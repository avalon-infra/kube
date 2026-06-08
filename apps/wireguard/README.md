# WireGuard on the VPS — closed network setup

A personal WireGuard VPN that connects your phone and laptop together over
the VPS, but does **not** let them reach the VPS itself or the internet
through the VPS. The peers form a small isolated mesh.

The WireGuard kernel interface (`wg0`) and `wg-quick` live on the VPS host
so the tunnel stays up independently of k3s. The web UI (`wireguard-ui`)
runs in Kubernetes so it gets the existing cert-manager / Traefik / Vault
infrastructure for free.

## What "closed network" means here

```
  Phone (10.8.0.2)  <---->  Laptop (10.8.0.3)
        \                    /
         \                  /
          --->  VPS wg0  <---
                (10.8.0.1, but unreachable from clients)
```

- Phone can talk to Laptop and vice versa.
- Phone/Laptop **cannot** reach `10.8.0.1` (the VPS's `wg0` IP) — dropped
  by a host nftables rule on traffic arriving from `wg0`.
- Phone/Laptop **cannot** reach any other IP on the VPS (public IP,
  k3s service IPs, MetalLB IPs, etc.) for the same reason.
- Phone/Laptop **cannot** reach the internet through the VPS — no IP
  forwarding and no NAT/MASQUERADE.
- Phone/Laptop still use their own local network for internet (split
  tunnel by design).

## Architecture

```
  ┌───────────────────────────────────────────────────────────┐
  │ VPS                                                       │
  │                                                           │
  │  Host (systemd)               k3s                         │
  │  ─────────────                ───                         │
  │  wg-quick@wg0                 wireguard-ui pod            │
  │   └── wg0 interface           └── mounts                  │
  │       (10.8.0.1/24)               /etc/wireguard          │
  │   └── reads /etc/wireguard/   └── UI at wg.matiix310.dev  │
  │       wg0.conf (hostPath)         (Traefik + cert-manager)│
  │                                                           │
  │  wgui-reload.path  watches wg0.conf, runs                 │
  │  `wg syncconf wg0 <(wg-quick strip ...)` to apply         │
  │  changes live when the UI saves.                          │
  │                                                           │
  │  nftables: accept UDP 51820 on eth0, drop input from wg0  │
  └───────────────────────────────────────────────────────────┘
```

## Prerequisites

- Debian 12+ (k3s host). WireGuard is in the mainline kernel — no DKMS.
- DNS record for `wg.matiix310.dev` → VPS public IP.
- Vault reachable; the `vault-secrets-operator` already deployed in
  the cluster.
- `kubectl` and `vault` CLI on your workstation for the bootstrap.

## One-time setup

### 1. Install WireGuard on the host

Run as root on the VPS:

```sh
apt update && apt install -y wireguard
umask 077
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key
```

The public key is what goes into each peer's config — note it down.

### 2. Write `/etc/wireguard/wg0.conf`

10.8.0.0/24 is the VPN subnet. The server sits at `.1`; peers get
`.2`, `.3`, etc. Note: **no** `PostUp`/`PostDown` MASQUERADE and
**no** IP forwarding — those are deliberately absent for the closed
network.

```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <contents of /etc/wireguard/server_private.key>
```

```sh
chmod 600 /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0
wg show   # expect a wg0 interface with port 51820
```

### 3. Configure nftables for the closed network

Two nftables rules turn this into a closed network:

- accept UDP 51820 on the public interface — so WireGuard handshakes
  reach the server from the internet
- drop everything arriving on `wg0` — so peers cannot reach the host
  (10.8.0.1, the public IP, k3s, anything on the host)

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

#### Existing ruleset — add the rules by hand

If you already have a hand-written `/etc/nftables.conf` you want to
keep, just append these rules to your `input` chain (the table and
chain must exist first — the snippet in `setup-nftables.sh` is a good
template if you need to bootstrap them):

```sh
# Replace 'eth0' with your public interface (ip route | grep default)
nft add rule inet filter input tcp dport { 80, 443 } ct state new accept comment "http(s)"
nft add rule inet filter input tcp dport 6443 ct state new accept comment "k3s-api"
nft add rule inet filter input udp dport 51820 iifname "eth0" accept comment "wireguard-in"
nft add rule inet filter input iifname "wg0" drop comment "wireguard-closed"

# Closed network — drop wg0 forward too (defence in depth).
# Policy on 'forward' should otherwise be 'accept' so k3s ingress works.
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
# then add the two rules above
```

### 4. Live-reload watcher for UI changes

The `wireguard-ui` pod writes to `/etc/wireguard/wg0.conf` (mounted
via `hostPath`) when you save peers. `wg-quick@wg0` only reads the
file at start, so we need a watcher to apply changes live.

```sh
cat > /etc/systemd/system/wgui-reload.service <<'EOF'
[Unit]
Description=Apply wg0.conf changes from wireguard-ui
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'wg syncconf wg0 <(wg-quick strip /etc/wireguard/wg0.conf)'
EOF

cat > /etc/systemd/system/wgui-reload.path <<'EOF'
[Unit]
Description=Watch /etc/wireguard/wg0.conf for changes
[Path]
PathChanged=/etc/wireguard/wg0.conf
Unit=wgui-reload.service
[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now wgui-reload.path
```

After this, every UI save reapplies the config without dropping the
interface or interrupting existing peers.

### 5. Kubernetes manifests

Files in this repo (already committed on the feature branch, apply with
ArgoCD or `kubectl apply -k`):

- `apps/wireguard/deployment.yaml` — `wireguard-ui` with `hostPath`
  mount of `/etc/wireguard`, `WGUI_MANAGE_START_WG=false` so the host
  stays the single source of truth for the interface, password pulled
  from the Vault-backed Secret.
- `apps/wireguard/service.yaml` — ClusterIP on TCP 5000.
- `apps/wireguard/ingress.yaml` — Traefik `IngressRoute` for
  `wg.matiix310.dev`.
- `apps/wireguard/certificate.yaml` — `cert-manager` Certificate
  using the `prod-cluster-issuer` ClusterIssuer.
- `apps/wireguard/secret.yaml` — `VaultSecret` that materialises a
  Kubernetes Secret named `wireguard-ui-credentials` with a single
  `password` key.
- `argo/wireguard.yaml` — ArgoCD `Application` pointing at
  `apps/wireguard/`.

### 6. Vault password for the UI

The operator expects a path with a single `password` key:

```sh
vault kv put secret/kvv2/wireguard-ui/data \
  password=$(openssl rand -base64 32)
```

The `VaultSecret` resource will pick it up and create a Kubernetes
Secret `wireguard-ui-credentials`.

### 7. Roll it out

```sh
git add apps/wireguard argo/wireguard.yaml
git commit -m "feat(wireguard): add wireguard-ui + closed-network host setup"
git push
```

ArgoCD reconciles `argo/wireguard.yaml` and deploys the UI. First time
the pod starts it will see the host's hand-written `wg0.conf` and
import it; the `wgui-reload.path` will fire once and the interface
state will be unchanged.

## Adding a peer

1. Open `https://wg.matiix310.dev`, log in with `admin` / the Vault
   password.
2. Add a new client. For each peer:
   - **Name**: anything (`phone`, `laptop`).
   - **Address**: the next free IP in `10.8.0.0/24` (e.g. `10.8.0.2`
     for the first peer, `10.8.0.3` for the second, etc.).
   - **Allowed IPs (client side)**: this is the critical field for the
     closed network. Set it to `10.8.0.0/24` so this peer can route to
     every other peer on the subnet. (If you set it to just the
     peer's own `/32`, the peer can only talk to itself.)
3. Click **Apply** / **Save**. The `wgui-reload.path` unit on the host
   fires, runs `wg syncconf`, and the new peer is live within ~1s.
4. Either:
   - Scan the QR code with the WireGuard app on the phone, or
   - Download / copy the `.conf` and import it on the laptop with
     `wg-quick up ./peer.conf` or the WireGuard desktop app.

You do **not** need to restart `wg-quick@wg0` or the `wireguard-ui`
pod. Existing peers keep their connections across UI saves.

## Verifying the closed network

From a peer (phone or laptop) connected to the VPN:

```sh
# Should succeed — peer-to-peer traffic
ping 10.8.0.<other-peer-ip>

# Should FAIL — closed network
ping 10.8.0.1                  # server's wg0 IP, dropped by nftables
ping <VPS-public-IP>           # host's other interfaces, also dropped
curl https://example.com       # internet: no IP forwarding → no route
```

From the VPS:

```sh
wg show                        # see handshake timestamps + transfer stats per peer
nft list chain inet filter input | grep wireguard
```

## Troubleshooting

**UI is up but adding a peer has no effect on the live interface.**
Check that the path unit is active: `systemctl status wgui-reload.path`.
If it's not, `systemctl enable --now wgui-reload.path`. Then make a
trivial edit in the UI and save — `/var/log/syslog` should show the
service firing.

**A peer can ping the server's public IP.** That means the
`iifname "wg0" drop` rule is missing or in the wrong chain. Re-check
with `nft list ruleset`. Make sure your rule is *before* any allow
rule that might match it (the chain order matters).

**A peer can reach the internet through the VPS.** Either IP
forwarding is on (`sysctl net.ipv4.ip_forward` should be `0`) or a
MASQUERADE rule slipped in. `wg0.conf` should have no `PostUp`
forwarding/MASQUERADE lines.

**Handshake never completes.** UDP 51820 not open on the public
interface, or the server is behind a NAT you forgot about. From
outside the VPS: `nc -uvz <vps-public-ip> 51820`. From the VPS:
`wg show` should still show the interface listening.

**`wireguard-ui` pod won't start.** Almost always the
`wireguard-ui-credentials` Secret doesn't exist yet. Check
`kubectl describe vaultsecret -n wireguard` and confirm the Vault
path is reachable. The pod's `imagePullPolicy: IfNotPresent` will not
help here — the pod keeps CrashLoopBackOff-ing until the Secret
materialises.

**Permission denied writing to `/etc/wireguard/wg0.conf` from the
pod.** The `wireguard-ui` image runs as root by default and can write
to a `hostPath` mount. If you've customised the SecurityContext, the
UID must own the directory. The host's `wg-quick@wg0` only needs read
access to the file (mode 600 is fine for the host service).

## Uninstall

```sh
# Tear down the interface
systemctl disable --now wg-quick@wg0 wgui-reload.path
wg-quick down wg0

# Remove files
rm -f /etc/wireguard/wg0.conf
rm -f /etc/systemd/system/wgui-reload.{path,service}
systemctl daemon-reload

# Remove the nftables rules
nft delete rule inet filter input handle $(nft -a list chain inet filter input | grep wireguard-closed | grep -oP 'handle \K\d+')
# (or edit /etc/nftables.conf and `nft -f` it)

# Remove the k8s app
kubectl delete -n argocd -f argo/wireguard.yaml
# Then remove the files from the repo in a follow-up commit
```

## File map

```
  apps/wireguard/
    README.md           <- this file
    setup-nftables.sh   <- host script: write /etc/nftables.conf
    kustomization.yaml
    deployment.yaml     <- wireguard-ui, hostPath /etc/wireguard
    service.yaml        <- ClusterIP on TCP 5000
    ingress.yaml        <- Traefik IngressRoute for wg.matiix310.dev
    certificate.yaml    <- cert-manager cert
    secret.yaml         <- VaultSecret → wireguard-ui-credentials Secret
  argo/wireguard.yaml   <- ArgoCD Application
```