#!/usr/bin/env bash
# Re-encrypts the plaintext files in talos/_out/ into their committed .enc.yaml
# counterparts. Run this after any change to controlplane.yaml, worker.yaml,
# talosconfig, or kubeconfig.
set -euo pipefail
cd "$(dirname "$0")/../_out"

sops -e --filename-override controlplane.enc.yaml controlplane.yaml > controlplane.enc.yaml
sops -e --filename-override worker.enc.yaml worker.yaml > worker.enc.yaml
sops -e --input-type yaml --filename-override talosconfig.enc.yaml talosconfig > talosconfig.enc.yaml
sops -e --input-type yaml --filename-override kubeconfig.enc.yaml kubeconfig > kubeconfig.enc.yaml

echo "Encrypted: controlplane.enc.yaml worker.enc.yaml talosconfig.enc.yaml kubeconfig.enc.yaml"
