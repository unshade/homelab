# VPS ingress (replaces Cloudflare Tunnel)

This VPS (`debian@179.237.107.136`) is the public entry point for `*.nstnr.com`. It does
**not** terminate TLS — it's a raw TCP relay (HAProxy, `mode tcp`, PROXY protocol v2) over a
WireGuard tunnel to a pod inside the homelab cluster, which relays again to Envoy Gateway, which
does the real TLS termination. See the top-level README's ingress section and
`clusters/homelab/apps/wireguard/` for the cluster side.

## 1. WireGuard (native, not Docker)

Kernel WireGuard + `NET_ADMIN` in a container buys nothing on a dedicated box — native
`wg-quick` + systemd is the standard way to run a persistent site-to-site tunnel here.

```bash
sudo apt update && sudo apt install -y wireguard-tools
sudo install -o root -g root -m 600 wireguard/wg0.conf /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
sudo wg show   # should show the peer once the in-cluster pod is up and dials in
```

This VPS is the WireGuard listener (`ListenPort 51820` — make sure UDP/51820 is open in any
VPS-provider firewall/security group, in addition to TCP/80 and TCP/443). The in-cluster pod
dials out to it, so no other inbound port is needed.

## 2. HAProxy (Docker)

```bash
cd haproxy
docker compose up -d
docker compose logs -f
```

Test end-to-end *before* touching DNS (once the in-cluster tunnel is confirmed up):

```bash
curl -k --resolve immich.nstnr.com:443:127.0.0.1 https://immich.nstnr.com/
```

## 3. DNS cutover

Point `*.nstnr.com` at `179.237.107.136`, **DNS-only / grey-cloud** (not Cloudflare-proxied) —
proxying would re-terminate TLS at Cloudflare's edge and defeat the whole point of TLS
passthrough + real source IP.

## Adding a new hostname later

Nothing to change here — there's no SNI-based routing, every hostname already relays to the
same single Envoy Gateway backend. Just point DNS at this VPS's IP and add the corresponding
`HTTPRoute` in the cluster.
