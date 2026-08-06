#!/usr/bin/env bash
# Restores talos/out/kubeconfig from the committed talos/kubeconfig.enc.yaml.
# Run this after a fresh git clone, before using kubectl.
#
# talosctl access needs one more step first: './talos.sh render' (which
# itself decrypts talos/secrets-sops-all.yaml) to produce talos/out/talosconfig
# and the per-node configs - those are never committed, only regenerated.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p out
chmod 700 out
sops -d kubeconfig.enc.yaml > out/kubeconfig
chmod 600 out/kubeconfig

echo "Decrypted: out/kubeconfig"
