# Talos: day-to-day operations

This is the operational runbook for the `talos/` directory: how the machine config is laid
out, how secrets are versioned, how to change something, and the historical log of how the
cluster got to its current state. For cluster-wide facts (node IPs, versions) and the
Cilium/storage design, see the root [`README.md`](../README.md).

## Repo layout

```
talos/
  patches/
    common.yaml                # shared by every node - install image, kubelet extraMounts,
                                # features, the data-disk UserVolumeConfig. A real Talos
                                # machine-config patch, applied via --config-patch.
    talos-cp1.yaml              # per-node patch: static IP + hostname, hand-written -
                                 # the sole control-plane node
    w-1.yaml                    # same, for the worker node
  schematic.yaml                # Image Factory input that produced the schematic ID baked
                                # into common.yaml's install.image - documentation + the
                                # input to re-resolving it by hand, not consumed automatically
  secrets-sops-all.yaml         # the cluster PKI/tokens (talosctl gen-secrets output),
                                # generated exactly once ever, sops-encrypted, committed
  kubeconfig.enc.yaml           # sops-encrypted kubectl client credentials (committed)
  out/                          # gitignored, throwaway - talos-cp1.yaml, w-1.yaml (full
                                # per-node machine configs), talosconfig, kubeconfig
  scripts/
    decrypt-secrets.sh          # sops -d kubeconfig.enc.yaml into out/kubeconfig
    encrypt-secrets.sh          # sops -e out/kubeconfig back into kubeconfig.enc.yaml
```

(`.sops.yaml` and `.gitignore`, at the repo root, also matter here — see "Secrets" below.)

No wrapper script generates anything here — every step is a plain, documented `talosctl`
command (see "Changing the machine config" below), run by hand. The only things committed are
either a genuine secret or a fact that can't be regenerated (a node's static IP, its hostname,
in its own patch file); the full per-node machine config — same shape Talos actually consumes,
~400 lines each — is assembled on demand from `patches/common.yaml` + a node's own patch file
+ the secrets bundle, and thrown away freely.

## Secrets: how this is versioned

