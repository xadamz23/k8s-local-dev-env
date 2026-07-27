#!/usr/bin/env bash
# Pull the Netskope certs out of the combined keychain bundle.
#
#   ./scripts/extract-ca.sh [~/nscacert_combined.pem]
#
# Produces scripts/netskope.crt containing just the Netskope root + your
# tenant's signing CA. That trimmed file is what gets APPENDED to trust
# stores that already have the public roots (Colima VM, kind node image).
# The full combined bundle is used elsewhere, to REPLACE a container's
# bundle wholesale -- see README.
set -euo pipefail

SRC="${1:-$HOME/nscacert_combined.pem}"
OUT="$(dirname "$0")/netskope.crt"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

[[ -f "$SRC" ]] || { echo "not found: $SRC"; exit 1; }

awk '/BEGIN CERTIFICATE/{n++} {print > ("'"$WORK"'/c-" n ".pem")}' "$SRC"

: > "$OUT"
for c in "$WORK"/c-*.pem; do
  if openssl x509 -in "$c" -noout -subject -issuer 2>/dev/null | grep -qi 'netskope\|goskope'; then
    cat "$c" >> "$OUT"
  fi
done

N=$(grep -c 'BEGIN CERTIFICATE' "$OUT" || true)
echo "==> wrote $OUT ($N certs)"
openssl crl2pkcs7 -nocrl -certfile "$OUT" 2>/dev/null \
  | openssl pkcs7 -print_certs -noout 2>/dev/null | grep '^subject' | sed 's/^/    /'

[[ "$N" -ge 2 ]] || { echo "!! expected at least 2 (root + tenant CA). Check the source bundle."; exit 1; }
