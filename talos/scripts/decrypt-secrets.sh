#!/usr/bin/env bash
# Restores the plaintext files in talos/_out/ from the committed .enc.yaml
# copies. Run this after a fresh git clone, before using talosctl/kubectl.
set -euo pipefail
cd "$(dirname "$0")/../_out"

sops -d controlplane.enc.yaml > controlplane.yaml
sops -d controlplane-cp2.enc.yaml > controlplane-cp2.yaml
sops -d worker.enc.yaml > worker.yaml
sops -d talosconfig.enc.yaml > talosconfig
sops -d kubeconfig.enc.yaml > kubeconfig
chmod 600 kubeconfig

echo "Decrypted: controlplane.yaml controlplane-cp2.yaml worker.yaml talosconfig kubeconfig"