The cluster's PKI (etcd CA, Kubernetes CA, aggregator CA, service-account key, OS CA) and
tokens live in `secrets-sops-all.yaml`, generated **once, ever**, via `talosctl gen
secrets`. Re-running that against a running cluster would produce a *different* random PKI the
nodes don't trust — that's not the same thing as rotating credentials on an existing one, so
this command is never run again short of standing up a brand new cluster. `kubeconfig.enc.yaml`
is the other committed secret — unrelated to the PKI bundle (it's minted live from the running
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
  the cluster's PKI from scratch (which, per above, means every node needs re-imaging — it's not
  a rotation, it's a new cluster identity).

**After cloning this repo on a new machine:**
```bash
brew install sops gnupg talosctl yq
# import your backed-up private key: gpg --import <key-file>
talos/scripts/decrypt-secrets.sh   # gets you out/kubeconfig
# then render the machine configs and talosconfig - see "Changing the machine config" below
```

**After fetching a new kubeconfig** (`talosctl -n 10.200.0.52 kubeconfig talos/out/kubeconfig --force`):
```bash
cd talos && ./scripts/encrypt-secrets.sh
git add kubeconfig.enc.yaml
git commit -m "..."
```

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
talosctl -n 10.200.0.52 dashboard        # live TUI: CPU/mem/disk, logs, processes
talosctl -n 10.200.0.52 services         # health of every Talos-managed service
talosctl -n 10.200.0.52 dmesg            # kernel + controller log stream
talosctl -n 10.200.0.52 logs <service>   # e.g. etcd, kubelet
talosctl -n 10.200.0.52 containers -k    # kubernetes-namespace containers (static pods)
talosctl -n 10.200.0.52 version          # confirm the node is reachable
talosctl -n 10.200.0.52 reboot           # graceful reboot
talosctl -n 10.200.0.52 upgrade --image ghcr.io/siderolabs/installer:vX.Y.Z   # OS upgrade
```

### Changing the machine config

Talos has no shell and no package manager — there's nothing to SSH into and tweak. The *only*
way to change anything about the OS (network, disks, kubelet, static pods, users of the API,
etc.) is to edit the YAML and push the whole file back to the node. Talos diffs it against the
running state and reconciles.

The file you actually edit is almost never the full per-node config — it's `patches/common.yaml`
(shared by both nodes) or, for something genuinely per-node (a new static IP, a disk override),
that node's own `patches/talos-cp1.yaml`/`patches/w-1.yaml`. The full config is reassembled from
those plus the secrets bundle via plain `talosctl` commands, no wrapper script; `talos/out/` is
disposable output, not a source of truth.

**One asymmetry to know:** `talos-cp1` is a `controlplane`-type config, `w-1` is a `worker`-type
one (see "What was done to get here" below for why there's only one control-plane) — these are
two different `talosctl gen config --output-types` values, generated separately, even though
both consume the exact same `patches/common.yaml`.

Step by step, e.g. to change something shared by both nodes:

```bash
cd talos

# 1. edit the patch, not a full per-node file
$EDITOR patches/common.yaml

# 2. regenerate the base configs - one per machine type, both from the same common.yaml
sops -d secrets-sops-all.yaml > out/.secrets.yaml
talosctl gen config talos-proxmox-cluster https://talos-api.lan:6443 \
  --with-secrets out/.secrets.yaml \
  --kubernetes-version 1.36.2 \
  --output-types controlplane,talosconfig \
  --output out/base-cp \
  --config-patch @patches/common.yaml \
  --force
talosctl gen config talos-proxmox-cluster https://talos-api.lan:6443 \
  --with-secrets out/.secrets.yaml \
  --kubernetes-version 1.36.2 \
  --output-types worker,talosconfig \
  --output out/base-worker \
  --config-patch @patches/common.yaml \
  --force
rm out/.secrets.yaml
# gen config ships its own HostnameConfig document defaulted to auto: stable, which conflicts
# with the explicit hostname in each node's own patch - strip it so the per-node patch is the
# only source:
yq -i 'select(.kind != "HostnameConfig")' out/base-cp/controlplane.yaml
yq -i 'select(.kind != "HostnameConfig")' out/base-worker/worker.yaml

# 3. layer each node's own patch on top of its matching base type
talosctl machineconfig patch out/base-cp/controlplane.yaml --patch @patches/talos-cp1.yaml --output out/talos-cp1.yaml
talosctl machineconfig patch out/base-worker/worker.yaml --patch @patches/w-1.yaml --output out/w-1.yaml

# 4. out/talos-cp1.yaml is plain YAML (gitignored, not itself encrypted) - read it, or diff
#    it against a copy saved before this to see exactly what changed. Also worth running
#    talosctl validate against it before pushing anything to a live node:
talosctl validate --config out/talos-cp1.yaml --mode metal
talosctl validate --config out/w-1.yaml --mode metal

# 5. push it to a node, one at a time
talosctl -n 10.200.0.52 apply-config -f out/talos-cp1.yaml

# 6. confirm it actually applied before touching the other node
talosctl -n 10.200.0.52 services              # everything still Running/OK?
kubectl get nodes                               # still Ready?

# 7. repeat 5-6 for the other node, then a final whole-cluster check
talosctl etcd members                           # cp1 only - w-1 isn't an etcd member
talosctl -n 10.200.0.52,10.200.0.7 health   # everything OK or expected SKIP
kubectl get pods -A | grep -v Running            # empty - nothing stuck

# 8. commit the patch change (out/ isn't committed - the patches are what's versioned)
git add patches/common.yaml
git commit -m "describe the change"
```

Applying one node at a time and verifying in between (steps 5-6) still matters even with a
single control-plane — a bad change to `common.yaml` would otherwise hit both nodes before you
notice, taking out the worker along with the only control-plane.

Most fields apply live with no downtime (this is how the taint and static-IP changes described
in "What was done to get here" below, back when they were still done by hand, went in). A few —
like the hostname — refuse to apply live and need `apply-config --mode=reboot` instead, which
Talos will tell you if you hit it: the error says something like *"static hostname is already
set"* rather than a generic failure. When in doubt, try without `--mode=reboot` first; it's a
safe no-op error if a reboot turns out to be required, it doesn't apply half the change.

`talosctl` also has a lower-level `talosctl edit mconfig -n 10.200.0.52` which opens the
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
This endpoint is content-addressed — the same extension list always resolves to the same
schematic ID, so re-running it is free and safe even when nothing actually changed.

### Day-to-day kubectl commands

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl top nodes / kubectl top pods -A   # needs metrics-server (not installed yet)
kubectl apply -f my-manifest.yaml         # deploy something
```

### Upgrading Kubernetes itself (separate from Talos OS upgrades)

```bash
talosctl -n 10.200.0.52 upgrade-k8s --to 1.37.0
```

### If you lose network access to the node

You still have the Proxmox console (VNC/serial) for out-of-band access — a Talos machine has no
shell, but the console shows boot/network diagnostics, which is the first thing to check if
`talosctl` or `kubectl` can't reach `10.200.0.52` after a config change.

## What was done to get here

This is the actual sequence of `talosctl` operations that took the VM from a blank Talos boot
to the cluster described in the root README's "Cluster facts".

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
mounted it at `/var/mnt/data`. See the root README's Storage section for what this is and how
it's meant to be used.

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
`machine.kubelet.extraMounts` for `/var/mnt/data` (see the root README's Networking/Storage
sections) — paths on the Talos host aren't visible inside the kubelet's own mount namespace
without this, which Longhorn's hostPath-based pods need.

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

Two things this did **not** fix: `cluster.controlPlane.endpoint` and Cilium's `k8sServiceHost`
were both still hardcoded to cp1's IP — at the time this meant real HA would need a floating VIP
across control-plane nodes. Moot as of step 13 below: going back to a single control-plane
means there's only one node these could ever point to anyway.

**12. Restructured the committed config from full per-node files into patches.** Steps 1-11
above happened by hand-editing the full `talos/_out/controlplane.yaml` / `controlplane-cp2.yaml`
directly, which is genuinely how it went — that history is preserved above as-written, not
rewritten to match current tooling. The config was then restructured into
`talos/patches/common.yaml` (everything shared by both nodes) plus each node's own
`talos/patches/talos-cp1.yaml`/`talos-cp2.yaml` (static IP + hostname, the only genuinely
per-node facts), with the cluster PKI extracted into `talos/secrets-sops-all.yaml` rather than
staying embedded in a full config file. Every field was verified to reproduce the exact same
running config — semantic diff (`yq -o=json 'sort_keys(..)'` on both sides, to strip
comment/ordering noise) against what was actually deployed, plus `talosctl validate --mode
metal` — before this was applied live via `talosctl apply-config` to `talos-cp1` then
`talos-cp2`, one at a time, with a full health check (`talosctl services`, `kubectl get nodes`)
between the two. Confirmed afterwards with `talosctl etcd members` (both non-learner),
`talosctl health` (all `OK`/expected `SKIP`), and a cluster-wide sweep for non-`Running` pods
(empty) — the restructure changed nothing about what's running, only how the same config is
authored and regenerated going forward (see "Changing the machine config" above).

**13. Converted `talos-cp2` into a worker (`w-1`), going back to a single control-plane.**
Decided the 2-node etcd from step 11 wasn't worth keeping - it has *zero* real fault tolerance
(quorum of 2 needs both members healthy, so it's strictly worse than a 1-node etcd, not more
resilient) - and simplicity was worth more than fake HA for a homelab. `machine.type`
(`controlplane` vs `worker`) is fixed at install time in Talos, not a live-patchable field, so
this meant wiping and rejoining the node, not a config change:

```bash
# safety net first - etcd holds every Kubernetes Secret in plaintext, treat the snapshot
# accordingly (not committed anywhere, kept local-only)
talosctl -n 192.168.1.252 etcd snapshot out/etcd-backups/etcd-$(date +%Y%m%d-%H%M%S).snapshot
```

Before wiping anything, checked what Longhorn data actually lived only on `talos-cp2` -
`kubectl get replicas.longhorn.io -n longhorn-system` (not just `volumes.longhorn.io`'s
`ownerID`, which only shows current attachment, not full replica placement) showed every
`longhorn-replicated` volume already had a synced replica on `talos-cp1` too, and the
`longhorn-strict-local` Postgres volumes were all CNPG replicas (primaries were already on
`cp1`) - so nothing irreplaceable was actually single-homed on `cp2`. Worth checking this fresh
each time rather than assuming, since `ownerID` alone gives a misleading picture.

```bash
talosctl -n 192.168.1.206 reset --graceful --reboot --wipe-mode system-disk
```
`--graceful` (default `true`) cordons/drains the node and leaves etcd *before* wiping anything -
etcd's membership drops to 1 (trivial quorum) before the node actually goes away, rather than
losing 1-of-2 with no warning. `--wipe-mode system-disk` (default is `all`) is what keeps
`/dev/sdb` - the actual Longhorn data disk - untouched; the default would have wiped it too.
Longhorn's own node-eviction safety logic (it tries to wait for a replica to exist elsewhere
before releasing the last one - a condition `strict-local` volumes can never satisfy by design)
didn't end up hanging the drain this run, but it's a known rough edge of `strict-local` worth
knowing about before draining a node that has any.

