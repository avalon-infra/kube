# Vault — HA raft, manually unsealed

Vault runs from the upstream Helm chart (`hashicorp/vault`, pinned in
`argo/vault.yaml`) with **integrated storage (raft)** and **manual
initialisation / manual unsealing**.

- Namespace: `vault`
- Replicas: `1` (single raft voter — this is the quorum)
- Storage: PVC `data-vault-0` (10Gi, `local-path`)
- TLS: served from the cert-manager secret `vault-tls`
  (`apps/vault/certificate.yaml`), mounted at `/vault/userconfig/vault-tls`
- Seal type: `shamir`, `t=1, n=1` — **one** unseal key, threshold **one**

> **Vault is not auto-unsealed.** There is no auto-unseal mechanism in
> this cluster: no KMS transit seal, no `vault-operator`, no seal
> controller. **Every time the Vault pod (or the node) restarts, Vault
> comes back SEALED** and every consumer that talks to Vault — most
> notably `vault-secrets-operator` — fails until someone unseals it by
> hand. See [Unsealing Vault](#unsealing-vault).

## Why the liveness probe must tolerate a sealed Vault

This is the single most important detail of this deployment, and it is
easy to get wrong.

Vault answers `GET /v1/sys/health` with **HTTP 503 while it is sealed or
uninitialised**. That is an *operational* state, not a dead process.

A liveness probe that does not account for that creates an unbreakable
deadlock:

1. Vault starts sealed → `/v1/sys/health?standbyok=true` returns 503.
2. The kubelet's liveness probe fails `failureThreshold` times and kills
   the container.
3. The container restarts → Vault is sealed again → back to step 1.

On top of that, the container is killed **before** a human can run
`vault operator unseal`, so the Vault can never be unsealed at all.

This is not hypothetical — it happened. The liveness probe used to be:

```yaml
livenessProbe:
  enabled: true
  path: "/v1/sys/health?standbyok=true"   # <- 503 while sealed
  initialDelaySeconds: 60
```

With the chart's default `periodSeconds: 5` and `failureThreshold: 2`,
the kubelet killed `vault-0` roughly every **70 seconds**. `vault-0`
racked up **7375 restarts over 19 days** in `CrashLoopBackOff`, and
Vault was unreachable the whole time.

The fix (in `argo/vault.yaml`) is to make the liveness probe
**sealed-tolerant**, using the same query the readiness probe uses:

```yaml
readinessProbe:
  enabled: true
  path: "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
livenessProbe:
  enabled: true
  path: "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
  initialDelaySeconds: 60
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 6
```

`sealedcode=204&uninitcode=204` tells Vault to answer **204 No Content**
for those states, so the liveness probe only fails when the HTTP listener
is genuinely gone — which is what liveness is supposed to mean. The
relaxed timings (`15s x 6` ≈ 2.5 min of tolerance) additionally stop a
slow raft recovery from tripping the probe.

> **The chart renders no `startupProbe` for the server StatefulSet.**
> Only `readinessProbe` and `livenessProbe` exist in
> `templates/server-statefulset.yaml` (chart 0.32.0), so a startup probe
> cannot be used to gate the liveness probe here. If you ever need one,
> it has to be injected with a kustomize patch (see
> `git show 1fdb1ee` — a `tcpSocket` probe patch that was later
> reverted).

### If the Vault ever crashes into CrashLoopBackOff again

Check the liveness probe path first. If it is missing
`sealedcode=204&uninitcode=204`, that is the bug: the container is being
killed for being sealed, not for being unhealthy.

## Unsealing Vault

Check the current state:

```sh
kubectl -n vault exec vault-0 -- \
  wget -q -O - --timeout=5 --no-check-certificate \
  "https://127.0.0.1:8200/v1/sys/seal-status"
# {"type":"shamir","initialized":true,"sealed":true,"t":1,"n":1,...}
```

If `"sealed":true`, unseal it with the unseal key:

```sh
kubectl -n vault exec vault-0 -- env \
  VAULT_ADDR=https://127.0.0.1:8200 \
  vault operator unseal -tls-skip-verify "<UNSEAL KEY>"
```

`-tls-skip-verify` is needed because the certificate served by Vault
covers `vault.matiix310.dev` and `vault.vault.svc.cluster.local`, but
**not** `127.0.0.1` (no IP SAN). The connection is a loopback to the
same pod, so verification adds nothing.

To avoid leaving the key in your shell history, use the interactive
prompt instead:

```sh
kubectl -n vault exec -it vault-0 -- env \
  VAULT_ADDR=https://127.0.0.1:8200 \
  vault operator unseal -tls-skip-verify
# Key (will be hidden): <paste the unseal key>
```

A successful unseal prints the HA status and the cluster becomes active:

```
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false
...
HA Mode         active
```

### Where the unseal key lives

The unseal key and the root token were captured when the cluster was
initialised and are stored **outside this repo**, in
`../cluster-keys.json` (i.e. `perso/avalon/cluster-keys.json`), which
is deliberately *not* a git repository. Do not move them into this repo
— every secret here is supposed to come from Vault itself.

If that file is ever lost, the Vault cannot be recovered: `t=1, n=1`
means there is exactly one key, `vault operator generate-root` needs
quorum (which a sealed single-node cluster does not have), and the
`core/shamir-kek` entry in the raft data is encrypted with the key
itself. The only remaining option would be to delete the PVC and
re-initialise, which **destroys every secret, policy, auth method and
OIDC provider stored in Vault**.

## Consumers

`vault-secrets-operator` (`argo/vault-secrets-operator.yaml`) reads the
`kvv2/` mount and materialises the `VaultSecret` resources in `apps/`
into Kubernetes Secrets. It authenticates with the `kubernetes/` auth
method, which needs Vault to be **unsealed** — a sealed Vault answers
the login request with `503 Vault is sealed` and the operator exits with
code 1, which puts it in `CrashLoopBackOff`.

So: **if `vault-secrets-operator` is crash-looping, check whether Vault
is sealed first.** Its error message says so explicitly:

```
Could not create API client for Vault: ... Code: 503. Errors: * Vault is sealed
```

Note that the operator does **not** delete the Kubernetes Secrets it has
already materialised when Vault becomes unreachable, so an outage does
not immediately break the downstream applications. It does, however,
stop them from being refreshed.

## Troubleshooting

**`vault-0` is in CrashLoopBackOff with a huge restart count.**

Check the liveness probe (see above). A liveness probe that is not
sealed-tolerant turns "Vault is sealed" into an infinite restart loop.
Also confirm the container is not being OOM-killed:

```sh
kubectl -n vault get pod vault-0 -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
# exitCode 137 = SIGKILL (probe kill or OOM kill - check the pod events)
```

**`vault-0` starts but `/v1/sys/health` returns 503.**

Vault is sealed. Unseal it.

**`Liveness probe failed: ... Client.Timeout exceeded while awaiting headers`.**

Vault's HTTP listener is not accepting connections yet — usually just
slow raft startup. With the relaxed probe timings this is tolerated.

**`vault operator unseal` fails with `invalid key: failed to decrypt keys from storage`.**

The key does not match this Vault instance. Do **not** keep retrying —
check that you are using the key from `../cluster-keys.json`, and that it
belongs to this cluster (`cluster_id` in `seal-status` is
`1aa1e46e-791c-72d8-e16d-f5b95d8316bd`).

**`storage.raft.fsm: raft FSM db file has wider permissions than needed: needed=-rw------- existing=-rw-rw----`.**

A warning, not an error. The `local-path` provisioner creates the
directory with `0770` and the umask leaves the file group-writable.
Vault copes with it. Harmless.

**The Vault UI is reachable but every API call returns 503.**

Sealed. Same as above.

## Reference

- Upstream chart: <https://github.com/hashicorp/vault-helm> (0.32.0)
- Vault docs on sealing: <https://developer.hashicorp.com/vault/docs/concepts/seal>
