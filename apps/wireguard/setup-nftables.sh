#!/usr/bin/env bash
# setup-nftables.sh — Configure nftables for the closed-network WireGuard setup.
#
# Usage:  sudo bash setup-nftables.sh [public_interface]
#   public_interface  defaults to the interface holding the default route
#                      (override with this argument, e.g. ens3 or eth0)
#   NFT_CONF          override the target config path (default: /etc/nftables.conf)
#
# What it does:
#   - Writes /etc/nftables.conf with a base input/forward/output policy
#   - Accepts UDP 51820 on the public interface (WireGuard handshakes)
#   - Drops everything arriving on wg0 (closed network: peers cannot reach
#     the host itself, the public IP, or k3s)
#   - Enables and (re)starts the nftables service
#
# Re-running is safe if /etc/nftables.conf already contains wireguard rules.
# If the file exists and contains no wireguard rules, the script refuses to
# overwrite it — back it up, merge the rules by hand, and re-run.

set -euo pipefail

IFACE="${1:-$(ip route | awk '/default/ {print $5; exit}')}"
CONF="${NFT_CONF:-/etc/nftables.conf}"

if [[ -z "${IFACE:-}" ]]; then
  echo "ERROR: could not detect a default-route interface." >&2
  echo "Pass it explicitly, e.g.:  sudo bash $0 ens3" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (sudo bash $0 ...)" >&2
  exit 1
fi
if ! command -v nft >/dev/null 2>&1; then
  echo "ERROR: nft is not installed. Run:  apt update && apt install -y nftables" >&2
  exit 1
fi

if [[ -f "$CONF" ]] && [[ -s "$CONF" ]] && ! grep -q "wireguard" "$CONF"; then
  cat >&2 <<EOF
ERROR: $CONF exists and has no wireguard rules.

This script will not overwrite an unrelated ruleset. If you have a
hand-written config you want to keep, back it up and merge the
wireguard rules from this script by hand (or from the README's
"First-time nftables setup" section).

To force a clean install:
  sudo mv $CONF ${CONF}.bak
  sudo bash $0 $IFACE
EOF
  exit 1
fi

cat > "$CONF" <<NFT_EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Loopback
        iif "lo" accept comment "loopback"

        # Established / related (responses to outgoing connections)
        ct state established,related accept comment "established"

        # ICMPv6 (router solicits, neighbour discovery, errors)
        ip6 nexthdr ipv6-icmp icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert, mld-listener-query } accept comment "icmpv6"
        ip6 nexthdr ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept comment "icmpv6-errors"

        # SSH
        tcp dport 22 ct state new accept comment "ssh"

        # HTTP / HTTPS — k3s ingress (Traefik / ingress-nginx) on this host
        tcp dport { 80, 443 } ct state new accept comment "http(s)"

        # k3s API server — needed for "kubectl" from outside the host.
        # Comment this out if you only ever run kubectl from the VPS itself
        # or via "ssh -L 6443:localhost:6443".
        tcp dport 6443 ct state new accept comment "k3s-api"

        # WireGuard handshakes on the public interface
        udp dport 51820 iifname "$IFACE" accept comment "wireguard-in"

        # Closed network: drop everything arriving on wg0 so peers
        # cannot reach the host (10.8.0.1, public IP, k3s, anything).
        iifname "wg0" drop comment "wireguard-closed"
    }

    chain forward {
        type filter hook forward priority filter; policy accept;

        # k3s ingress traffic is FORWARDed (DNAT'd by kube-proxy from the
        # public IP to a pod IP), so the policy must be accept. We only
        # drop traffic that originated on wg0 — the closed network.
        iifname "wg0" drop comment "wireguard-closed-forward"
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
NFT_EOF

systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart nftables

echo
echo "nftables configured for public interface: $IFACE"
echo
echo "Active ruleset:"
echo "---"
nft list ruleset
