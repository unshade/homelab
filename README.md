# homelab

## Flux

First installation :

```bash
flux bootstrap github \
  --private=false \
  --token-auth \
  --owner=unshade \
  --repository=homelab \
  --branch=main \
  --path=clusters/homelab \
  --personal
```

Then paste PAT with [required scopes](https://fluxcd.io/flux/installation/bootstrap/github/#github-pat).

Trash flux :

```bash
flux uninstall --namespace=flux-system --keep-namespace
```

## Cloudflared

Add a new domain :

```bash
cloudflared tunnel route dns <tunnel-name> <hostname>
```

`tunnel-name` is `homelab` and `hostname` is the domain you want to add.

Then, update `clusters/homelab/apps/cloudflared/configmap.yaml` with the new hostname and run :

```bash
flux reconcile kustomization cloudflared --with-source
```

## ZFS

Run on the Proxmox host (`192.168.1.201`) — the `rw=` clause is a colon-separated ACL of every
node IP allowed to mount the NFS export; add a new node's `/32` to the list rather than widening
to a whole subnet:

```bash
zfs set sharenfs="rw=@192.168.1.252/32:@192.168.1.206/32,no_root_squash,no_subtree_check" Main/data
```

## Cluster facts

| | |
|---|---|
| Cluster name | `talos-proxmox-cluster` |
| Nodes | `talos-cp1` (`192.168.1.252`), `talos-cp2` (`192.168.1.206`) — both static |
| Interface | `ens18` (both nodes) |
| Gateway | `192.168.1.254` |
| Talos version | v1.13.5 |
| Kubernetes version | v1.36.2 |
| CNI | [Cilium](https://cilium.io) (replaces flannel), kube-proxy-replacement mode, LoadBalancer IPs via L2 announcement (replaces the never-installed MetalLB) — see [Networking: Cilium](#networking-cilium) |
| Role | both nodes are control-plane with `allowSchedulingOnControlPlanes: true`, so regular pods schedule on either |
| Data disk | `sdb`, 430GB, XFS, mounted at `/var/mnt/data` on **each** node (see Storage section) — `longhorn-strict-local` volumes are pinned to whichever node the pod using them lands on, so both nodes need their own copy of this disk/mount, not a shared one |

> Both nodes' static IPs (`192.168.1.252`, `192.168.1.206`) should be excluded from your router's
> DHCP pool so they never get handed out to something else.

**Known gap:** `cluster.controlPlane.endpoint` (in both nodes' machine config) and Cilium's
`k8sServiceHost` Helm value are still hardcoded to `192.168.1.252` — every node bootstraps its
kube-apiserver connection through cp1 specifically. This isn't a problem day-to-day (once a node
is up, `kubectl`/`talosctl` can reach it directly, and running pods don't route through this
value), but if cp1 is down, a fresh Cilium agent or a from-scratch node join would have nothing to
bootstrap against even though cp2 is healthy. Fixing this for real needs a floating VIP (Talos
supports one natively) shared between control-plane nodes — not done yet, tracked here as a
follow-up rather than solved as a side effect of adding cp2.

## Repo layout

```
talos/
  patches/
    common.yaml                # shared by every node - install image, kubelet extraMounts,
                                # features, the data-disk UserVolumeConfig. A real Talos
                                # machine-config patch, applied via --config-patch.
    talos-cp1.yaml              # per-node patch: static IP + hostname, hand-written
    talos-cp2.yaml              # same, for the second node
  schematic.yaml                # Image Factory input that produced the schematic ID baked
                                # into common.yaml's install.image - documentation + the
                                # input to re-resolving it by hand, not consumed automatically
  secrets-sops-all.yaml         # the cluster PKI/tokens (talosctl gen-secrets output),
                                # generated exactly once ever, sops-encrypted, committed
  kubeconfig.enc.yaml           # sops-encrypted kubectl client credentials (committed)
  out/                          # gitignored, throwaway - talos-cp1.yaml, talos-cp2.yaml (full
                                # per-node machine configs), talosconfig, kubeconfig
  scripts/
    decrypt-secrets.sh          # sops -d kubeconfig.enc.yaml into out/kubeconfig
    encrypt-secrets.sh          # sops -e out/kubeconfig back into kubeconfig.enc.yaml
.sops.yaml                      # tells sops which GPG key encrypts which files, and how much
                                # of each file (see below - this matters)
.gitignore                      # excludes talos/out/ from git
```

No wrapper script generates anything here - every step is a plain, documented `talosctl`
command (see "Changing the machine config" below), run by hand. The only things committed are
either a genuine secret or a fact that can't be regenerated (a node's static IP, its hostname,
in its own patch file); the full per-node machine config - same shape Talos actually consumes,
~400 lines each - is assembled on demand from `patches/common.yaml` + a node's own patch file
+ the secrets bundle, and thrown away freely.

## Secrets: how this is versioned

The cluster's PKI (etcd CA, Kubernetes CA, aggregator CA, service-account key, OS CA) and
tokens live in `talos/secrets-sops-all.yaml`, generated **once, ever**, via `talosctl gen
secrets`. Re-running that against a running cluster would produce a *different* random PKI the
nodes don't trust - that's not the same thing as rotating credentials on an existing one, so
this command is never run again short of standing up a brand new cluster. `talos/kubeconfig.enc.yaml`
is the other committed secret - unrelated to the PKI bundle (it's minted live from the running
API server, not derivable from the secrets bundle alone).

- Both are encrypted with [SOPS](https://github.com/getsops/sops) against a GPG key.
- The key used is `noesteiner@proton.me` (fingerprint
  `0838E38422232D44B96B6C7659A7C95E7A016E5A`, labeled "Used for SOPS on kaastorama kube
  cluster" — reused here for consistency with the other cluster). `.sops.yaml` at the repo root
  pins this fingerprint as the encryption target.
- **`.sops.yaml` has two different rules that matter here.** `talos/secrets-sops-all.yaml` gets
  its own dedicated rule with no `encrypted_regex` (encrypts the *whole* document) — the
  generic `*-sops.yaml` rule elsewhere in this repo only encrypts keys literally named
  `data`/`stringData`/`secrets` (it's shaped for Kubernetes `Secret` manifests), which would
  leave `cluster.id`/`cluster.secret`/every CA private key sitting in git in plaintext, since
  none of those keys match that pattern. The `-sops-all` suffix is the deliberate signal for
  "encrypt everything" — don't rename this file to plain `-sops.yaml`.
- Decryption needs the matching **private** GPG key in your local keyring (`gpg
  --list-secret-keys`) and `gpg-agent` running — sops shells out to `gpg` automatically, no
  extra env vars needed. Make sure this private key is backed up (e.g. `gpg --export-secret-keys
  --armor 0838E38422232D44B96B6C7659A7C95E7A016E5A`, stored somewhere durable) — if you lose it
  and lose this machine, you can't decrypt the committed secrets and would have to regenerate
  the cluster's PKI from scratch (which, per above, means every node needs re-imaging - it's not
  a rotation, it's a new cluster identity).

**After cloning this repo on a new machine:**
```bash
brew install sops gnupg talosctl yq
# import your backed-up private key: gpg --import <key-file>
talos/scripts/decrypt-secrets.sh   # gets you out/kubeconfig
# then render the machine configs and talosconfig - see "Changing the machine config" below
```

**After fetching a new kubeconfig** (`talosctl -n 192.168.1.252 kubeconfig talos/out/kubeconfig --force`):
```bash
cd talos && ./scripts/encrypt-secrets.sh
git add kubeconfig.enc.yaml
git commit -m "..."
```

## What was done to get here

This is the actual sequence of `talosctl` operations that took the VM from a blank Talos boot
to the cluster described above.

**1. Generate the machine configs (done once, on this Mac, not on the node):**
```bash
talosctl gen config talos-proxmox-cluster https://192.168.1.16:6443 -o talos/_out
```
This produced `controlplane.yaml`, `worker.yaml` (unused — single-node clusters only need the
control-plane config), and `talosconfig`, each containing freshly generated cluster PKI
(CA cert/key, cluster ID/secret, join tokens). `192.168.1.16` was the VM's DHCP IP at the time;
it later became `192.168.1.252` (step 4).

**2. Push the config to the booted VM and start the cluster:**
```bash
# the VM was booted from the Talos metal ISO in Proxmox and sat in "maintenance mode"
# at its DHCP IP, waiting for a config — --insecure is required here because the node
# has no identity/certs yet at this point
talosctl apply-config --insecure -n 192.168.1.16 -f talos/_out/controlplane.yaml

# once the node rebooted with the config installed to disk, this initializes etcd
# and starts the Kubernetes control plane (only ever run once per cluster):
talosctl --talosconfig talos/_out/talosconfig -n 192.168.1.16 bootstrap
```

**3. Allow the control-plane node to run normal workloads** (by default it's tainted
`NoSchedule`, which would leave nothing running since this node is the entire cluster):
```yaml
# added under cluster: in controlplane.yaml
cluster:
    allowSchedulingOnControlPlanes: true
```
```bash
talosctl -n 192.168.1.16 apply-config -f talos/_out/controlplane.yaml
```

**4. Convert from DHCP to the static IP `192.168.1.252`:**
```yaml
# added under machine: in controlplane.yaml
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
        nameservers:
            - 192.168.1.253
            - 1.1.1.1
            - 1.0.0.1
```
also updated `cluster.controlPlane.endpoint` to `https://192.168.1.252:6443` to match, then:
```bash
talosctl -n 192.168.1.16 apply-config -f talos/_out/controlplane.yaml
talosctl config endpoint 192.168.1.252 --talosconfig talos/_out/talosconfig
talosctl config node 192.168.1.252 --talosconfig talosconfig
```
This took effect live, no reboot — etcd kept running throughout.

**5. Pin the hostname.** The IP change alone left the hostname on `auto: stable`, which
generates a new random-looking name (`talos-lv0-386`) any time the network identity changes —
not something you want wandering around. Fixed via the config's separate `HostnameConfig`
document:
```yaml
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: talos-cp1
```
```bash
talosctl -n 192.168.1.252 apply-config -f talos/_out/controlplane.yaml --mode=reboot
```
Hostname changes need `--mode=reboot` (a plain `apply-config` errors with "static hostname is
already set" instead of applying live).

**6. Clean up stale node identities.** Every rename (`192.168.1.16` → `talos-lv0-386` →
`talos-cp1`) made Kubernetes register a brand-new `Node` object without removing the old one —
Kubernetes doesn't do this automatically. Once `talos-cp1` came up `Ready`, the leftovers were
removed by hand:
```bash
kubectl delete node 192-168-1-16 talos-lv0-386
```

**7. Added the QEMU guest agent** by requesting a custom installer image from the Talos Image
Factory (extension `siderolabs/qemu-guest-agent`) and running `talosctl upgrade` to that image —
extensions get baked into the boot image, they're not a plain config field.

**8. Provisioned the second disk (`sdb`, 430GB) as a `UserVolumeConfig`** — formatted it XFS and
mounted it at `/var/mnt/data`. See the Storage section below for what this is and how it's meant
to be used.

**9. Set up SOPS + GPG encryption** so the config could be committed to git safely (see above).

**10. Added Longhorn's required extensions** (`siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`)
the same way — a new Image Factory schematic including these plus the existing
`siderolabs/qemu-guest-agent`, then `talosctl upgrade` to it:
```bash
curl -X POST "https://factory.talos.dev/schematics" -H "Content-Type: application/yaml" --data-binary @- <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
EOF
# returns a schematic ID; current one: 53513e54bb39202f35694412577a6bc53d484744d35a126e5d42ef34785c0d83
talosctl -n 192.168.1.252 upgrade \
  --image factory.talos.dev/installer/53513e54bb39202f35694412577a6bc53d484744d35a126e5d42ef34785c0d83:v1.13.5
```
This reboots the node (it's the only one — expect a brief full-cluster interruption while it
comes back). Verify with `talosctl -n 192.168.1.252 get extensions`. Also added
`machine.kubelet.extraMounts` for `/var/mnt/data` (see the Networking/Storage sections) — paths
on the Talos host aren't visible inside the kubelet's own mount namespace without this, which
Longhorn's hostPath-based pods need.

The chosen installer image *is* tracked declaratively, in `machine.install.image` — but
`talosctl upgrade --image ...` only swaps the running image, it does **not** write the new
reference back into `controlplane.yaml` for you. That has to be done by hand (and was, here) or
the file silently drifts from what's actually running — a fresh install from a stale
`controlplane.yaml` would use the old image and come back without these extensions, even though
`install.image` genuinely is the field meant to make this reproducible.

**11. Added a second control-plane node (`talos-cp2`).** Unlike the very first node, the target
state was known upfront, so this was one config push instead of the incremental DHCP→static→
hostname dance step 4/5 went through. `talos/_out/controlplane-cp2.yaml` is a copy of
`controlplane.yaml` — same cluster PKI/tokens/etcd CA (required to join the *same* cluster) —
with only the `HostnameConfig` (`talos-cp2`) and the static IP (`192.168.1.206/24`) changed. The
new VM turned out to have the exact same disk layout as cp1 (`sda` 64GB, `sdb` 430GB) and NIC
name (`ens18`), confirmed read-only against the booted-but-unconfigured node before writing the
config:
```bash
talosctl version --insecure -n 192.168.1.22          # confirms it's reachable in maintenance mode
talosctl -n 192.168.1.22 --insecure get links         # confirms the interface name
talosctl -n 192.168.1.22 disks --insecure             # confirms the disk layout
```
so the `UserVolumeConfig` (`/var/mnt/data`) and the custom installer image (with the iSCSI/util-linux
extensions) were kept identical rather than dropped. One push did everything — install, network,
hostname, PKI join — no separate reboot step needed this time since it all went in on the node's
very first config application:
```bash
talosctl apply-config --insecure -n 192.168.1.22 -f talos/_out/controlplane-cp2.yaml
```
**`talosctl bootstrap` is never run again for additional control-plane nodes** — that command
initializes etcd and only ever happens once, for the very first node in a cluster's life. A new
control-plane node joins the existing etcd cluster automatically on boot because its config
carries the same `cluster.id`/`cluster.secret`/etcd CA as the first node.

Registered the new node as an additional `talosctl` target:
```bash
talosctl config endpoint 192.168.1.252 192.168.1.206
talosctl config node 192.168.1.252 192.168.1.206
```
Verified with `talosctl etcd members` (both nodes listed, neither a learner), `kubectl get nodes`
(both `Ready`, `control-plane`, no taint — workload scheduling just works, inherited from
`allowSchedulingOnControlPlanes: true`), and confirmed Longhorn auto-discovered the new node's
`/var/mnt/data/longhorn` disk and DaemonSets (Cilium, csi-driver-nfs, Longhorn) self-scheduled
onto it with no manual intervention.

Two things this did **not** fix, called out in the Cluster facts "Known gap" note above:
`cluster.controlPlane.endpoint` and Cilium's `k8sServiceHost` are both still hardcoded to cp1's
IP — real HA needs a floating VIP across control-plane nodes, which Talos supports but this
change didn't set up.

**Note on the sequence above:** all of it happened by hand-editing the full
`talos/_out/controlplane.yaml` / `controlplane-cp2.yaml`, which is genuinely how it went — this
section is a historical record, not rewritten to match current tooling. Since then, the machine
config has been restructured into `talos/patches/common.yaml` (shared) plus each node's own
`talos/patches/talos-cp1.yaml`/`talos-cp2.yaml`, regenerated on demand via plain `talosctl`
commands (see "Repo layout" and "Changing the machine config" above) — confirmed to reproduce
the exact same config (semantic diff, then `talosctl validate`) before cutting over, so nothing
above needed to actually change on the live nodes for the restructure itself.

## Networking: Cilium

The cluster originally ran Talos's default CNI (flannel) and kube-proxy. MetalLB was planned for
`LoadBalancer` IPs but never actually installed. All three were replaced with
[Cilium](https://cilium.io): it's the CNI, it replaces kube-proxy (eBPF-based Service routing,
`kubeProxyReplacement: true`), and it hands out `LoadBalancer` IPs itself via **L2 announcement**
(ARP-based — there's no BGP router on this LAN, so BGP mode wasn't an option) instead of MetalLB.

Managed via Flux, same pattern as everything else in `clusters/homelab/apps/`:

- `repositories/helm/cilium.yaml` — `HelmRepository` pointing at `https://helm.cilium.io/`.
- `apps/cilium/release.yaml` — the `HelmRelease` (installed into `kube-system`, chart `1.19.6`).
- `apps/cilium-config/lb-pool.yaml` — a `CiliumLoadBalancerIPPool` (`192.168.1.190`–`192.168.1.200`)
  and `CiliumL2AnnouncementPolicy`, the direct equivalent of MetalLB's IPAddressPool +
  L2Advertisement. This is its own Flux `Kustomization` with `dependsOn: [cilium]`, since its CRDs
  only exist once the Cilium HelmRelease has installed.

Key Helm values, and why each one is there (Talos needs some overrides other distros don't):

```yaml
kubeProxyReplacement: true
k8sServiceHost: 192.168.1.252   # this node's static IP
k8sServicePort: 6443
cgroup:
  autoMount:
    enabled: false               # Talos already mounts cgroupv2 itself
  hostRoot: /sys/fs/cgroup
securityContext:
  capabilities:                  # see "Problem 1" below — required on Talos
    ciliumAgent: [CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    cleanCiliumState: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
operator:
  replicas: 1                    # chart default is 2; this is a one-node cluster
```

`k8sServiceHost`/`k8sServicePort` are mandatory in kube-proxy-replacement mode: without kube-proxy
there's no ClusterIP-to-apiserver translation, so Cilium needs the real API endpoint directly.

On the Talos side (`talos/patches/common.yaml`), two fields turn off the defaults Cilium is
replacing:
```yaml
cluster:
  network:
    cni:
      name: none        # don't deploy flannel
  proxy:
    disabled: true       # don't deploy kube-proxy
```

### Doing this cutover live, on a single-node cluster with no failover

This is inherently disruptive: for a moment there is no working CNI at all. Existing pods keep
their IPs, but the moment flannel's DaemonSet is gone, its VXLAN interface and iptables rules go
with it — pod-to-pod networking breaks until Cilium's datapath is up. `kubectl`/`talosctl` stay
reachable throughout (the control plane runs as static, host-network pods), so it's recoverable
even mid-outage, but nothing pod-network-based works until Cilium is healthy.

**What actually happened, for reference — three separate problems stacked on top of each other:**

1. **Capabilities error.** Cilium's `clean-cilium-state` init container immediately crashed:
   `unable to apply caps: can't apply capabilities: operation not permitted`. Talos's default
   container capability bounding set is stricter than the Cilium chart assumes — the fix is the
   explicit `securityContext.capabilities` block above, which [Talos's own Cilium
   guide](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium) documents. Without
   it, Cilium simply cannot start on Talos, full stop.

2. **Flux locked itself out.** While Cilium was crash-looping (no working CNI yet), Flux's own
   controllers — `source-controller`, `kustomize-controller`, `helm-controller` — are ordinary
   pod-network pods, not host-network. They lost their route to the API server's ClusterIP along
   with everything else, so Flux couldn't reconcile the fix I'd already pushed to git. The cluster
   was stuck: no CNI, and the tool that would normally fix it couldn't reach anything either.
   Recovery was a one-time manual `helm upgrade --install cilium cilium/cilium ...` run **from
   outside the cluster** (a laptop, talking straight to the node's real IP, bypassing in-cluster
   networking entirely) using the corrected values. That brought Cilium up, which restored pod
   networking, which let Flux's controllers reconnect and take back over on their own — Flux's
   next reconcile recognized the manually-installed release and adopted it with a normal `helm
   upgrade`, no special handling needed. **Takeaway:** if a from-scratch CNI bootstrap ever needs
   to happen again, don't assume Flux can be the thing that installs the CNI it depends on to run
   — keep a manual `helm install` escape hatch in mind.

3. **Stale pod sandboxes.** Once Cilium was healthy, pods that had been running *before* the
   cutover (`flux-system`, `cert-manager`, `envoy-gateway-system`) still showed `0/1 Ready` with
   liveness/readiness probes failing on `no route to host`. Their network sandboxes were created
   under flannel's old routing and never got migrated — they needed a fresh sandbox under Cilium.
   Fix: `kubectl delete pod` on each (all are Deployment-managed, so they self-heal immediately
   with new, correctly-routed IPs). This is expected any time the CNI itself changes underneath
   already-running pods; it isn't Cilium-specific.

**Verifying it's actually healthy:**
```bash
kubectl get nodes                                          # Ready
kubectl get pods -A                                         # everything Running, no stale sandboxes
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief   # "OK"
kubectl get ciliumloadbalancerippools                        # IPs available
kubectl get ciliuml2announcementpolicies
flux get helmrelease -A                                      # cilium: Ready
```

**How to know the schema/values for a chart like this in general:** `helm show values
cilium/cilium --version 1.19.6` dumps every configurable value with inline comments — that's the
authoritative source, not guessing from blog posts. For the CRDs Cilium itself installs
(`CiliumLoadBalancerIPPool`, etc.), `kubectl explain ciliumloadbalancerippool.spec` works the same
way `kubectl explain` does for any other CRD, once the CRD is installed.

## Storage

`UserVolumeConfig` is a **Talos** machine config document, not a Kubernetes resource — it lives
in `talos/patches/common.yaml` (shared by both nodes, since both have the same disk layout;
`HostnameConfig` is the one document that's genuinely per-node, hand-written in each node's own
`talos/patches/talos-cp*.yaml`), and it's how Talos itself (not Kubernetes)
declaratively owns a disk: which physical disk to use, what filesystem to put on it, where to
mount it on the node. There is no `kubectl get uservolumeconfig` — the object doesn't exist in
the Kubernetes API at all, only in Talos's own config/resource system on the node:
```bash
talosctl -n 192.168.1.252 get volumestatus u-data     # provisioning result: partition, size, phase
talosctl -n 192.168.1.252 get mountstatus              # confirms it's mounted at /var/mnt/data
```

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: data                        # mount path becomes /var/mnt/<name>
provisioning:
    diskSelector:
        match: '!system_disk'     # "the disk Talos isn't installed on" — sdb
    minSize: 400GB
filesystem:
    type: xfs
```

This is **layer 1 of 2**. Talos formatting and mounting `/var/mnt/data` just makes 430GB of disk
available *on the node* — it does nothing for Kubernetes by itself. **Layer 2** is a Kubernetes
`StorageClass`/provisioner that actually turns that mounted directory into `PersistentVolume`s
pods can claim — this is [Longhorn](https://longhorn.io) (`clusters/homelab/apps/longhorn/`),
using its **strict-local** data-locality mode rather than the plain single-node
`local-path-provisioner` originally considered here.

`strict-local` forces exactly one replica, pinned to the same node as the pod using it — no
cross-node replication attempted, which fits a single-node cluster fine (multi-replica would just
mean permanently-degraded volumes trying to place replicas on nodes that don't exist). Unlike
local-path-provisioner, Longhorn still provides snapshots, backups, and online volume expansion —
worth having for apps that manage their own redundancy at the application level (e.g. a Postgres
with its own backup strategy) and just need a real block-storage feature set underneath. The
`longhorn-strict-local` StorageClass (`numberOfReplicas: "1"`, `dataLocality: "strict-local"`) is
the cluster's default. When more nodes are added later, a second StorageClass with a higher
replica count can just be added alongside it — nothing about this setup blocks that, replica
count is a per-StorageClass (and per-volume) parameter, not a cluster-wide one.

Longhorn's engine needs iSCSI tooling Talos doesn't ship by default — this needs two Talos system
extensions (`siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`) baked into the boot image via
a `talosctl upgrade --image factory.talos.dev/installer/<schematic>:<version>`, plus a
`machine.kubelet.extraMounts` bind-mount so hostPath-based pods can actually see
`/var/mnt/data` (paths on the Talos host aren't automatically visible inside the kubelet's own
mount namespace). See [Longhorn's Talos support
doc](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/).

**TODO — cold storage:** a separate NFS-backed `StorageClass`, backed by a ZFS dataset exported
from the Proxmox host itself rather than this local disk. Trades a bit of performance for the
ability to browse/manage/snapshot the data directly from Proxmox, which a local block device
fundamentally can't offer — `sdb`/`/var/mnt/data` stays reserved for regular fast PVCs.

## Managing the cluster

Two separate CLIs, two separate credential files, both under `talos/out/` (regenerate per
"Changing the machine config" below / `talosctl kubeconfig` if missing — see "Repo layout"
above):

- **`talosctl`** — talks to the Talos OS itself (not Kubernetes): reboot, upgrade, disk/network
  state, service health, logs. Uses `talos/out/talosconfig`.
- **`kubectl`** — talks to the Kubernetes API: pods, deployments, services. Uses
  `talos/out/kubeconfig`.

Set these once per shell session so you don't have to pass flags every time:
```bash
export TALOSCONFIG=talos/out/talosconfig
export KUBECONFIG=talos/out/kubeconfig
```

### Day-to-day Talos commands

```bash
talosctl -n 192.168.1.252 dashboard        # live TUI: CPU/mem/disk, logs, processes
talosctl -n 192.168.1.252 services         # health of every Talos-managed service
talosctl -n 192.168.1.252 dmesg            # kernel + controller log stream
talosctl -n 192.168.1.252 logs <service>   # e.g. etcd, kubelet
talosctl -n 192.168.1.252 containers -k    # kubernetes-namespace containers (static pods)
talosctl -n 192.168.1.252 version          # confirm the node is reachable
talosctl -n 192.168.1.252 reboot           # graceful reboot
talosctl -n 192.168.1.252 upgrade --image ghcr.io/siderolabs/installer:vX.Y.Z   # OS upgrade
```

### Changing the machine config

Talos has no shell and no package manager — there's nothing to SSH into and tweak. The *only*
way to change anything about the OS (network, disks, kubelet, static pods, users of the API,
etc.) is to edit the YAML and push the whole file back to the node. Talos diffs it against the
running state and reconciles.

The file you actually edit is almost never the full per-node config — it's `patches/common.yaml`
(shared by both nodes) or, for something genuinely per-node (a new static IP, a disk override),
that node's own `patches/talos-cp1.yaml`/`talos-cp2.yaml`. The full config is reassembled from
those plus the secrets bundle via plain `talosctl` commands, no wrapper script; `talos/out/` is
disposable output, not a source of truth.

Step by step, e.g. to change something shared by both nodes:

```bash
cd talos

# 1. edit the patch, not a full per-node file
$EDITOR patches/common.yaml

# 2. regenerate the base config (both nodes' shared starting point)
sops -d secrets-sops-all.yaml > out/.secrets.yaml
talosctl gen config talos-proxmox-cluster https://192.168.1.252:6443 \
  --with-secrets out/.secrets.yaml \
  --kubernetes-version 1.36.2 \
  --output-types controlplane,talosconfig \
  --output out/base \
  --config-patch @patches/common.yaml \
  --force
rm out/.secrets.yaml
# gen config ships its own HostnameConfig document defaulted to auto: stable, which conflicts
# with the explicit hostname in each node's own patch - strip it so the per-node patch is the
# only source:
yq -i 'select(.kind != "HostnameConfig")' out/base/controlplane.yaml

# 3. layer each node's own patch on top
talosctl machineconfig patch out/base/controlplane.yaml --patch @patches/talos-cp1.yaml --output out/talos-cp1.yaml
talosctl machineconfig patch out/base/controlplane.yaml --patch @patches/talos-cp2.yaml --output out/talos-cp2.yaml

# 4. out/talos-cp1.yaml is plain YAML (gitignored, not itself encrypted) - read it, or diff
#    it against a copy saved before this to see exactly what changed

# 5. push it to a node, one at a time
talosctl -n 192.168.1.252 apply-config -f out/talos-cp1.yaml

# 6. confirm it actually applied (also useful right after any change)
talosctl -n 192.168.1.252 services              # everything still Running/OK?
kubectl get nodes                               # still Ready?

# 7. repeat 5-6 for the other node, then commit the patch change (out/ isn't committed - the
#    patches are what's versioned)
git add patches/common.yaml
git commit -m "describe the change"
```

Most fields apply live with no downtime (this is how the taint and static-IP changes described
below, back when they were still done by hand, went in). A few — like the hostname — refuse to
apply live and need `apply-config --mode=reboot` instead, which Talos will tell you if you hit
it: the error says something like *"static hostname is already set"* rather than a generic
failure. When in doubt, try without `--mode=reboot` first; it's a safe no-op error if a reboot
turns out to be required, it doesn't apply half the change.

`talosctl` also has a lower-level `talosctl edit mconfig -n 192.168.1.252` which opens the
node's *live* config in `$EDITOR` and applies on save — convenient for a quick one-off tweak,
but it bypasses `patches/common.yaml` entirely, so anything changed that way needs to be copied
back into the patch by hand afterwards or the next regenerate-and-apply will silently revert it.

**Re-resolving the install image** (only needed if `schematic.yaml`'s extension list changes,
or a new/heterogeneous node needs a different one):
```bash
curl -X POST --data-binary @talos/schematic.yaml https://factory.talos.dev/schematics
# {"id": "<schematic-id>", ...} - use it in patches/common.yaml (or a per-node patch, for a
# node whose extensions genuinely differ) as:
#   factory.talos.dev/installer/<schematic-id>:<talos_version>
```

### Day-to-day kubectl commands

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl top nodes / kubectl top pods -A   # needs metrics-server (not installed yet)
kubectl apply -f my-manifest.yaml         # deploy something
```

### Upgrading Kubernetes itself (separate from Talos OS upgrades)

```bash
talosctl -n 192.168.1.252 upgrade-k8s --to 1.37.0
```

### If you lose network access to the node

You still have the Proxmox console (VNC/serial) for out-of-band access — a Talos machine has no
shell, but the console shows boot/network diagnostics, which is the first thing to check if
`talosctl` or `kubectl` can't reach `192.168.1.252` after a config change.
