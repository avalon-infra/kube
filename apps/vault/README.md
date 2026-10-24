# Vault — HA raft, manually unsealed

Vault runs from the upstream Helm chart (`hashicorp/vault`, pinned in
`argo/vault.yaml`) with **integrated storage (raft)** and **manual
initialisation / manual unsealing**.

- Namespace: `vault`
- Replicas: `1` (single raft voter — this is the quorum)
- Storage: PVC `data-vault-0` (10Gi, `local-path`)
- Seal type: `shamir`, `t=1, n=1` — **one** unseal key, threshold **one**

## TLS: two listeners, two identities

Vault serves **two** TLS listeners, each with its own certificate, for
two different kinds of client:

| Port | Listener | Secret | Issued by | Used by |
|---|---|---|---|---|
| 8200 | `tcp` | `vault-tls` | `prod-cluster-issuer` (ACME / Let's Encrypt) | the WireGuard tunnel, Traefik, a browser |
| 8201 | `tcp` (raft cluster) | `vault-tls` | same | vault cluster traffic (raft) |
| 8300 | `tcp-internal` | `vault-internal-tls` | `internal-cluster-issuer` (private CA) | in-cluster clients |

- **8200 — the edge identity.** The certificate is issued by the public
  ACME issuer, so a phone or a laptop on the WireGuard tunnel can verify
  it against the root CAs it already trusts. The name is
  `vault.matiix310.dev`.
- **8300 — the in-cluster identity.** The certificate is issued by the
  **private CA** in `apps/cert-manager/internal-ca.yaml`. The name is
  `vault.vault.svc.cluster.local`, which is not publicly resolvable.
  Only pods that are explicitly given that CA can verify it — today that
  is `vault-secrets-operator`, via `VAULT_CACERT`.

**Why not just one certificate with both names on it?**

Because the trust anchors have to differ. If the in-cluster name were a
SAN on the Let's Encrypt certificate, then every pod talking to Vault
would have to trust the whole public web PKI to verify one private
service, and a private service identity would depend on a public CA's
good behaviour. A separate listener keeps the two trust worlds apart:
the edge keeps its public CA, the cluster gets its own.

**Why not two certificates on one listener?**

Because a TLS server sends one certificate per listener. `tls_cert_file`
is a single file path.

The listener configuration lives in `argo/vault.yaml` under
`server.ha.raft.config`.

> **The 8300 listener has no `cluster_address`.** 8201 is already the
> raft cluster port of the `tcp` listener, and a raft cluster has
> exactly one cluster listener. The 8300 listener only serves API
> requests.

### Certificate reload, and why it matters here

Both listeners set `tls_reload_interval = "30s"`. Vault then re-reads
the certificate from the mounted Secret when its contents change, and
picks up a rotated certificate **without a restart**.

That is not a nicety here. Restarting the Vault pod **re-seals it**
(see below), and with `t=1, n=1` somebody has to unseal it by hand
again. With `tls_reload_interval`, a cert-manager renewal does not
bounce the pod.

### The Service for 8300

The Helm chart's `vault` Service template hard-codes exactly two ports
(8200 and 8201) and there is no chart value to add a third one. The
Service that exposes 8300 is therefore defined in
`apps/vault/service-internal.yaml` and applied by the same ArgoCD
Application (`argo/vault.yaml`) that renders the chart — so it is still
pure GitOps and it is still pruned when it is deleted from the repo.

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

> The certificate that covers `vault.vault.svc.cluster.local` is the
> **internal** one (`vault-internal-tls`, on port 8300). Port 8200 serves
> `vault-tls`, which covers `vault.matiix310.dev` only. Either way the
> loopback to `127.0.0.1:8200` is not covered by any of them, so
> `-tls-skip-verify` is still required.

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

It reaches Vault on the **internal** listener:

```
VAULT_ADDRESS = https://vault.vault.svc.cluster.local:8300
VAULT_CACERT  = /etc/vault-secrets-operator/ca.pem
```

`VAULT_CACERT` points at the private CA bundle in the operator's
namespace (`apps/vault-secrets-operator/certificate-ca.yaml`). If that
CA is wrong or missing, the operator fails with an `x509` error and
cannot materialise anything.

So: **if `vault-secrets-operator` is crash-looping, check whether Vault
is sealed first.** Its error message says so explicitly:

```
Could not create API client for Vault: ... Code: 503. Errors: * Vault is sealed
```

Note that the operator does **not** delete the Kubernetes Secrets it has
already materialised when Vault becomes unreachable, so an outage does
not immediately break the downstream applications. It does, however,
stop them from being refreshed.

## Files

```
apps/vault/
  README.md               <- this file
  certificate.yaml        <- edge cert (Let's Encrypt), served on 8200
  certificate-internal.yaml
                        <- internal cert (private CA), served on 8300
  service-internal.yaml  <- Service exposing 8300
  ingress.yaml           <- the public route - DISABLED, see its header
  kustomization.yaml
apps/cert-manager/
  internal-ca.yaml       <- the private CA (selfSigned Issuer -> CA -> ca ClusterIssuer)
apps/vault-secrets-operator/
  certificate-ca.yaml    <- the private CA bundle, in the operator's namespace
argo/vault.yaml                  <- ArgoCD Application (chart + apps/vault)
argo/vault-secrets-operator.yaml <- ArgoCD Application (chart + apps/vault-secrets-operator)
```

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

**`vault-secrets-operator` fails with an `x509` certificate error.**

The operator verifies Vault's internal certificate against the private
CA it was given. If the two do not match, the handshake fails:

```
x509: certificate signed by unknown authority
x509: certificate is valid for vault.matiix310.dev, not vault.vault.svc.cluster.local
```

Check which certificate Vault is actually serving on 8300, and which CA
the operator has:

```sh
# What Vault serves on the internal listener.
kubectl -n vault get secret vault-internal-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -issuer -ext subjectAltName

# What the operator trusts.
kubectl -n vault-secrets-operator-system get secret vault-internal-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d \
  | openssl x509 -noout -subject
```

Both have to be the same CA (`CN=avalon internal CA`). If the operator
still has the OLD CA bundle, cert-manager has not re-issued
`apps/vault-secrets-operator/certificate-ca.yaml` yet — check
`kubectl -n vault-secrets-operator-system get certificate`.

**`vault-secrets-operator` fails with `context deadline exceeded`.**

The connection to `vault.vault.svc.cluster.local:8300` hangs. That
means nothing is listening on 8300 — the internal listener is not up.
Check:

```sh
kubectl -n vault get svc vault-internal-api
kubectl -n vault exec vault-0 -- \
  wget -qO- --timeout=3 --no-check-certificate \
  "https://127.0.0.1:8300/v1/sys/health"
```

If that fails too, the Vault pod has not been rolled with the new
`server.ha.raft.config` (see `argo/vault.yaml`) — or it came back
sealed and is waiting to be unsealed.

## Reference

- Upstream chart: <https://github.com/hashicorp/vault-helm> (0.32.0)
- Vault docs on sealing: <https://developer.hashicorp.com/vault/docs/concepts/seal>
