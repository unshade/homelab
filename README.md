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

## Ingress

Public entry is a VPS (HAProxy, TCP passthrough + PROXY protocol) over a WireGuard tunnel to a
pod in-cluster, which relays to Envoy Gateway for TLS termination — replaces the old Cloudflare
Tunnel setup. See [`vps/README.md`](vps/README.md) for the VPS side and
`clusters/homelab/apps/wireguard/` for the cluster side. Adding a new hostname needs no changes
here — just point DNS at the VPS IP and add the `HTTPRoute` in-cluster.

## ZFS

Run on the Proxmox host `nas` (`10.200.0.20`, was `192.168.1.201` before the router migration -
see [`router/README.md`](router/README.md)) — the `rw=` clause is a colon-separated ACL of every
node IP allowed to mount the NFS export; add a new node's `/32` to the list rather than widening
to a whole subnet. Kept the stale old-network entries below rather than pruning them - harmless,
not worth the risk of a typo on a live export ACL for zero functional benefit:

```bash
zfs set sharenfs="rw=@192.168.1.252/32:@192.168.1.206/32:@192.168.1.5/32:@10.200.0.52/32:@10.200.0.7/32,no_root_squash,no_subtree_check" Main/data
```

## Cluster facts

| | |
|---|---|
| Cluster name | `talos-proxmox-cluster` |
| Nodes | `talos-cp1` (`10.200.0.52`, control-plane), `w-1` (`10.200.0.7` - temporary, see below) — both static |
| Interface | `ens18` (both nodes) - `talos-cp1` is also dual-homed on `ens19` (`10.200.0.52`), `ens18`'s old `192.168.1.252` kept as an inert rollback address, no longer routed |
| Gateway | `10.200.0.1` (was `192.168.1.254` before the router migration) |
| Talos version | v1.13.5 |
| Kubernetes version | v1.36.2 |
| CNI | [Cilium](https://cilium.io) (replaces flannel), kube-proxy-replacement mode, LoadBalancer IPs via L2 announcement (replaces the never-installed MetalLB) — see [Networking: Cilium](#networking-cilium) |
| Role | single control-plane (`talos-cp1`) by design — a 2-node etcd (the earlier setup) has zero real fault tolerance anyway, since quorum of 2 needs both members healthy. `talos-cp1` has `allowSchedulingOnControlPlanes: true` so it still runs regular pods alongside `w-1`, not just etcd/control-plane |
| Data disk | `sdb`, 430GB, XFS, mounted at `/var/mnt/data` on **each** node (see Storage section) — `longhorn-strict-local` volumes are pinned to whichever node the pod using them lands on, so both nodes need their own copy of this disk/mount, not a shared one |

> `w-1`'s `10.200.0.7` is temporary - `pve0` (the Proxmox host it runs on) ended up claiming the
> originally-planned `10.200.0.6` by mistake during the migration and was left as-is; reconcile
> both to clean, final addresses eventually. Both nodes' static IPs should stay excluded from
> the router's DHCP pool (`.100`-`.199`) so they never get handed out to something else - see
> `router/README.md`'s addressing table.

`cluster.controlPlane.endpoint` is `https://talos-api.lan:6443` (a floating DNS record on the
Mikrotik - see `router/README.md` - rather than a literal IP, so it can survive control-plane
ever moving to a different physical node). Cilium's `k8sServiceHost` is `10.200.0.52`. Both used
to be hardcoded to `192.168.1.252` and both were genuinely risky to change - changing either one
independently invalidates every service-account token cluster-wide, since Talos derives
`--service-account-issuer`/`--api-audiences` from `cluster.controlPlane.endpoint` by default. Both
are now explicitly pinned via `cluster.apiServer.extraArgs` in `talos/patches/common.yaml`
instead, permanently decoupled from whatever this endpoint says - see `router/README.md`'s Phase
3 notes for the full incident writeup (twice) and the actual safe procedure.

## Talos: day-to-day operations

Repo layout under `talos/`, secrets/SOPS handling, how to change the machine config, and the
full historical log of how the cluster got bootstrapped and grew from one node to two all live
in [`talos/README.md`](talos/README.md) — that's the runbook to reach for when actually
operating the cluster day to day. This file stays focused on architecture/design (below) and
the facts that don't change often (above).

## Router

A Mikrotik router, managed with Terraform, sits behind the existing home network and hosts the
homelab on its own isolated `10.200.0.0/24` segment. See [`router/README.md`](router/README.md)
for the Terraform config, addressing, and the cutover history (both Talos nodes and the Proxmox
hosts are fully migrated onto it as of this writing).

## Networking: Cilium

The cluster originally ran Talos's default CNI (flannel) and kube-proxy. MetalLB was planned for
`LoadBalancer` IPs but never actually installed. All three were replaced with
[Cilium](https://cilium.io): it's the CNI, it replaces kube-proxy (eBPF-based Service routing,
`kubeProxyReplacement: true`), and it hands out `LoadBalancer` IPs itself via **L2 announcement**
(ARP-based — there's no BGP router on this LAN, so BGP mode wasn't an option) instead of MetalLB.

Managed via Flux, same pattern as everything else in `clusters/homelab/apps/`:

- `repositories/helm/cilium.yaml` — `HelmRepository` pointing at `https://helm.cilium.io/`.
- `apps/cilium/release.yaml` — the `HelmRelease` (installed into `kube-system`, chart `1.19.6`).
- `apps/cilium-config/lb-pool.yaml` — a `CiliumLoadBalancerIPPool` (`10.200.0.90`–`10.200.0.99`,
  was `192.168.1.190`–`192.168.1.200` before the router migration)
  and `CiliumL2AnnouncementPolicy`, the direct equivalent of MetalLB's IPAddressPool +
  L2Advertisement. This is its own Flux `Kustomization` with `dependsOn: [cilium]`, since its CRDs
  only exist once the Cilium HelmRelease has installed.

Key Helm values, and why each one is there (Talos needs some overrides other distros don't):

```yaml
kubeProxyReplacement: true
k8sServiceHost: 10.200.0.52   # this node's static IP
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
talosctl -n 10.200.0.52 get volumestatus u-data     # provisioning result: partition, size, phase
talosctl -n 10.200.0.52 get mountstatus              # confirms it's mounted at /var/mnt/data
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
