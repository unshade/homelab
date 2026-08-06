#!/usr/bin/env bash
# Re-encrypts talos/out/kubeconfig into the committed talos/kubeconfig.enc.yaml.
# Run this after './talos.sh kubeconfig'.
#
# Machine configs are no longer handled here - see talos/secrets-sops-all.yaml
# (the cluster PKI, committed encrypted, generated once ever) and
# talos/patches/ (everything else, plaintext, not secret). Full per-node
# configs are regenerated on demand via './talos.sh render' into the
# gitignored talos/out/, never committed.
set -euo pipefail
cd "$(dirname "$0")/.."

sops -e --input-type yaml --filename-override kubeconfig.enc.yaml out/kubeconfig > kubeconfig.enc.yaml

echo "Encrypted: kubeconfig.enc.yaml"
