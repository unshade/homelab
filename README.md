# homelab

Single-node [Talos Linux](https://www.talos.dev/) Kubernetes cluster running as a VM on Proxmox.

## Cluster facts

| | |
|---|---|
| Cluster name | `talos-proxmox-cluster` |
| Node hostname | `talos-cp1` |
| Node IP | `192.168.1.252` (static) |
| Interface | `ens18` |
| Gateway | `192.168.1.254` |
| Talos version | v1.13.5 |
| Kubernetes version | v1.36.2 |
| CNI | flannel |
| Role | control-plane, with `allowSchedulingOnControlPlanes: true` so regular pods schedule on it too (it's the only node) |
| Data disk | `sdb`, 430GB, XFS, mounted at `/var/mnt/data` (see Storage section) |

> The node's static IP (`192.168.1.252`) should be excluded from your router's DHCP pool so it never gets handed out to something else.

## Repo layout

```
talos/
  _out/
    controlplane.yaml       # plaintext machine config (gitignored, has private keys)
    controlplane.enc.yaml   # sops-encrypted version (committed)
    worker.yaml / worker.enc.yaml   # not used (single-node), kept for reference
    talosconfig / talosconfig.enc.yaml   # talosctl client credentials
    kubeconfig / kubeconfig.enc.yaml     # kubectl client credentials
  scripts/
    decrypt-secrets.sh      # sops -d the .enc.yaml files into plaintext, for local use
    encrypt-secrets.sh      # sops -e the plaintext files back into .enc.yaml, before commit
.sops.yaml                  # tells sops which GPG key encrypts *.enc.yaml files
.gitignore                  # excludes the plaintext secret files from git
```

## Secrets: how this is versioned

`controlplane.yaml`, `talosconfig`, and `kubeconfig` all contain real private keys, cluster
tokens, and client certs in plaintext — never committed as-is. Instead:

- They're encrypted with [SOPS](https://github.com/getsops/sops) against a GPG key, producing
  the `*.enc.yaml` files that **are** committed to git.
- The key used is `noesteiner@proton.me` (fingerprint
  `0838E38422232D44B96B6C7659A7C95E7A016E5A`, labeled "Used for SOPS on kaastorama kube
  cluster" — reused here for consistency with the other cluster). `.sops.yaml` at the repo root
  pins this fingerprint as the encryption target.
- Decryption needs the matching **private** GPG key in your local keyring (`gpg
  --list-secret-keys`) and `gpg-agent` running — sops shells out to `gpg` automatically, no
  extra env vars needed. Make sure this private key is backed up (e.g. `gpg --export-secret-keys
  --armor 0838E38422232D44B96B6C7659A7C95E7A016E5A`, stored somewhere durable) — if you lose it
  and lose this machine, you can't decrypt the committed secrets and would have to regenerate
  the cluster's PKI from scratch.

**After cloning this repo on a new machine:**
```bash
brew install sops gnupg
# import your backed-up private key: gpg --import <key-file>
talos/scripts/decrypt-secrets.sh
```

**After editing `controlplane.yaml` (or any plaintext file in `talos/_out/`):**
```bash
talos/scripts/encrypt-secrets.sh
git add talos/_out/*.enc.yaml
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

## Storage

`UserVolumeConfig` is a **Talos** machine config document, not a Kubernetes resource — it lives
in `controlplane.yaml` alongside `HostnameConfig`, and it's how Talos itself (not Kubernetes)
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
pods can claim. That part isn't set up yet — the plan discussed was
[local-path-provisioner](https://github.com/rancher/local-path-provisioner) pointed at
`/var/mnt/data`, since for a single node it gives dynamic PVC provisioning without the
complexity of something like Longhorn (which is built for replicating across multiple nodes —
no benefit here, only overhead).

**TODO — cold storage:** a separate NFS-backed `StorageClass`, backed by a ZFS dataset exported
from the Proxmox host itself rather than this local disk. Trades a bit of performance for the
ability to browse/manage/snapshot the data directly from Proxmox, which a local block device
fundamentally can't offer — `sdb`/`/var/mnt/data` stays reserved for regular fast PVCs.

## Managing the cluster

Two separate CLIs, two separate credential files:

- **`talosctl`** — talks to the Talos OS itself (not Kubernetes): reboot, upgrade, disk/network
  state, service health, logs. Uses `talos/_out/talosconfig`.
- **`kubectl`** — talks to the Kubernetes API: pods, deployments, services. Uses
  `talos/_out/kubeconfig`.

Set these once per shell session so you don't have to pass flags every time:
```bash
export TALOSCONFIG=talos/_out/talosconfig
export KUBECONFIG=talos/_out/kubeconfig
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

Step by step, e.g. to change something in `controlplane.yaml`:

```bash
# 1. decrypt, if you don't already have the plaintext locally
talos/scripts/decrypt-secrets.sh

# 2. edit the file
$EDITOR talos/_out/controlplane.yaml

# 3. push it to the node
talosctl -n 192.168.1.252 apply-config -f talos/_out/controlplane.yaml

# 4. confirm it actually applied (also useful right after any change):
talosctl -n 192.168.1.252 services              # everything still Running/OK?
kubectl get nodes                               # still Ready?

# 5. re-encrypt and commit, so the change is captured in git
talos/scripts/encrypt-secrets.sh
git add talos/_out/*.enc.yaml
git commit -m "describe the change"
```

Most fields apply live in step 3 with no downtime (this is how the taint and static-IP changes
above were done). A few — like the hostname — refuse to apply live and need
`apply-config ... --mode=reboot` instead, which Talos will tell you if you hit it: the error
says something like *"static hostname is already set"* rather than a generic failure. When in
doubt, try without `--mode=reboot` first; it's a safe no-op error if a reboot turns out to be
required, it doesn't apply half the change.

`talosctl` also has a lower-level `talosctl edit mconfig -n 192.168.1.252` which opens the
node's *live* config in `$EDITOR` and applies on save — convenient for a quick one-off tweak,
but it bypasses the file in `talos/_out/`, so anything changed that way needs to be copied back
into `controlplane.yaml` by hand afterwards or it'll silently drift from what's in git.

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