Wiping `/dev/sda` means there's no OS left to boot from - the node came back to a UEFI "no
bootable option" screen, needing the Talos installer ISO re-attached/boot-ordered in Proxmox to
re-enter maintenance mode, same as a from-scratch node. Once it was back in maintenance mode (on
a fresh DHCP lease, `192.168.1.22` again in this case):

```bash
# worker, not controlplane - see "Changing the machine config" above for the full two-type flow
talosctl gen config talos-proxmox-cluster https://192.168.1.252:6443 \
  --with-secrets out/.secrets.yaml --kubernetes-version 1.36.2 \
  --output-types worker,talosconfig --output out/base-worker \
  --config-patch @patches/common.yaml --force
yq -i 'select(.kind != "HostnameConfig")' out/base-worker/worker.yaml
talosctl machineconfig patch out/base-worker/worker.yaml --patch @patches/w-1.yaml --output out/w-1.yaml
talosctl validate --config out/w-1.yaml --mode metal
talosctl apply-config --insecure -n 192.168.1.22 -f out/w-1.yaml
```
`patches/w-1.yaml` is `patches/talos-cp2.yaml` (deleted) with the hostname changed to `w-1` -
same static IP (`192.168.1.206/24`), since this is the same physical VM as before.

One thing that broke afterward: `talosctl etcd members` started failing with `PermissionDenied:
no request forwarding`. The talosconfig's **endpoints** list (the gRPC gateway `talosctl`
connects through - separate from `-n`/`--nodes`, which just selects which node's data to
fetch) still had `192.168.1.206` in it from step 11, and a worker apparently can't forward
admin-level requests like etcd queries the way a control-plane node can. Fixed by dropping it
back to just the control-plane:
```bash
talosctl config endpoint 192.168.1.252
```

Verified with `talosctl -n 192.168.1.252 etcd members` (`talos-cp1` only), `kubectl get nodes`
(`w-1` `Ready`, role `<none>`), `kubectl delete node talos-cp2` (the old `Node` object doesn't
go away on its own, same as every previous rename in this history), and a cluster-wide pod
sweep once things settled - the `Pending` CNPG replicas and DaemonSet pods that had been on
`cp2` rescheduled onto `w-1` on their own once it came `Ready`, no manual intervention needed.
