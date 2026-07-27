#!/usr/bin/env bash
# Inject the Netskope MITM root CA everywhere a local kind cluster needs it.
#
#   ./scripts/netskope-ca.sh [cluster-name]
#
# Netskope terminates TLS, so anything that does not trust its root CA sees
# "x509: certificate signed by unknown authority". macOS trusts it via the
# keychain; Linux VMs and containers do not. There are four separate trust
# stores in this stack and fixing one does not fix the others:
#
#   1. the Colima VM        -> `docker pull`, kind node images
#   2. the kind nodes       -> containerd/kubelet image pulls
#   3. pods that call out   -> argocd-repo-server (git clone + helm fetch)
#   4. macOS itself         -> already fine, keychain has it
#
# Re-run this after every `kind create cluster`, or bake the CA into a custom
# node image (see scripts/Dockerfile.node) to skip steps 1-2 permanently.

set -euo pipefail

CLUSTER="${1:-macos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- locate CA
# Netskope ships two bundles:
#   nscacert.pem           - just the Netskope root
#   nscacert_combined.pem  - Netskope root + the public Mozilla roots
# We want the plain root for update-ca-certificates (which appends to the
# system store), and the combined one for wholesale bundle replacement in pods.
CA_SRC="${NETSKOPE_CA:-}"

if [[ -z "$CA_SRC" ]]; then
  for c in \
    "/Library/Application Support/Netskope/STAgent/download/nscacert.pem" \
    "/Library/Application Support/Netskope/STAgent/data/nscacert.pem" \
    "$HOME/Library/Application Support/Netskope/STAgent/download/nscacert.pem"
  do
    [[ -f "$c" ]] && { CA_SRC="$c"; break; }
  done
fi

if [[ -z "$CA_SRC" ]]; then
  echo "Could not auto-locate the Netskope CA. Find it with:"
  echo "  sudo find /Library /Applications -iname 'nscacert*' 2>/dev/null"
  echo "  grep -ri 'NODE_EXTRA_CA_CERTS\|nscacert' <your-team-claude-code-script>"
  echo "Then re-run:  NETSKOPE_CA=/path/to/nscacert.pem $0 $CLUSTER"
  exit 1
fi

echo "==> Using CA bundle: $CA_SRC"

# update-ca-certificates only reads the FIRST cert from each .crt file, so a
# multi-cert PEM must be split. Extra public roots are harmless duplicates.
awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} {print > ("'"$WORK"'/netskope-" n ".crt")}' "$CA_SRC"
COUNT=$(ls "$WORK"/netskope-*.crt 2>/dev/null | wc -l | tr -d ' ')
echo "==> Split into $COUNT certificate(s)"

# ------------------------------------------------------------- 1. Colima VM
if command -v colima >/dev/null && colima status >/dev/null 2>&1; then
  echo "==> Installing into the Colima VM"
  for f in "$WORK"/netskope-*.crt; do
    colima ssh -- sudo tee "/usr/local/share/ca-certificates/$(basename "$f")" >/dev/null < "$f"
  done
  colima ssh -- sudo update-ca-certificates >/dev/null
  colima ssh -- sudo systemctl restart docker
  echo "    done (docker restarted)"
fi

# ----------------------------------------------------------- 2. kind nodes
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "==> Installing into kind nodes (cluster: $CLUSTER)"
  for n in $(kind get nodes --name "$CLUSTER"); do
    for f in "$WORK"/netskope-*.crt; do
      docker cp "$f" "$n:/usr/local/share/ca-certificates/$(basename "$f")"
    done
    docker exec "$n" update-ca-certificates >/dev/null 2>&1
    docker exec "$n" systemctl restart containerd
    echo "    $n"
  done
  echo "    waiting for nodes to settle..."
  kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1 || true
else
  echo "==> No kind cluster named '$CLUSTER'; skipping node injection"
fi

# --------------------------------------------------- 3. argocd trust bundle
# Pods carry their own CA store from their base image, so fixing the node does
# NOT fix argocd-repo-server cloning GitHub. Build a COMBINED bundle (public
# roots + Netskope) and mount it over the container's system bundle. Using the
# Netskope root alone here would break every non-intercepted TLS connection.
if kubectl get ns argocd >/dev/null 2>&1; then
  echo "==> Creating combined CA bundle ConfigMap in argocd namespace"
  COMBINED="$WORK/ca-certificates.crt"
  : > "$COMBINED"
  # start from the node image's public roots so we are additive, not replacing
  docker exec "$(kind get nodes --name "$CLUSTER" | head -1)" \
    cat /etc/ssl/certs/ca-certificates.crt >> "$COMBINED" 2>/dev/null || true
  cat "$WORK"/netskope-*.crt >> "$COMBINED"

  kubectl -n argocd create configmap custom-ca-bundle \
    --from-file=ca-certificates.crt="$COMBINED" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    configmap/custom-ca-bundle created ($(grep -c 'BEGIN CERTIFICATE' "$COMBINED") certs)"
  echo
  echo "    Now add the volume block from scripts/argocd-ca-values.yaml to BOTH"
  echo "    bootstrap/argocd-values.yaml and apps/argocd.yaml, then:"
  echo "      kubectl -n argocd rollout restart deploy/argocd-repo-server"
else
  echo "==> No argocd namespace yet; re-run this after installing Argo CD"
fi

echo
echo "==> Verify:"
echo "  docker exec ${CLUSTER}-worker sh -c 'echo | openssl s_client -connect ecr-public.aws.com:443 -servername ecr-public.aws.com 2>/dev/null | openssl x509 -noout -issuer'"
echo "  docker exec ${CLUSTER}-worker crictl pull ecr-public.aws.com/docker/library/redis:8.2.3-alpine"
