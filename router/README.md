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
  |-- existing 192.168.1.0/24 devices (Proxmox host `nas` - vmbr0/nic3, .201 - your laptop/phone, etc.)
  |
  '-- Mikrotik WAN (ether1, static 192.168.1.5/24 - see "First-time router setup")
        |
        '-- Mikrotik LAN bridge, 10.200.0.0/24
              |-- Proxmox host `nas`, second bridge vmbr1/nic0, 10.200.0.20 - dual-homed,
              |     vmbr0 untouched (see cutover checklist)
              |-- talos-cp1, w-1 - each dual-homed via a second vNIC once added - see checklist
              '-- WireGuard interface (10.200.255.0/24) - see below
```

The Mikrotik is a **second router behind the first one**, not a replacement for it - the
existing gateway/DNS/Proxmox host keep their `192.168.1.x` addresses untouched. Only the
homelab's own network segment moves to `10.200.0.0/24`. `nas` has 4 physical NICs (`nic0`-`nic3`)
but only `nic3`/`vmbr0` is in use - one of the 3 spare ports is what carries the new network to
the host and VMs, so `vmbr0`/`192.168.1.201` never has to change.

## Addressing

| | |
|---|---|
| LAN subnet | `10.200.0.0/24`, gateway `10.200.0.1` (the router) |
| Static range | `.5`-`.99` - Talos nodes, Cilium's LoadBalancer pool, anything else that needs a fixed address |
| DHCP pool | `.100`-`.199` - everything else (phones, laptops when physically on this LAN, etc.) |
| WireGuard | `10.200.255.0/24`, kept deliberately separate from the LAN subnet so tunnel and LAN addresses never collide. Router is `10.200.255.1` |

Statics for the cutover (not applied yet - see checklist below). Trimmed from the old
`192.168.1.x` last octet to fit the narrower `.5`-`.99` static range (`.252`→`.52`, `.206`→`.6`)
rather than reusing the old `.206`/`.252`/`.220`-`.245`, which would now fall inside the DHCP
pool and risk a lease colliding with a statically-pinned Talos address:

| Host | Address | Notes |
|---|---|---|
| `nas` (Proxmox host, `vmbr1`) | `10.200.0.20` | new - `vmbr0`/`192.168.1.201` is untouched, dual-homed |
| talos-cp1 | `10.200.0.52` | from `192.168.1.252` |
| w-1 | `10.200.0.6` | from `192.168.1.206` |
| Cilium LoadBalancer pool | `10.200.0.70`-`10.200.0.85` | replaces the old `192.168.1.190`-`.200` pool |

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
one step verified before the next, not as a batch.

**The key trick that makes this near-zero-downtime and reboot-free: everything can be dual-homed
- host and both VMs - entirely live, and the physical cabling has zero timing pressure since it
happens before anything about traffic routing changes.** `nas` has 4 physical NICs (`nic0`-`nic3`)
but only `nic3`/`vmbr0` is in use; one of the 3 spare ports carries the new network in without
ever touching `vmbr0`/`192.168.1.201`. Each Talos VM gets a **second virtual NIC** (hot-added,
live, no VM reboot) attached to that new bridge, so it ends up with two real network interfaces -
the existing `ens18` (old network, untouched) and a new `ens19` (new network) - rather than two
addresses squeezed onto one interface fighting over a single physical link. The only genuinely
disruptive moment left is flipping which interface carries the default route, which is a single
live `apply-config` with no physical action attached to it at all.

### Phase 0 - Proxmox host: add the second bridge (fully live, zero risk to `vmbr0`)

1. Cable one of the unused ports (`nic0`/`nic1`/`nic2`) to a Mikrotik LAN port. Check
   *Datacenter → nas → System → Network* - whichever port flips to `Active: Yes` is the one you
   just plugged in.
2. *Network → Create → Linux Bridge*:
   - Name: `vmbr1`
   - IPv4/CIDR: `10.200.0.20/24`
   - Gateway: **leave empty** - the host should keep exactly one default route (via `vmbr0`/
     `192.168.1.254`); giving `vmbr1` a gateway too would create two default routes on the host
     itself and invite asymmetric-routing weirdness for no benefit, since `nas` doesn't need to
     reach the internet over the new segment.
   - Bridge ports: the NIC that just went active
   - Autostart: yes, VLAN aware: no
3. *Create*, then the **Apply Configuration** button (top-right, same one visible in your
   screenshot) - applies live via `ifreload`, no reboot, doesn't touch `vmbr0`/`nic3` at all.
4. Verify: `ip a show vmbr1` shows `10.200.0.20/24`; once the Mikrotik side is live,
   `ping 10.200.0.1` from the Proxmox shell should succeed.

### Phase 1 - Talos VMs: add the second NIC and the new interface's config (fully live)

Do this any time after Phase 0; it changes nothing about how the nodes are currently reached -
`ens18` keeps its `192.168.1.x/24` address and the `192.168.1.254` default route throughout.

1. Hot-add a second vNIC to each VM, attached to `vmbr1` (find the VM IDs with `qm list`):
   ```bash
   qm set <cp1-vmid> -net1 virtio,bridge=vmbr1
   qm set <w1-vmid> -net1 virtio,bridge=vmbr1
   ```
2. Confirm Talos actually sees it and note the interface name it gets (likely `ens19`, following
   `ens18`, but confirm rather than assume - same check this repo already used when bringing up
   `talos-cp2`):
   ```bash
   talosctl -n 192.168.1.252 get links
   ```
3. Add it as a **new, separate** `interfaces:` entry - not a second address on `ens18` - with no
   *default* route, so it's scoped to just what's needed until the deliberate cutover step below.
   One thing that's easy to miss here (found live, while bringing up `talos-cp1`): the WireGuard
   road-warrior tunnel subnet (`10.200.255.0/24`) is a *different* subnet from the LAN
   `10.200.0.0/24` - so without an explicit route for it, a reply to a WireGuard client has
   nowhere to go except the default route, still on `ens18`, addressed to the *old* gateway, which
   has never heard of `10.200.255.0/24` and silently drops it. Symptom looked identical to a
   router-side firewall block (requests forwarded fine, zero replies ever came back - confirmed via
   `/ip firewall connection print detail` on the Mikrotik showing `orig-packets` climbing while
   `repl-packets` stayed at `0`) until this was added:
   ```yaml
   # talos/patches/talos-cp1.yaml
   machine:
     network:
       interfaces:
         - interface: ens18
           addresses:
             - 192.168.1.252/24
           dhcp: false
           routes:
             - network: 0.0.0.0/0
               gateway: 192.168.1.254
         - interface: ens19
           addresses:
             - 10.200.0.52/24
           dhcp: false
           routes:
             - network: 10.200.255.0/24
               gateway: 10.200.0.1
   ```
   same idea for `w-1.yaml`: `ens19` (confirm the name) with `10.200.0.6/24`, same
   `10.200.255.0/24` route. Regenerate/validate/apply exactly as `talos/README.md`'s "Changing
   the machine config" describes, one node at a time.
4. **Verify with a raw ping/`nc`, not `talosctl`.** `talosctl -n 10.200.0.52 ...` is *not* a valid
   test of this path - the client connects to whatever `endpoint` is configured
   (`192.168.1.252`, reachable directly, no tunnel needed), and `-n` just tells that same
   already-reachable `apid` "answer as if targeting this node," which it can satisfy locally
   without ever touching `ens19`. This produced a convincing false positive live - looked like a
   successful end-to-end check, wasn't. Use something that can't take that shortcut instead, from
   a machine reaching the node only via the WireGuard tunnel:
   ```bash
   ping -c 5 10.200.0.52          # from a WireGuard-connected client, not the node itself
   nc -zv -w3 10.200.0.52 6443
   ```
   Both should succeed with `0%` loss / `succeeded`. Also check `talosctl -n 192.168.1.252 get
   addresses` (over the still-working old path) shows both interfaces up, and a full health sweep
   (`talosctl services`, `kubectl get nodes`, non-`Running` pod check) - see `talos/README.md`.
   Repeat everything for `w-1`/`10.200.0.6`. At this point both nodes are fully dual-homed and
   nothing about current traffic has changed - `kubectl get nodes` may already show the new
   address as a node's `INTERNAL-IP` (kubelet's own address-detection picks it up early), which is
   cosmetic and harmless as long as `ciliumnodes`' tracked address for that node is still the old
   one (`kubectl get ciliumnodes -o yaml`) - it'll converge naturally once Phase 2/3 happen in
   order.

### Phase 2 - the actual cutover: flip the default route (the one disruptive moment, still no reboot, no physical action)

With both interfaces already up and verified, this is a single `apply-config` per node that moves
the `routes:` block from `ens18` to `ens19` - the only traffic that notices is anything using the
default route (internet-bound, cross-subnet) for the seconds it takes the route table to update;
anything reaching the node directly over either subnet is unaffected throughout:

```yaml
# talos/patches/talos-cp1.yaml
machine:
  network:
    interfaces:
      - interface: ens18
        addresses:
          - 192.168.1.252/24
        dhcp: false
      - interface: ens19
        addresses:
          - 10.200.0.52/24
        dhcp: false
        routes:
          - network: 0.0.0.0/0
            gateway: 10.200.0.1
