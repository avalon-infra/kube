# WireGuard on the VPS — closed network setup

A personal WireGuard VPN using [wg-easy](https://github.com/wg-easy/wg-easy)
that connects your phone and laptop together over the VPS, but does **not**
let them reach the VPS itself or the internet through the VPS. The peers
form a small isolated mesh.

wg-easy runs as a single container in k3s with `hostNetwork: true`, so it
manages the `wg0` interface on the host directly. The web UI gets the
existing cert-manager / Traefik / Vault infrastructure for free via the
IngressRoute on `wg.matiix310.dev`.

## What "closed network" means here

  Phone (10.8.0.2)  <---->  Laptop (10.8.0.3)
        \                    /
         \                  /
          --->  VPS wg0  <---
                (10.8.0.1, but unreachable from clients)

- Phone can talk to Laptop and vice versa.
- Phone/Laptop **cannot** reach `10.8.0.1` (the VPS's `wg0` IP) — dropped
  by a host nftables rule on traffic arriving from `wg0`.
- Phone/Laptop **cannot** reach any other IP on the VPS (public IP,
  k3s service IPs, MetalLB IPs, etc.) for the same reason.
- Phone/Laptop **cannot** reach the internet through the VPS — no
  forwarding from `wg0` to other interfaces, and `WG_ALLOWED_IPS` on
  every client is restricted to `10.8.0.0/24`.
- Phone/Laptop still use their own local network for internet (split
  tunnel by design).

## Architecture

  ┌──────────────────────────────────────────────────────────┐
  │ VPS                                                       │
  │                                                           │
  │  Host (no WireGuard)                k3s                   │
  │  ─────────────────                 ───                   │
  │  nftables: drop wg0 input           wg-easy pod           │
  │  drop wg0 → non-wg0 forward         (hostNetwork: true)   │
  │  accept udp/51820 on ens3           ├─ wg0 interface      │
  │                                    │  10.8.0.1/24        │
  │                                    ├─ UI on tcp/51821    │
  │                                    └─ wg0.conf on host  │
  │                                                           │
  │                                    Traefik + cert-manager │
  │                                    expose UI at           │
  │                                    wg.matiix310.dev       │
  └──────────────────────────────────────────────────────────┘

A consequence of running wg-easy in k3s: if k3s is down, the VPN is down.
If that matters to you, run wg-easy on the host via Docker instead and
have only the IngressRoute live in k8s.

## Prerequisites

- Linux (k3s host). WireGuard is in the mainline kernel — no DKMS,
  but the kernel module must be available (it is on every default k3s
  install image). The script and deployment expect a standard
  `/lib/modules` tree for `modprobe`; cloud-provider kernels sometimes
  ship minimal — see the `DISABLE_IPV6` note in
  `apps/wireguard/deployment.yaml` if `modprobe ip6_tables` fails.
- DNS record for `wg.matiix310.dev` → VPS public IP.
- Vault reachable; the `vault-secrets-operator` already deployed in
  the cluster.
- `kubectl` and `vault` CLI on your workstation.

## One-time setup

### 1. Configure nftables for the closed network

Two nftables rules turn this into a closed network:

- accept UDP 51820 on the public interface — so WireGuard handshakes
  reach the server from the internet
- drop everything arriving on `wg0` (input) and drop `wg0 → non-wg0`
  forwarding — so peers cannot reach the host or route through it
- explicitly allow `wg0 → wg0` forwarding — so peer-to-peer still works

#### Fresh VPS — use the script

`setup-nftables.sh` in this directory auto-detects your public
interface, writes a full `/etc/nftables.conf`, restarts the service,
and prints the active ruleset. It refuses to overwrite a config that
isn't related to wireguard.

```sh
scp apps/wireguard/setup-nftables.sh vps:~/
ssh vps 'sudo bash ~/setup-nftables.sh'
```

If the script refuses with "ERROR: ... has no wireguard rules", back
the existing config up and re-run:

```sh
ssh vps 'sudo mv /etc/nftables.conf /etc/nftables.conf.bak && sudo bash ~/setup-nftables.sh'
```

If your VPS has multiple interfaces and the auto-detected one is
wrong, pass it explicitly:

```sh
ssh vps 'sudo bash ~/setup-nftables.sh ens3'
```

The ruleset opens:

  tcp/22       SSH
  tcp/80,443   HTTP(S) — k3s / Traefik ingress
  tcp/6443     k3s API server — needed for `kubectl` from outside
  udp/51820    WireGuard on the public interface
  forward wg0→wg0     accept  (peer-to-peer)
  forward wg0→other   drop    (closed network)
  input iif wg0       drop    (closed network)

Everything else stays at `policy drop`.

#### Existing ruleset — add the rules by hand

If you already have a hand-written `/etc/nftables.conf` you want to
keep, just append these rules to your `input` and `forward` chains:

```sh
# Replace 'eth0' with your public interface (ip route | grep default)
nft add rule inet filter input tcp dport { 80, 443 } ct state new accept comment "http(s)"
nft add rule inet filter input tcp dport 6443 ct state new accept comment "k3s-api"
nft add rule inet filter input udp dport 51820 iifname "eth0" accept comment "wireguard-in"
nft add rule inet filter input iifname "wg0" drop comment "wireguard-closed"

# Peer-to-peer (accept), then everything else from wg0 (drop).
# 'forward' policy must otherwise be 'accept' so k3s ingress works.
nft add rule inet filter forward iifname "wg0" oifname "wg0" accept comment "wireguard-peer-to-peer"
nft add rule inet filter forward iifname "wg0" drop comment "wireguard-closed-forward"

# Persist
nft list ruleset > /etc/nftables.conf
```

Note: the `tcp dport { 80, 443 }` and `tcp dport 6443` lines are what
k3s and `kubectl` need respectively. If your existing config already
opens them, you can skip those.

Common gotcha: if the `nft add rule` command fails with
"Could not process rule: No such file or directory", the
`inet filter input` chain doesn't exist on the host. Either run
`setup-nftables.sh` after backing up your config, or bootstrap the
table and chain first:

```sh
nft add table inet filter
nft 'add chain inet filter input { type filter hook input priority 0 ; policy accept ; }'
# then add the rules above
```

### 2. Kubernetes manifests

Files in this repo (apply with ArgoCD or `kubectl apply -k`):

- `apps/wireguard/deployment.yaml` — `wg-easy` with `hostNetwork: true`
  and `NET_ADMIN`, the WireGuard server lives in this pod. `INIT_*`
  env vars (used once on first start) set the public hostname, the
  IPv4 CIDR (`10.8.0.0/24`), the global `AllowedIPs` (`10.8.0.0/24`
  for the closed network), and the initial admin password from Vault.
  After first start, settings live in wg-easy's SQLite database and
  must be changed in the UI.
- `apps/wireguard/service.yaml` — ClusterIP on TCP 51821 (the UI port).
- `apps/wireguard/ingress.yaml` — Traefik `IngressRoute` for
  `wg.matiix310.dev`.
- `apps/wireguard/certificate.yaml` — `cert-manager` Certificate
  using the `prod-cluster-issuer` ClusterIssuer.
- `apps/wireguard/secret.yaml` — `VaultSecret` that materialises a
  Kubernetes Secret named `wg-easy-credentials` with a single
  `password` key.
- `argo/wireguard.yaml` — ArgoCD `Application` pointing at
  `apps/wireguard/`.

### 3. Vault password for the UI

The operator expects a path with a single `password` key. The
`VaultSecret` resource will materialise it as a Kubernetes Secret
`wg-easy-credentials` and the wg-easy pod will read it as
`INIT_PASSWORD` on the **first start only** (it then lives in
wg-easy's SQLite database, see warning below).

```sh
vault kv put secret/kvv2/wg-easy/data \
  password=$(openssl rand -base64 32)
```

> **Warning about `INIT_*` env vars.** The `INIT_HOST`,
> `INIT_PORT`, `INIT_IPV4_CIDR`, `INIT_ALLOWED_IPS`, and
> `INIT_PASSWORD` env vars are read **only on the first start** of
> the wg-easy pod, when the database is empty. After that, the
> values are stored in the SQLite database at
> `/etc/wireguard/wg-easy.db` and the env vars are ignored on
> subsequent restarts. To change any of them later, you have two
> options:
>
> 1. Change the value in the UI (`Configuration` page).
> 2. Wipe `/etc/wireguard/wg-easy.db` (and any wg-easy-related
>    state) and let the pod restart so the `INIT_*` env vars take
>    effect again. **This deletes all configured clients** — only
>    do it on a fresh deployment.

### 4. Roll it out

```sh
git add apps/wireguard argo/wireguard.yaml
git commit -m "feat(wireguard): switch to wg-easy"
git push
```

ArgoCD reconciles `argo/wireguard.yaml` and deploys wg-easy. The
first start takes a few seconds while the `wg0` interface is
created. You can follow along with:

```sh
kubectl -n wireguard logs -f deploy/wg-easy
```

## Adding a peer

1. Open `https://wg.matiix310.dev`, log in with `admin` / the Vault
   password.
2. Click **New Client**. Each new client is automatically assigned
   the next free address (`10.8.0.2`, then `10.8.0.3`, etc.) and
   inherits the global `WG_ALLOWED_IPS = 10.8.0.0/24` — leave that
   field as-is to preserve the closed network.
3. Either:
   - Scan the QR code with the WireGuard app on the phone, or
   - Download / copy the `.conf` and import it on the laptop with
     `wg-quick up ./peer.conf` or the WireGuard desktop app.

You do **not** need to restart the wg-easy pod. Adding a peer takes
effect immediately and the existing peer's connections are
unaffected.

## Verifying the closed network

From a peer (phone or laptop) connected to the VPN:

```sh
# Should succeed — peer-to-peer traffic
ping 10.8.0.<other-peer-ip>

# Should FAIL — closed network
ping 10.8.0.1                  # server's wg0 IP, dropped by nftables input
ping <VPS-public-IP>           # host's other interfaces, also dropped
curl https://example.com       # internet: no AllowedIPs for 0.0.0.0/0
```

From the VPS:

```sh
ip link show wg0               # interface exists, owned by the wg-easy pod
wg show                        # peers + handshakes + transfer stats
nft list chain inet filter input | grep wireguard
nft list chain inet filter forward | grep wireguard
```

## Migrating from wireguard-ui

If you previously had `wireguard-ui` running with a host-side
`wg-quick@wg0` setup, take these steps to clean up before deploying
wg-easy:

```sh
# Stop and remove the old UI
kubectl delete -n argocd -f argo/wireguard.yaml

# Tear down the host-side WireGuard
systemctl disable --now wg-quick@wg0 wgui-reload.path
rm -f /etc/wireguard/wg0.conf
rm -f /etc/systemd/system/wgui-reload.{path,service}
systemctl daemon-reload

# Optionally remove the wireguard package, the wg0 interface will be
# gone after wg-quick@wg0 stopped
apt remove wireguard-tools
```

Then deploy wg-easy as in step 4. Peer configs from wireguard-ui are
not migrated — re-add phone and laptop in the new UI.

## Troubleshooting

**UI is up but adding a peer doesn't take effect on the live
interface.** `kubectl -n wireguard logs deploy/wg-easy` will tell you
if the container is failing to bring up `wg0`. Common cause: the
`wg-easy-credentials` Secret doesn't exist yet (the pod
CrashLoopBackOffs until Vault resolves it).

**`INIT_*` env vars in the deployment are not being applied.** The
database is not empty — either wg-easy was already deployed once
with no/wrong init, or you restarted a fresh db. Wipe
`/etc/wireguard/wg-easy.db` (and any sibling state files) and let
the pod restart; the `INIT_*` env vars will run the wizard on the
next start. Re-add all clients in the UI afterwards.

**Password change in Vault has no effect.** Same root cause: the
password is now in the SQLite database, not the env var. Change it
in the UI, or wipe the database to force a re-init from the
`INIT_PASSWORD` Vault secret.

**`modprobe: FATAL: Module ip6_tables not found in directory
/lib/modules/<version>`.** Two possible causes:

1. The deployment is missing the `/lib/modules` hostPath mount or
   the `SYS_MODULE` capability. Both are required so `modprobe`
   inside the container can find and load the host's kernel modules.
   Compare against the official `docker-compose.yml`:
   https://github.com/wg-easy/wg-easy/blob/master/docker-compose.yml
2. The host's kernel genuinely doesn't include `ip6_tables`. Some
   cloud-provider kernels ship without it. Set `DISABLE_IPV6=true`
   in `apps/wireguard/deployment.yaml` to skip the IPv6 firewall
   setup entirely. (You almost certainly don't need IPv6 for a
   personal phone+laptop VPN.)

**`[unhandledRejection] Error: Command failed: wg-quick up wg0`.**
Almost always a downstream effect of the `modprobe` failure above.
Once the modules are reachable, this clears up. If it persists
after fixing modprobe, share the full output of
`kubectl -n wireguard logs deploy/wg-easy` and the contents of
`/etc/wireguard/wg0.conf` on the host.

**Peer can ping the server's wg0 IP (10.8.0.1).** The
`iifname "wg0" drop` rule on `input` is missing. Check with
`nft list ruleset`. Make sure it sits *before* any allow rule that
might match it (chain order matters).

**Peer can ping another peer on the same VPN but the other peer
doesn't reply.** The peer-to-peer forward rule is missing. Check
`nft list chain inet filter forward` — you need
`iifname "wg0" oifname "wg0" accept` *before* the
`iifname "wg0" drop` rule.

**Peer can reach the internet through the VPS.** Either
`WG_ALLOWED_IPS` in the client config got set to `0.0.0.0/0` (check
in the UI) or the `wireguard-closed-forward` rule is missing.

**Handshake never completes.** UDP 51820 not open on the public
interface, or DNS for `wg.matiix310.dev` doesn't resolve to the VPS
public IP. From outside the VPS:
`nc -uvz <vps-public-ip> 51820`. From the VPS:
`ss -ulpn | grep 51820` should show the wg-easy container binding
it (with `hostNetwork: true` it's bound on the host's interfaces
directly).

**`wireguard-ui` had wg0 as 10.8.0.1 — does wg-easy use the same
default?** Yes, `WG_DEFAULT_ADDRESS=10.8.0.x` makes the server
10.8.0.1 and assigns 10.8.0.2, .3, etc. to clients.

## Uninstall

```sh
# Remove the k8s app
kubectl delete -n argocd -f argo/wireguard.yaml
# Then remove the files from the repo in a follow-up commit

# Tear down wg0 and the nftables rules (the wg-easy pod will
# remove wg0 as part of its own shutdown, but the nftables rules
# are host-side and need manual cleanup)
nft delete rule inet filter input handle $(nft -a list chain inet filter input | grep 'comment "wireguard' | grep -oP 'handle \K\d+')
nft delete rule inet filter forward handle $(nft -a list chain inet filter forward | grep 'comment "wireguard' | grep -oP 'handle \K\d+')
# (or edit /etc/nftables.conf and `nft -f` it)

# Optional: clean up the Vault entry
vault kv delete secret/kvv2/wg-easy/data
```

## File map

```
  apps/wireguard/
    README.md           <- this file
    setup-nftables.sh   <- host script: write /etc/nftables.conf
    kustomization.yaml
    deployment.yaml     <- wg-easy, hostNetwork, NET_ADMIN
    service.yaml        <- ClusterIP on TCP 51821 (the UI)
    ingress.yaml        <- Traefik IngressRoute for wg.matiix310.dev
    certificate.yaml    <- cert-manager cert
    secret.yaml         <- VaultSecret → wg-easy-credentials Secret
  argo/wireguard.yaml   <- ArgoCD Application
```
