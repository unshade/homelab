# Router: Mikrotik + Terraform

A Mikrotik router sits behind the existing home network (gateway `192.168.1.254`, DNS
`192.168.1.253`) and creates an isolated network for the homelab, `10.200.0.0/24` - same
addressing convention as [yyewolf/infra](https://github.com/yyewolf/infra/tree/main/router),
which this is adapted from. Managed with Terraform (`terraform-routeros` provider), config as
code the same way the rest of this repo works.

**No wrapper script.** Every step below is a plain `terraform`/`sops`/`gpg` command, run by
hand - same philosophy as [`talos/README.md`](../talos/README.md): more boilerplate, nothing
hidden.

**Status: not deployed yet.** This is the Terraform config and the plan for how to bring it up;
the router itself hasn't been touched. See "Cutover checklist" at the bottom for what's still
manual/live/not-yet-done, in particular re-IPing the Talos nodes onto this new network.

## Topology

```
Internet
  |
ISP router (192.168.1.254, DNS .253) - unchanged
  |
  |-- existing 192.168.1.0/24 devices (Proxmox host .201, your laptop/phone, etc.)
  |
  '-- Mikrotik WAN (ether1, static 192.168.1.5/24 - see "First-time router setup")
        |
        '-- Mikrotik LAN bridge, 10.200.0.0/24
              |-- talos-cp1, talos-cp2 (once re-IP'd - see cutover checklist)
              '-- WireGuard interface (10.200.255.0/24) - see below
```

The Mikrotik is a **second router behind the first one**, not a replacement for it - the
existing gateway/DNS/Proxmox host keep their `192.168.1.x` addresses untouched. Only the
homelab's own network segment moves to `10.200.0.0/24`.

## Addressing

| | |
|---|---|
| LAN subnet | `10.200.0.0/24`, gateway `10.200.0.1` (the router) |
| Static range | `.2`-`.99` - Talos nodes, Cilium's LoadBalancer pool, anything else that needs a fixed address |
| DHCP pool | `.100`-`.199` - everything else (phones, laptops when physically on this LAN, etc.) |
| WireGuard | `10.200.255.0/24`, kept deliberately separate from the LAN subnet so tunnel and LAN addresses never collide. Router is `10.200.255.1` |

Suggested statics once the cutover happens (not applied yet - see checklist):

| Host | Address | Notes |
|---|---|---|
| talos-cp1 | `10.200.0.252` | keeps the same last octet as the old `192.168.1.252`, for continuity |
| talos-cp2 | `10.200.0.206` | same, from `192.168.1.206` |
| Cilium LoadBalancer pool | `10.200.0.220`-`10.200.0.245` | replaces the old `192.168.1.590`-`.200` pool |

## WireGuard: local access from the upstream network

This is **not** the friend's reference site-to-site tunnel to a cloud edge node (that's for
later, when public ingress moves off the current VPS setup - see the root README's Ingress
section for how that's done today). This is simpler: a road-warrior tunnel so a device
physically on the upstream `192.168.1.0/24` network (your laptop on the home WiFi, say) can
reach the otherwise-isolated `10.200.0.0/24` homelab segment without being cabled into one of
the Mikrotik's LAN ports.

Because the client and the router's WAN interface are both already on `192.168.1.0/24`, the
tunnel endpoint is just the router's own upstream address - no port-forward on the ISP router,
no dynamic DNS needed. (Exposing this same tunnel to the public internet later, for access away
from home, would need both of those - the module doesn't need to change, just how it's reached.)

**Adding a client (e.g. your laptop):**
```bash
# on the client
wg genkey | tee privatekey | wg pubkey > publickey
```
Add an entry to `router/terraform.tfvars` (gitignored - see below, public keys aren't secret but
this file is where per-deployment values that aren't worth committing to `variables.tf`'s
defaults live):
```hcl
wireguard_peers = {
  laptop = {
    public_key = "<contents of publickey>"
    address    = "10.200.255.2/32"
  }
}
```
Then the client's own `wg0.conf`:
```ini
[Interface]
PrivateKey = <contents of privatekey>
Address = 10.200.255.2/32

[Peer]
PublicKey = <router's WireGuard public key - wg pubkey against secrets.wg_private_key>
Endpoint = <var.wan_address's host part, e.g. 192.168.1.5>:51820
AllowedIPs = 10.200.0.0/24, 10.200.255.0/24
PersistentKeepalive = 25
```
`terraform apply` (see "Day-to-day" below) to push the new peer to the router.

## First-time router setup (once, before Terraform ever runs)

Done via Winbox or the router's serial/USB console, not Terraform - Terraform only manages
config on a router it can already reach and authenticate against.

1. **Start from a blank config.** If this is a fresh router, skip RouterOS's "quick set"/defconf
   wizard entirely (choose "none"/blank configuration) so it doesn't create its own bridge/DHCP/
   firewall on `192.168.88.0/24` that Terraform would then be fighting. If it's not fresh,
   `/system reset-configuration no-defaults=yes` wipes it back to blank first.
2. **Set a real admin password immediately:**
   ```
   /user set admin password=<strong password>
   ```
3. **Enable the REST API Terraform talks to, over HTTPS:**
   ```
   /certificate add name=api-cert common-name=mikrotik-router
   /certificate sign api-cert
   /ip service set www-ssl certificate=api-cert disabled=no
   /ip service disable telnet,ftp,www,api
   ```
   Exact command syntax can drift slightly by RouterOS version - check `/ip service print` and
   [Mikrotik's own docs](https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API) for
   your specific version if any of this errors.
4. **Assign the static WAN address by hand, once.** Terraform's own provider block needs an
   address to reach the router at before it can apply anything - including the very config that
   would normally set that address - so this one has to be created manually first:
   ```
   /ip address add address=192.168.1.5/24 interface=ether1
   ```
   Double-check `192.168.1.5` is actually free on the upstream network first (`ping`/`arp -a`
   from another device on it) - this repo doesn't have visibility into every device on
   `192.168.1.0/24`, only the ones in the root README's "Cluster facts" table. Pick a different
   address and update `wan_address` in `router/variables.tf` (or override it in
   `terraform.tfvars`) if `.1` turns out to be taken.
5. **Adopt that address into Terraform state**, so the first real `terraform apply` reconciles
   with it instead of trying to create a conflicting duplicate. From `router/`, after `terraform
   init` (see "Day-to-day" below):
   ```bash
   terraform import module.wan.routeros_ip_address.wan "$(id-shown-by-ip-address-print)"
   ```
   The id is whatever `/ip address print` shows for the entry just created (RouterOS's own
   internal id, of the form `*1`) - check there rather than assuming, and consult the
   [terraform-routeros provider docs](https://registry.terraform.io/providers/terraform-routeros/routeros/latest/docs/resources/ip_address)
   if `terraform import`'s id format has changed since this was written. After a successful
   import, `terraform plan` should show no changes for this resource - if it wants to change the
   address/interface/comment, the manually-created one doesn't match `var.wan_address`/
   `var.wan_interface` and one of the two needs to be fixed before continuing.

## Secrets

`router-sops.yaml` holds the RouterOS admin credentials and the router's own WireGuard private
key. Copy the template and fill in real values before encrypting:
```bash
cd router
cp router-sops.yaml.example router-sops.yaml
$EDITOR router-sops.yaml   # fill in secrets.username/password/wg_private_key
sops -e -i router-sops.yaml
```
This uses the same `*-sops.yaml` pattern and GPG key (`0838E38422232D44B96B6C7659A7C95E7A016E5A`)
as the rest of this repo - see the root README's "Secrets" section and
[`talos/README.md`](../talos/README.md)'s for the full explanation of how SOPS is set up here.
To edit it later: `sops router-sops.yaml` opens it decrypted in `$EDITOR` and re-encrypts on
save, no separate decrypt/encrypt step needed for in-place edits.

**Terraform state also needs encryption** - it contains the plaintext admin password and
WireGuard private key once applied (Terraform state is not itself SOPS-aware). Kept as a single
GPG-encrypted blob, matching the reference repo, decrypted before each command and re-encrypted
after:
```bash
cd router
gpg --decrypt --output terraform.tfstate terraform-state.gpg   # skip on the very first apply, no state exists yet
terraform init
terraform plan    # or apply
gpg --encrypt --yes --recipient 0838E38422232D44B96B6C7659A7C95E7A016E5A \
  --output terraform-state.gpg terraform.tfstate
rm terraform.tfstate terraform.tfstate.backup
git add terraform-state.gpg
git commit -m "..."
```
Never commit `terraform.tfstate` itself (it's gitignored, but double check `git status` anyway
before committing - same hygiene rule as everywhere else secrets touch this repo).

## Day-to-day

```bash
cd router
gpg --decrypt --output terraform.tfstate terraform-state.gpg
terraform plan
terraform apply
gpg --encrypt --yes --recipient 0838E38422232D44B96B6C7659A7C95E7A016E5A \
  --output terraform-state.gpg terraform.tfstate
rm terraform.tfstate terraform.tfstate.backup
```

Non-secret, deployment-specific values (WireGuard peers, or an override for `wan_address` if
`.1` turned out to be taken) go in `router/terraform.tfvars` (gitignored - it's not committed
since it's local/environment specific, not because it's sensitive; public keys aren't secrets).
Example:
```hcl
wireguard_peers = {
  laptop = {
    public_key = "..."
    address    = "10.200.255.2/32"
  }
}
```

Adding a new hostname/port-forward, a new LAN device's static reservation, a new WireGuard peer,
etc. - edit `router/main.tf`/`variables.tf`/`terraform.tfvars`, `terraform plan` to review, then
`terraform apply`.

## Cutover checklist (not done yet)

Everything above is safe to write and even `terraform apply` on its own - it only configures the
router itself, nothing on the existing cluster changes as a result. Actually putting the homelab
*behind* this router is a separate, higher-stakes step: it means the Talos nodes lose their
current `192.168.1.252`/`.206` addresses and everything that references them needs to move in
lockstep, or the cluster becomes unreachable mid-cutover. Do this as its own deliberate session,
one step verified before the next, not as a batch:

1. **Physical**: cable the Proxmox host into one of the Mikrotik's LAN ports (directly, or via a
   dedicated VLAN/bridge on the existing switch) - the Talos VMs' virtual NICs need to attach to
   a Proxmox bridge that reaches the Mikrotik's LAN side, not the current one facing
   `192.168.1.0/24`. Proxmox's own management address (`192.168.1.201`) can stay where it is if
   the host is dual-homed (a second bridge on a second NIC/VLAN) - only the two Talos VMs' NICs
   need to move.
2. **Re-IP one node at a time**, same one-at-a-time-with-verification discipline as any other
   Talos machine-config change (see `talos/README.md`'s "Changing the machine config"):
   `talos/patches/talos-cp1.yaml`/`talos-cp2.yaml` addresses move from `192.168.1.252/24` /
   `192.168.1.206/24` to `10.200.0.252/24` / `10.200.0.206/24`, gateway `10.200.0.1`.
3. **Update everything else still hardcoded to the old addresses**: `cluster.controlPlane.endpoint`
   in `talos/patches/common.yaml` (currently `192.168.1.252`), Cilium's `k8sServiceHost` Helm
   value (`clusters/homelab/apps/cilium/release.yaml`), and the `CiliumLoadBalancerIPPool` range
   in `clusters/homelab/apps/cilium-config/lb-pool.yaml` (currently `192.168.1.590`-`.200`, move
   to `10.200.0.220`-`.245` per the addressing table above).
4. **ZFS NFS export ACL**: the Proxmox host's `zfs set sharenfs="rw=@192.168.1.252/32:..."` (see
   root README's ZFS section) is keyed to the nodes' old IPs and needs updating to the new ones,
   or NFS mounts (`nfs-csi`) break.
5. **Verify** at each step the same way the Talos patches restructure was verified before it went
   live: `talosctl services`, `kubectl get nodes`, `talosctl etcd members`, a cluster-wide
   non-`Running` pod sweep, before moving to the next node or the next hardcoded reference.

This is exactly the kind of hard-to-reverse, whole-cluster-reachability-affecting change worth
doing together interactively rather than scripted end-to-end - keep Proxmox console access
(VNC/serial) to each VM handy throughout in case a node becomes unreachable over the network
mid-change.
