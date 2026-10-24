# WireGuard on the VPS — closed network setup

A personal WireGuard VPN using [wg-easy](https://github.com/wg-easy/wg-easy)
that connects your phone and laptop together over the VPS, but does **not**
let them reach the VPS itself or the internet through the VPS. The peers
form a small isolated mesh.

wg-easy runs as a single container in k3s with `hostNetwork: true`, so it
manages the `wg0` interface on the host directly. The web UI gets the
existing cert-manager / Traefik / Vault infrastructure for free via the
IngressRoute on `wg.matiix310.dev`.

> **This document describes two modes.**
>
> - **Closed network** (the original design, described below) — peers reach
>   only each other.
> - **Split tunnel to the cluster** (added later) — peers additionally reach
>   the k3s pod/service networks, so they can use private services such as
>   Vault. See [Opening the tunnel to the cluster](#opening-the-tunnel-to-the-cluster).
>
> The host itself stays closed in *both* modes.

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

> **⚠️ These claims were not actually enforced on this host.**
>
> The rules that implement them live in **legacy iptables** (written by
> wg-easy's PostUp hook), not in nftables — and wg-easy's
> `-A FORWARD -i wg0 -j ACCEPT` accepts *all* forwarded traffic from the
> tunnel. The `inet filter` nftables table was empty (default
> `policy accept`). So on a fresh boot, before
> wg-easy's **per-client firewall** (off by default) fixes this by
> inserting its own chain at `FORWARD` position 1, ahead of wg-easy's
> `ACCEPT`. Enable it in the UI — no host script required.
> See [Opening the tunnel to the cluster](#opening-the-tunnel-to-the-cluster).

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

# The authoritative policy on this host is LEGACY iptables:
iptables -S INPUT   | grep wireguard
iptables -S FORWARD | grep wireguard

# The nftables copy (defence in depth):
nft list table inet filter | grep wireguard
```

## Opening the tunnel to the cluster

Split-tunnel mode: peers keep full control of their own internet traffic,
but the k3s pod/service networks become reachable over the VPN. This is
how a phone or laptop reaches private services (Vault first).

The **host stays closed** — peers still cannot reach the VPS public IP,
`10.8.0.1`, the k3s API server, or anything else listening on the host.
Only traffic *forwarded into the cluster* is allowed.

### What changes

| | Closed network | Split tunnel |
|---|---|---|
| Peer → peer (`10.8.0.x`) | allowed | allowed |
| Peer → VPS host (`10.8.0.1`, public IP) | **dropped** | **dropped** (unchanged) |
| Peer → internet | not routed | not routed |
| Peer → pod CIDR (`10.42.0.0/16`) | dropped | **allowed** (per client) |
| Peer → service CIDR (`10.43.0.0/16`) | dropped | **allowed** (per client) |

In split-tunnel mode the allowlist is **per client**, enforced by
wg-easy's own firewall chain — so a phone can be limited to
`10.43.9.131:8200` while a laptop gets a wider range, without touching
the host firewall.

### The pieces

**1. Client-side routing — `AllowedIPs`**

The peer must route the cluster CIDRs into the tunnel. In wg-easy this is
the global `AllowedIPs` (Configuration page) or a per-client `AllowedIPs`.

```
10.8.0.0/24, 10.42.0.0/16, 10.43.0.0/16
```

`deployment.yaml` sets `INIT_ALLOWED_IPS` to that value, but **`INIT_*` is
read only on the very first start** when the SQLite DB is empty. On an
existing deployment you must change it in the UI:

```
wg.matiix310.dev → Configuration → Allowed IPs
  10.8.0.0/24, 10.42.0.0/16, 10.43.0.0/16
```

Then re-download each client config (or set a per-client `AllowedIPs` on
your own device only, which leaves the phone/laptop peer-to-peer config
untouched).

**2. Server-side enforcement — wg-easy's built-in firewall (no shell script)**

wg-easy v15 ships a per-client firewall engine that manages its own
iptables chain. **No host script is needed** — the policy lives in the
wg-easy database and is applied by wg-easy itself.

Turn it on:

```
wg.matiix310.dev → Configuration → "Enable Per-Client Firewall"
```

Then, per client, set **"Firewall Allowed IPs"** (the server-side
allowlist):

```
10.43.9.131:8200
```

or, for the whole service network:

```
10.43.0.0/16
```

Supported entry syntax (parsed by wg-easy):

| Entry | Meaning |
|---|---|
| `10.43.0.0/16` | CIDR, any port |
| `10.43.9.131:8200` | IP + port (TCP and UDP) |
| `10.43.9.131:8200/tcp` | IP + port, TCP only |
| `10.43.9.131:8200/udp` | IP + port, UDP only |
| `[fd00::1]:8200` | IPv6 with port |

What wg-easy generates:

```
iptables -N WG-FILTER
iptables -I FORWARD 1 -i wg0 -j WG-FILTER
iptables -A WG-FILTER -s 10.8.0.2 -d 10.43.0.0/16 -j ACCEPT
iptables -A WG-FILTER -s 10.8.0.3 -d 10.43.0.0/16 -j ACCEPT
iptables -A WG-FILTER -j DROP
```

Two things worth noting:

- The `-I FORWARD 1` inserts at **position 1**, ahead of the
  `-i wg0 -j ACCEPT` rule that wg-easy's own PostUp hook adds. So the
  firewall chain is what actually decides — the permissive rule is
  shadowed.
- The final `-j DROP` is the catch-all: a peer can only reach what its
  own entry allows.

Because the policy is stored in SQLite and re-applied by wg-easy on every
start, it **survives reboots** — no systemd unit, no `nftables.conf`, no
script to re-run.

> **This replaces the old `setup-nftables-split-tunnel.sh`.** That script
> existed to hand-roll the same thing across two independent rule systems
> (legacy iptables *and* nftables), because wg-easy's own firewall was
> not being used. With the built-in firewall, the host-side shell script
> is unnecessary.
>
> If you want to *verify* what wg-easy actually applied:
>
> ```sh
> kubectl -n wireguard exec deploy/wg-easy -- iptables -S WG-FILTER
> kubectl -n wireguard exec deploy/wg-easy -- iptables -S FORWARD | head
> ```

**3. The Traefik route — `vault-vpn-route.yaml`**

`apps/wireguard/vault-vpn-route.yaml` exposes Vault on the hostname
`vault.vpn.matiix310.dev`, reachable only through the tunnel.

The **public** route `vault.matiix310.dev` has been **removed** — it is no
longer listed in `apps/vault/kustomization.yaml`, so ArgoCD never renders
it and it never reaches the cluster. The manifest is kept in the repo
(unreferenced) as documentation; see the header comment in
`apps/vault/ingress.yaml`.

That is the whole security model:

- Vault is **not published** — there is no public route to attack.
- The only way in is the WireGuard tunnel.
- Inside the tunnel, wg-easy's per-client firewall limits each peer to
  `10.43.9.131:8200`.

```yaml
routes:
  - match: Host(`vault.vpn.matiix310.dev`)
    services:
      - name: vault
        port: 8200
        scheme: https
        serversTransport: traefik-vault-vpn-transport
```

Notes on this route:

- **No IPAllowList middleware.** See
  [Traefik and the tunnel](#traefik-and-the-tunnel) for why an IP
  allowlist cannot work here — kube-proxy masquerades the peer address
  away before Traefik sees it.
- **Port 8200 == targetPort == container port.** The `80 -> 51821`
  indirection breaks Traefik resolution (see Troubleshooting).
- **`serversTransport.serverName: vault.matiix310.dev`.** Vault's pod
  serves a certificate for `vault.matiix310.dev`. The VPN hostname is only
  a Traefik routing label — the TLS handshake still happens against the
  Vault pod — so we pin `serverName` rather than disabling verification.
- **Its own certificate.** `vault-tls` only covers `vault.matiix310.dev`
  (the `*.matiix310.dev` wildcard does **not** match a two-label
  subdomain), so `certificate-vpn.yaml` issues a separate
  `vault-vpn-tls` certificate for `vault.vpn.matiix310.dev`. DNS-01
  against `matiix310.dev` — no public ingress needed to issue it.

**4. In-cluster access — direct to the Service, on the internal listener**

`vault-secrets-operator` talks to Vault **directly over the cluster
network**, not through Traefik and not through the public hostname:

```
VAULT_ADDRESS = https://vault.vault.svc.cluster.local:8300
```

That name resolves to Vault's ClusterIP via CoreDNS, so the operator
never touches the public route. Removing `vault.matiix310.dev` therefore
does not affect secret materialisation.

Note the port: **8300**, not 8200.

**Two listeners, two identities.** Vault serves two certificates:

| Port | Listener | Certificate | Issued by | Used by |
|---|---|---|---|---|
| 8200 | `tcp` | `vault-tls` | `prod-cluster-issuer` (Let's Encrypt) | the VPN tunnel, Traefik, browsers |
| 8300 | `tcp-internal` | `vault-internal-tls` | `internal-cluster-issuer` (private CA) | in-cluster clients |

The reason for the split is the trust model:

- The **edge** identity (`vault.matiix310.dev`) has to be verifiable by
  a phone or a laptop that only trusts the public root CAs. So it is
  issued by a public CA.
- The **in-cluster** identity (`vault.vault.svc.cluster.local`) is a
  private name that is not publicly resolvable. A public CA issuing a
  certificate for it would make a private service depend on the public
  web PKI — every public CA could then be a candidate signer for it.
  So it is issued by a **private CA** that only the pods that need it are
  given.

`vault-secrets-operator` gets that private CA explicitly:

```yaml
environmentVars:
  - name: VAULT_CACERT
    value: "/etc/vault-secrets-operator/ca.pem"
```

`VAULT_CACERT` is a **file path**. The file is the `ca.crt` key of the
`vault-internal-ca` Secret in the operator's namespace
(`apps/vault-secrets-operator/certificate-ca.yaml`). The operator
verifies Vault's certificate against that CA and nothing else — it does
not trust the public roots for this connection.

> `VAULT_CACERT` **replaces** the trust store rather than adding to it:
> the Vault API client loads that file into a fresh `x509.CertPool` and
> uses it on its own. The public root CAs are not consulted for this
> connection. That is the intent — the operator talks to exactly one
> private service.

The `ca.crt` key is the same CA that signed Vault's certificate, so
there is no second, hand-copied CA bundle that could drift out of sync
with the issuer.

Verify:

```sh
# The internal listener is up and serving the internal certificate.
kubectl -n vault get svc vault-internal-api
kubectl -n vault get certificate vault-internal-tls

# The operator is talking to it, and its CA bundle is the private CA.
kubectl -n vault-secrets-operator-system get secret vault-internal-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -subject
# subject=CN=avalon internal CA

kubectl -n vault-secrets-operator-system logs deploy/vault-secrets-operator-system \
  | grep -i "renew vault token"
```

Other in-cluster consumers use the same Service and are unaffected by
the public route removal.


### Traefik and the tunnel

**There is no IPAllowList, and that is deliberate.** The obvious approach —
allowlist the tunnel subnet `10.8.0.0/24` on the Vault route — does not
work, for a reason worth knowing:

```
chain KUBE-SVC-UEJ6RQQLJG4VJPPB {
    ip saddr != 10.42.0.0/16 ip daddr 10.43.9.131 ... jump KUBE-MARK-MASQ
    ...
}
```

A VPN peer at `10.8.0.x` is **not** in the pod CIDR, so kube-proxy
**masquerades** its traffic to the node IP (`51.68.191.40`) before the
connection reaches the pod. By the time Traefik sees it, the source IP is
the node IP, not `10.8.0.x`.

Traefik has neither `forwardedHeaders` nor `proxyProtocol` configured
(verified with `kubectl -n kube-system get deploy traefik`), so it has no
way to recover the real peer address. An `IPAllowList` would therefore
have to allow `10.42.0.0/16` / `10.43.0.0/16` — which means **any pod in
the cluster** could reach the route. That is not a security control.

So the control is instead: **the public route does not exist.** Vault is
not published at `vault.matiix310.dev` any more (the public
`IngressRoute` has been removed from `apps/vault/kustomization.yaml`),
which leaves the tunnel as the only way in. "The route doesn't exist" is
far stronger than "the route exists but rejects some IPs".

The request path from a peer is then:

```
peer 10.8.0.x
  -> wg0
  -> FORWARD (nftables/iptables allows flannel.1/cni0)
  -> kube-proxy DNAT (+ masquerade, because 10.8.0.x is outside 10.42.0.0/16)
  -> Traefik pod
  -> ClusterIP 10.43.9.131:8200
  -> vault-0 pod
```

### DNS on the peer

`vault.vpn.matiix310.dev` must resolve **to the Vault ClusterIP
`10.43.9.131`**, not to the public IP. Use peer-local DNS:

```
[DNS]
vault.vpn.matiix310.dev = 10.43.9.131
```

This is the important part: the public IP is **not** in the client's
`AllowedIPs`, so a peer that resolved the hostname to `51.68.191.40`
would send the request out its own default gateway, straight to Traefik
from the public side — bypassing the tunnel entirely.

Pointing DNS at the ClusterIP keeps the request inside the tunnel, where
the tunnel range is in `AllowedIPs` and the traffic genuinely flows over
wg0.

> **Note.** The certificate is issued for `vault.vpn.matiix310.dev`, so
> the client must use that **hostname** (not the bare IP) for TLS to
> validate. `https://10.43.9.131:8200` will fail certificate validation
> even though the connection works.

### If you must keep a public route

The peer-identity problem returns, and the fix is to give Traefik a
trustworthy client IP:

- **Traefik `proxyProtocol` on the `websecure` entrypoint** plus
  `trustedIPs` limited to the node — the real peer address then survives
  to the router and an `IPAllowList` becomes meaningful. Requires
  `--entryPoints.websecure.proxyProtocol=true` and
  `--entryPoints.websecure.proxyProtocol.trustedIPs=<node IP>`, and the
  LoadBalancer must pass PROXY protocol through.
- **Or `forwardedHeaders` with a strict `ipStrategy.depth`** — Traefik
  then trusts the rightmost `X-Forwarded-For` entry (the one it added
  itself) rather than a client-supplied one.

Neither is configured today. Until one of them is, an IP-based allowlist
on a public Vault route cannot distinguish VPN clients from the internet.

### Verifying the split tunnel

From a peer with the tunnel up:

```sh
# Should succeed — peer-to-peer
ping 10.8.0.<other-peer-ip>

# Should FAIL — the host is still closed
ping 10.8.0.1
ping 51.68.191.40

# Should succeed in split-tunnel mode — cluster services
curl -k https://10.43.9.131:8200/v1/sys/health
nc -zv 10.43.9.131 8200

# Should FAIL — internet is not routed through the VPS
curl https://example.com
```

From the VPS:

```sh
# The new forward rules (legacy iptables is authoritative here)
iptables -S FORWARD | grep wireguard
nft list table inet filter | grep split-tunnel

# Cluster reachability from the host
curl -k https://10.43.9.131:8200/v1/sys/health
```

### Rolling it out

```sh
git add apps/wireguard
git commit -m "feat(wireguard): split tunnel to cluster CIDRs + Vault VPN route"
git push
```

ArgoCD syncs `argo/wireguard.yaml` (already present, no change needed)
and applies the new `Certificate`, `IngressRoute`, `Middleware` and
`ServersTransport`.

Then, on the host:

```sh
```

Then, in the wg-easy UI:

1. **Configuration → Allowed IPs** → `10.8.0.0/24, 10.42.0.0/16, 10.43.0.0/16`
2. **Configuration → Enable Per-Client Firewall** → on
3. **Each client → Firewall Allowed IPs** → `10.43.9.131:8200`
4. Re-download the client configs

## Migrating away from the host script

The split-tunnel setup originally shipped a host script
(`setup-nftables-split-tunnel.sh`) that hand-wrote the firewall policy
into both legacy iptables and nftables. It is no longer needed —
wg-easy's built-in per-client firewall does the same job, persists the
policy itself, and needs no script to re-run after a reboot.

If you previously ran that script, clean up the rules it installed:

```sh
# Remove the split-tunnel rules from the legacy iptables chain
for i in cni0 flannel.1; do
  sudo iptables -D FORWARD -i wg0 -o "$i" -j ACCEPT \
    -m comment --comment "wireguard-split-tunnel-$i" 2>/dev/null
done
sudo iptables -D FORWARD -i wg0 -o wg0 -j ACCEPT \
  -m comment --comment "wireguard-peer-to-peer" 2>/dev/null
sudo iptables -D FORWARD -i wg0 -j DROP \
  -m comment --comment "wireguard-closed-forward" 2>/dev/null
sudo iptables -D INPUT -i wg0 -j DROP \
  -m comment --comment "wireguard-closed-input" 2>/dev/null
```

After that, confirm wg-easy's own firewall chain is doing the work:

```sh
sudo iptables -S FORWARD | head
sudo iptables -S WG-FILTER
```

Do **not** run the old `setup-nftables.sh` — it calls `nft flush ruleset`,
which destroys kube-proxy's tables and briefly breaks pod networking.

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

**Browser shows Traefik "service port not found: 51821" when hitting
`wg.matiix310.dev`, but `kubectl port-forward deploy/wg-easy 51821`
works.** Traefik's k8s provider isn't resolving the
`port: 80 → targetPort: 51821` indirection in the Service cleanly.
Fix: make the Service's `port` equal the pod's port (51821) and
update the IngressRoute to use the same. The Service file in this
repo is already set up that way — if you've customised it back to
port 80, restore the change.

**`modprobe: FATAL: Module ip6_tables not found in directory**
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

**Peer can ping the server's wg0 IP (10.8.0.1).** The `iifname "wg0"
drop` rule on `input` is missing. Check the **legacy iptables** chain
first (it is authoritative on this host):

```sh
iptables -S INPUT | grep wireguard
#    expect: -A INPUT -i wg0 -j DROP ... at position 1
nft list table inet filter | grep wireguard
```

Make sure the drop sits *before* any allow rule that might match it
(chain order matters).

**Peer can ping another peer on the same VPN but the other peer
doesn't reply.** The peer-to-peer forward rule is missing. Check

```sh
iptables -S FORWARD | grep wireguard
```

— you need `-i wg0 -o wg0 accept` *before* the `-i wg0 drop` rule. The
wg-easy firewall chain must list `10.8.0.0/24` in the client's allowed
range so peer-to-peer stays possible.

**Peer can reach the internet through the VPS.** Either
`WG_ALLOWED_IPS` in the client config got set to `0.0.0.0/0` (check
in the UI) or the `wireguard-closed-forward` rule is missing.

### Split-tunnel troubleshooting

**Peer cannot reach the cluster at all in split-tunnel mode.**
Two halves must both be in place:

```sh
# 1. Client side - is the traffic routed into the tunnel?
kubectl -n wireguard exec deploy/wg-easy -- wg show wg0 allowed-ips
#    expect: 10.42.0.0/16 and 10.43.0.0/16 listed
#    if missing -> set the global AllowedIPs in the wg-easy UI and
#    re-download the client config

# 2. Server side - is wg-easy's firewall chain doing its job?
sudo iptables -S FORWARD | grep WG-FILTER
#    expect: -A FORWARD -i wg0 -j WG-FILTER   (at position 1)
sudo iptables -S WG-FILTER
#    expect: one ACCEPT per client for its allowed range,
#             then a final -j DROP
#    if the chain is missing -> the firewall is not enabled in the UI
```

Also confirm the peer is not sending the traffic outside the tunnel:

```sh
# From the peer
traceroute 10.43.9.131     # first hop must be 10.8.0.1
ip route get 10.43.9.131   # must show "dev wg0"
```

**The rules are visible but traffic is still blocked.** Check that the
`WG-FILTER` chain is actually jumped to at position 1 of FORWARD:

```sh
sudo iptables -S FORWARD | head -3
#    expect: -A FORWARD -i wg0 -j WG-FILTER
```

If it is not first, wg-easy's `-i wg0 -j ACCEPT` is deciding the
outcome instead. Also check the client's own entry inside the chain:

```sh
sudo iptables -S WG-FILTER
```

**`nft list ruleset` shows nothing useful.** `flush ruleset` in the old
`setup-nftables.sh` also wipes kube-proxy's tables (`ip filter`,
`ip nat`, hundreds of `KUBE-*` chains) and the connection to the k3s API
server briefly breaks. Do not run `setup-nftables.sh`; use wg-easy's
built-in firewall instead.

**Peer reaches the cluster but the Vault route returns 404.**
Traefik has no route matching the hostname. The public route
`vault.matiix310.dev` was removed; the VPN route matches
`vault.vpn.matiix310.dev`. Check the Host header / URL the peer uses,
and that peer-local DNS maps it to `10.43.9.131`:

```sh
kubectl -n kube-system logs deploy/traefik --tail=100 | grep -i vault
```

**Peer reaches the cluster but the Vault route times out.**
The connection is probably going out to the public IP instead of through
the tunnel, because `vault.vpn.matiix310.dev` resolved to
`51.68.191.40`. The public IP is not in the client's `AllowedIPs`, so the
peer sends it to its own gateway. Point the peer at the ClusterIP
`10.43.9.131` via peer-local DNS.

**Peer reaches the cluster but TLS fails with a certificate error.**
`vault.vpn.matiix310.dev` is covered by its own certificate
(`vault-vpn-tls`), not by the `vault-tls` one. Check that it was issued:

```sh
kubectl -n wireguard get certificate vault-vpn-tls
kubectl -n wireguard get secret vault-vpn-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -text | grep -A1 "Alternative Name"
```

If the peer connects to the ClusterIP `10.43.9.131` instead of the
hostname, TLS validation fails because the certificate is issued for
`vault.vpn.matiix310.dev`. Use the hostname in the URL, or
`VAULT_SKIP_VERIFY=true` for a quick test.

**Everything works but the peer can still reach the host.**
The `DROP` is missing from the **legacy iptables** chain, or wg-easy's
`-i wg0 -j ACCEPT` is evaluating first. Compare:

```sh
iptables -S INPUT | grep wireguard
#    expect: -A INPUT -i wg0 -j DROP ... at position 1

iptables -S FORWARD | grep wireguard
#    expect the closed-forward DROP to be FIRST, ahead of wg-easy's
#    "-i wg0 -j ACCEPT"

nft list table inet filter | grep wireguard
#    expect: iifname "wg0" drop comment "wireguard-closed-input"
```

wg-easy's firewall chain ends with `-j DROP`, which keeps the host
closed in both modes.

**The `INIT_ALLOWED_IPS` change had no effect.**
Expected: `INIT_*` env vars are read only when the SQLite DB is empty.
Set the global `AllowedIPs` in the wg-easy UI instead
(`Configuration` page), then re-download the client configs.

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
    setup-nftables.sh   <- host script: write /etc/nftables.conf (closed network)
                        <-   NOT used for the split tunnel; wg-easy's own
                        <-   per-client firewall does that (see above)
    kustomization.yaml
    deployment.yaml     <- wg-easy, hostNetwork, NET_ADMIN, INIT_ALLOWED_IPS
    service.yaml        <- ClusterIP on TCP 51821 (the UI)
    ingress.yaml        <- Traefik IngressRoute for wg.matiix310.dev
    certificate.yaml    <- cert-manager cert
    secret.yaml         <- VaultSecret → wg-easy-credentials Secret
    certificate-vpn.yaml
                        <- cert-manager cert for vault.vpn.matiix310.dev
    vault-vpn-route.yaml
                        <- Traefik IngressRoute + ServersTransport for the
                           VPN-only Vault hostname
  argo/wireguard.yaml   <- ArgoCD Application
```

> **Note.** `service.yaml` and `ingress.yaml` (the wg-easy **web UI** on
> `wg.matiix310.dev`) are described here but are **not currently in the
> repo** — `kustomization.yaml` lists only `deployment.yaml`,
> `secret.yaml`, `certificate-vpn.yaml` and `vault-vpn-route.yaml`. The
> UI is therefore reachable on the pod IP / port 51821 only, not through
> Traefik. Add those two files if you want the UI on
> `wg.matiix310.dev`; remember the port rule (Service `port` must equal
> the container port 51821).
