#!/usr/bin/env bash
# Decrypts every committed *-sops.yaml secret in the repo into a sibling
# *-sops.dec.yaml file, so you can actually read passwords/tokens/etc.
# locally without running `sops -d` by hand each time. The .dec.yaml files
# are gitignored — never committed, regenerate anytime with this script.
#
# This is read-only convenience: to change a secret's value, edit the real
# *-sops.yaml file directly with `sops <file>` (opens decrypted in $EDITOR,
# re-encrypts on save), then re-run this script to refresh the copy.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
while read -r f; do
  out="${f%.yaml}.dec.yaml"
  if sops -d "$f" > "$out" 2>/tmp/decrypt-sops-err.$$; then
    echo "Decrypted: $out"
  else
    echo "FAILED to decrypt: $f"
    cat /tmp/decrypt-sops-err.$$
    rm -f "$out" /tmp/decrypt-sops-err.$$
    fail=1
  fi
done < <(find . -name "*-sops.yaml" -not -path "./.git/*")

exit $fail