```
```bash
talosctl -n 192.168.1.252 apply-config -f out/talos-cp1.yaml
```
same for `w-1`. Do both back to back rather than leaving one flipped and one not for long: Cilium
doesn't need L2 adjacency between nodes for pod traffic (no `routingMode` override in
`clusters/homelab/apps/cilium/release.yaml` means it's on the chart default, VXLAN tunnel), but it
does need L3 reachability between the two nodes, and nothing routes between the two subnets here.

`ens18`/`192.168.1.x` is deliberately left in place after this, not torn down immediately - it's
the rollback path while everything else in Phase 3 gets updated and verified. Remove it only once
you're fully confident (edit the patch again, drop the `ens18` block, `apply-config` once more -
zero surprises since Phase 0-2 already proved the pattern works).

Verify before moving to Phase 3: `talosctl -n 10.200.0.52 get addresses`, `talosctl services`,
`kubectl get nodes`.

### Phase 3 - everything else still hardcoded to the old addresses

None of this is in the hot path of the route-flip above - do it once both nodes are confirmed up
on `10.200.0.0/24`. Status as of the actual migration:

1. **`cluster.controlPlane.endpoint` - done, now `https://talos-api.lan:6443`** (the floating DNS
   record on the Mikrotik, `main.tf`'s `routeros_ip_dns_record.talos_api` - a purpose-named record
   rather than a literal IP, so control-plane can move to a different physical node later without
   touching this again). Getting here took **two separate incidents** in the same session, worth
   understanding fully before ever touching this field again:
   - **Incident 1**: changing `cluster.controlPlane.endpoint` alone changes the apiserver's
     `--service-account-issuer` flag too (confirmed live: `talosctl -n <ip> get staticpods
     kube-apiserver -o yaml`), which **invalidates every already-issued service-account token
     cluster-wide** - every pod using one (most of them: Flux's four controllers, cert-manager,
     cnpg, Longhorn, cilium-operator, ...) fails with `Unauthorized` immediately, and kubelet only
     refreshes a pod's mounted token on its own ~hour-long cycle, not on restart, so this doesn't
     self-heal quickly on its own. **Fix**: pin `cluster.apiServer.extraArgs.service-account-issuer`
     explicitly to kube-apiserver's own upstream default
     (`https://kubernetes.default.svc.cluster.local` - what plain kubeadm leaves it as; it's just
     an identity string compared inside already-validated tokens, never fetched, so it doesn't need
     to be a real address) - decouples it from the endpoint permanently. Confirmed no gradual
     multi-issuer migration is possible here first: `--config-patch`/`machineconfig patch` both
     reject a list-valued `extraArgs` entry outright (decoder error: `unexpected type for yaml
     sequence: v1alpha1.ArgValue`), a known unfixed upstream regression since Talos v1.12
     ([siderolabs/talos#12210](https://github.com/siderolabs/talos/issues/12210), closed as not
     planned) - a single string value patches fine, only lists are broken. So this was a direct,
     single-shot swap instead, done deliberately: fresh etcd backup, the full recovery staged
     *before* touching config (Cilium agent restart for the ClusterIP gotcha below, plus every real
     API-calling pod identified from actual RBAC bindings + running pods - ~45 of them, broader
     than the ~9 that happened to crash loudly) and fired immediately after applying, rather than
     waiting on kubelet's slow natural refresh. Total disruption: under 2 minutes.
   - **Incident 2**: with the issuer decoupled, changing `cluster.controlPlane.endpoint` alone
     *still* broke every token again - `--api-audiences` derives from the endpoint too,
     **independently of `--service-account-issuer`**, and is invisible in any config-file diff
     (Talos computes it purely internally, never rendering it as text anywhere until the live
     static pod manifest - a clean `diff` of the fully-rendered machine config genuinely shows zero
     change here, since this flag isn't derived from anything that appears in that file at all).
     Found out by actually applying the change and reading `talosctl get staticpods kube-apiserver
     -o yaml` afterward, not from any dry-run. **Fix**: same pattern - pin
     `cluster.apiServer.extraArgs.api-audiences` too, but as its own **separate, prior** step: pin
     it to its **current** value first (`https://192.168.1.252:6443` - same string, not the new
     one), which is a genuine no-op for tokens since nothing about what's currently valid changes,
     only where the value comes from. Verified live as a true no-op (full cluster-wide pod sweep
     stayed clean through the apiserver restart this still causes). *Only after* that was confirmed
     stable on its own did changing `cluster.controlPlane.endpoint` become safe - verified this time
     against the live rendered static pod manifest immediately after applying, not a config diff.
   - **`api-audiences` later advanced to its final value too** (`https://kubernetes.default.svc.
     cluster.local`, matching `service-account-issuer`), as its own separate, deliberate single-shot
     swap - same Talos limitation applies (no gradual multi-value path for this field either), same
     staged-recovery pattern (fresh etcd backup, Cilium agent restart, every real API-calling pod
     force-deleted - rebuilt fresh from live RBAC bindings each time, not reused from a prior
     incident's stale list, since pod names change on every restart). Verified against the live
     static pod manifest immediately after applying, same as always now. `ens18`'s `192.168.1.252`
     on `talos-cp1` is genuinely, fully inert as of this - nothing pins to it anymore, safe to
     remove entirely for a full cutover matching `w-1`/`pve0` whenever that's wanted.
   - **The actual lesson**: a clean machine-config diff does not prove no live-behavior change.
     Talos derives multiple apiserver flags from `cluster.controlPlane.endpoint` internally, and
     not all of them are visible as text anywhere in the config you're diffing. Before ever
     touching this field again, check `cluster.apiServer.extraArgs` in `common.yaml` for what's
     already pinned (as of this writing: both `service-account-issuer` and `api-audiences`) - if a
     *third* Talos-internal flag turns out to derive from this endpoint too, expect a third
     incident, and verify against the live static pod manifest, not the config file, before
     trusting any future change here.
   - `talosctl`'s `endpoints`/`nodes` and `kubeconfig`'s `server:` field are separate, pure
     client-side settings, decoupled from the apiserver's own issuer/audience flags - not affected
     by any of the above. `talosctl config endpoint 10.200.0.52`/`talosctl config node
     10.200.0.52` works cleanly. `talosctl kubeconfig ... --force` regenerates `server:` *from*
     `cluster.controlPlane.endpoint`, which would now correctly produce `talos-api.lan` - but
     editing `talos/out/kubeconfig`'s `server:` line directly to the raw IP (`sed`/by hand) is what
     was actually done, kept that way deliberately: one less DNS dependency for the one tool you'd
     reach for if DNS itself were ever the thing broken. Re-run
     `talos/scripts/encrypt-secrets.sh` after any change here to update the committed
     `kubeconfig.enc.yaml`.
2. **Cilium's `k8sServiceHost`** in `clusters/homelab/apps/cilium/release.yaml` - done, now
   `10.200.0.52`. And the `CiliumLoadBalancerIPPool` range in
   `clusters/homelab/apps/cilium-config/lb-pool.yaml` - done, now `10.200.0.90`-`.99` (not
   `.70`-`.85` as originally sketched here - whatever range you actually pick, first confirm
   nothing in the repo references the old LB IP directly: `grep -rn <old-ip>` across the repo. In
   this migration only `envoy-main` used one, and the real ingress path
   (`clusters/homelab/apps/wireguard/haproxy-configmap.yaml`) targets it via internal cluster DNS,
   not the LoadBalancer IP - so the range change had zero impact on public ingress). The
   `CiliumLoadBalancerIPPool`/`CiliumL2AnnouncementPolicy` CRDs are plain mutable manifests, no
   immutability surprise there (confirmed via dry-run patch before committing).
   - **Gotcha found the hard way, worth knowing before it bites you again**: any time
     `kube-apiserver` itself restarts (a `cluster.controlPlane.endpoint`-style config apply,
     an upgrade, anything), Cilium's own tracked backend for the `kubernetes` ClusterIP service
     (`10.96.0.1:443`) can go stale/empty - `cilium-dbg service list | grep 10.96.0.1` shows no
     backend at all, and everything using in-cluster service-account credentials (basically every
     controller pod) starts failing with `no route to host` reaching `10.96.0.1`. Symptom looks
     identical to a real network problem but isn't one - the fix is the same agent restart used
     elsewhere in this doc: `kubectl delete pods -n kube-system -l k8s-app=cilium`, verify the
     backend reappears, done. This needs re-doing after *every* apiserver restart, not just once -
     bit us twice in the same session (once after the endpoint change, again after reverting it).
3. **ZFS NFS export ACL** on `nas` - done, both nodes' new addresses added:
   `zfs set sharenfs="rw=@192.168.1.252/32:@192.168.1.206/32:@192.168.1.5/32:@10.200.0.52/32:@10.200.0.7/32,no_root_squash,no_subtree_check" Main/data`
   (kept the stale old-network entries rather than pruning them - harmless, not worth the risk of
   a typo on a live export ACL for a cleanup with zero functional benefit).
4. **Router DHCP pool exclusion**: double-check the Mikrotik's `.100`-`.199` DHCP pool doesn't
   overlap `10.200.0.52`/`.6`/`.7`/the Cilium range (`.90`-`.99`) - it shouldn't, by construction,
   but worth confirming in the Terraform config the same way the root README already calls out for
   the old network's DHCP pool. **Not yet done as of this writing.**
5. **Verify** the same way the Talos patches restructure was verified before it went live:
   `talosctl services`, `kubectl get nodes`, `talosctl etcd members`, a cluster-wide
   non-`Running` pod sweep - and now also: `kubectl get pods -A | grep -v Running` specifically
   after *any* apiserver restart, per the Cilium gotcha above, not just after Talos-level changes.

This is exactly the kind of hard-to-reverse, whole-cluster-reachability-affecting change worth
doing together interactively rather than scripted end-to-end - keep Proxmox console access
(VNC/serial) to each VM handy throughout in case a node becomes unreachable over the network
mid-change. Concretely proved its worth here: the `cluster.controlPlane.endpoint` mistake was
caught and reverted within minutes specifically because it was done interactively with health
checks after every step, not scripted end-to-end unattended.
