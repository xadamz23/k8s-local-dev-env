# Local platform lab — kind + Argo CD on Apple Silicon, behind Netskope

End-to-end from a clean Mac. Everything after Step 7 is GitOps; before that
it's four imperative commands that can't be, and the README explains why.

**If you already have a cluster, tear it down first:**

```bash
kind delete cluster --name macos    # or whatever you named it
colima delete                        # optional; Step 3 changes VM state anyway
```

---

## The one thing to understand before you start

Netskope terminates TLS. Every connection you make gets re-signed by a
Netskope CA, and anything that doesn't trust that CA fails with
`x509: certificate signed by unknown authority`.

**There are four independent trust stores in this stack.** Fixing one does
not fix the others, and each failure looks like a different bug:

| # | Trust store | What breaks without it | Fixed in |
|---|---|---|---|
| 1 | macOS keychain | nothing — already trusted | — |
| 2 | Colima VM | `docker pull`, `docker build` | Step 3 |
| 3 | kind nodes (containerd) | image pulls → `ImagePullBackOff` | Step 4 |
| 4 | pod containers | repo-server git clone → `x509` on the root app | Step 7 |

Store 4 is the sneaky one. Every container image ships its own
`/etc/ssl/certs`, so a perfectly-trusting node still runs pods that fail.

Two forms of the cert, used for different jobs:

- **`scripts/netskope.crt`** — Netskope root + your tenant CA only. *Appended*
  to stores that already have public roots (Colima VM, node image).
- **`~/nscacert_combined.pem`** — Netskope + all public roots. *Replaces* a
  container's bundle wholesale. Using the trimmed file here would break every
  connection Netskope isn't intercepting.

---

## Step 1 — Tools

```bash
brew install colima docker kubectl helm kind
softwareupdate --install-rosetta --agree-to-license
```

## Step 2 — Extract the CA

```bash
git clone <this repo> && cd gitops     # or just cd into it
chmod +x scripts/*.sh
./scripts/extract-ca.sh ~/nscacert_combined.pem
cp ~/nscacert_combined.pem scripts/
```

Expect `wrote scripts/netskope.crt (2 certs)` — the Netskope root and your
tenant's `ca.*.goskope.com` signing CA. Both are already gitignored.

## Step 3 — Colima, with CA and inotify limits

```bash
colima start --cpu 6 --memory 14 --disk 100 --vm-type vz --vz-rosetta --runtime docker
```

Scale to your machine. On 16GB drop to `--cpu 4 --memory 10` and cut
`kind-cluster.yaml` to one worker.

```bash
# trust store #2
colima ssh -- sudo tee /usr/local/share/ca-certificates/netskope.crt \
  < scripts/netskope.crt >/dev/null
colima ssh -- sudo update-ca-certificates
colima ssh -- sudo systemctl restart docker

# inotify — Prometheus + Argo + Envoy will exhaust the defaults and you'll
# see "too many open files" on pods that were healthy a minute ago
colima ssh -- sudo sh -c 'printf "fs.inotify.max_user_watches=1048576\nfs.inotify.max_user_instances=8192\n" > /etc/sysctl.d/99-kind.conf'
colima ssh -- sudo sysctl --system

# verify: issuer should now chain to something you trust
docker pull alpine:latest && echo "VM trust store OK"
```

Both survive `colima stop/start`. Neither survives `colima delete`.

## Step 4 — Build a node image that trusts Netskope

Baking the CA in means you never patch a running cluster.

```bash
docker build -f scripts/Dockerfile.node -t kindest-netskope:v1.36.1 scripts/
```

Match the tag to your kind version's default node image (`kind version`, then
check the release notes). `v1.36.1` is known-good here.

## Step 5 — Create the cluster

```bash
kind create cluster --config kind-cluster.yaml --image kindest-netskope:v1.36.1
kubectl config use-context kind-dev
kubectl get nodes
```

## Step 6 — Verify before installing anything

Pods running does not prove the kubeadm patches applied, and that's the whole
reason for choosing kind over k3d. Check while the cluster is still empty.

```bash
# want 0.0.0.0 on both bind-address lines and http://0.0.0.0:2381 for etcd
docker exec dev-control-plane grep -hE 'bind-address|listen-metrics-urls' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml \
  /etc/kubernetes/manifests/kube-scheduler.yaml \
  /etc/kubernetes/manifests/etcd.yaml

# want 30080/tcp -> 0.0.0.0:80 and 30443/tcp -> 0.0.0.0:443
docker port dev-control-plane

# trust store #3 — this is the pull that used to fail
docker exec dev-worker crictl pull ecr-public.aws.com/docker/library/redis:8.2.3-alpine

kubectl get sc                    # want "standard (default)"
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

If `bind-address` says `127.0.0.1`, recreate now — far easier than debugging
dead Prometheus targets in an hour.

## Step 7 — Argo CD

The CA ConfigMap must exist **before** the Helm install, so repo-server comes
up trusting Netskope on first boot.

**This ConfigMap cannot live in git** — repo-server needs it in order to read
git. That circularity is why Steps 7a–7c are imperative and can't be GitOps'd.

```bash
# 7a — namespace and trust store #4
kubectl create namespace argocd
kubectl -n argocd create configmap custom-ca-bundle \
  --from-file=ca-certificates.crt=scripts/nscacert_combined.pem

# 7b — install
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm install argocd argo/argo-cd -n argocd -f bootstrap/argocd-values.yaml --wait

# 7c — credentials
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Confirm the mount took before going further:

```bash
kubectl -n argocd exec deploy/argocd-repo-server -- \
  grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt   # ~175
```

## Step 8 — Push the repo, hand over control

```bash
# both bootstrap/root-app.yaml and apps/platform-config.yaml carry the placeholder
grep -rn YOUR_ORG .
grep -rl 'YOUR_ORG' . | xargs sed -i '' \
  's#https://github.com/YOUR_ORG/k8s-local-dev-env.git#https://github.com/xadamz23/k8s-local-dev-env.git#'

git init && git add . && git commit -m "platform bootstrap"
git remote add origin https://github.com/you/k8s-lab.git && git push -u origin main
```

Make the repo **private** — the `.gitignore` keeps the CA out, but a private
repo is the right default here. Then register credentials:

> NOTE: I could not get `argocd login` to work. So I just did a `k apply -f bootstrap/add-repo.yaml` to connect my github repo.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
argocd login localhost:8080 --username admin --password <from 7c> --plaintext
argocd repo add https://github.com/you/k8s-lab.git \
  --username you --password <fine-grained-PAT, Contents: read>
```

Public repo? Skip the `repo add` entirely.

```bash
kubectl apply -f bootstrap/root-app.yaml
kubectl -n argocd get applications -w
```

## Step 9 — Reach it

```
http://argocd.127.0.0.1.sslip.io
http://grafana.127.0.0.1.sslip.io      (admin / admin)
```

Once Envoy answers on :80, kill the port-forward.

```bash
kubectl top nodes                        # metrics-server
kubectl -n envoy-gateway-system get svc   # MetalLB VIP on the Envoy service
```

## Step 10 — Tighten up

1. **Pin every chart version.** They're all `targetRevision: "*"` so I wasn't
   inventing numbers. Once a sync is green, pin them, or a chart release will
   break your cluster during a self-heal.
2. **Enable the metrics-server ServiceMonitor.** Flip `metrics.enabled` and
   `serviceMonitor.enabled` to `true` in `apps/metrics-server.yaml` and commit.
   They're off because the CRD doesn't exist at wave 0, and a failed wave 0
   blocks every later wave.
3. **Trust the local CA** for real TLS:
   ```bash
   kubectl -n cert-manager get secret local-ca-tls -o jsonpath='{.data.tls\.crt}' \
     | base64 -d > /tmp/local-ca.crt
   sudo security add-trusted-cert -d -k /Library/Keychains/System.keychain /tmp/local-ca.crt
   ```
4. **Replace the ESO `fake` provider** with OpenBAO or Vault in dev mode as
   another Argo Application.

---

## Troubleshooting

**`ImagePullBackOff` + `x509`** → trust store #3. Cluster predates the custom
node image, or you forgot `--image`. Repair in place:
`./scripts/netskope-ca.sh dev`

**Root app `ComparisonError` + `x509`** → trust store #4. ConfigMap missing or
the volume mount didn't land:
```bash
kubectl -n argocd get cm custom-ca-bundle
kubectl -n argocd describe deploy argocd-repo-server | grep -A3 custom-ca
```

**Mount reverts a few minutes after you fix it** → the CA block is in
`bootstrap/argocd-values.yaml` but not `apps/argocd.yaml`. selfHeal is
reverting you. They must match.

**Prometheus control-plane targets down** → Step 6 kubeadm check failed.

**`localhost` returns nothing but the Gateway looks healthy** → the EnvoyProxy
NodePort patch is a strategic merge keyed on port *name*. If Envoy Gateway
generated something other than `http-80`/`https-443` it silently no-ops:
```bash
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=dev -o yaml
```

**`envoy-gateway` app fails on first sync** → OCI Helm repo registration.
Check `configs.repositories` made it into `argocd-cm`.

**Pods crash with "too many open files"** → inotify limits, Step 3.

**Push doesn't sync for ~3 min** → Argo polls; GitHub webhooks can't reach a
laptop behind NAT. Force with `argocd app get root --refresh`.

---

## Layout

```
kind-cluster.yaml            topology + control-plane scrape patches
scripts/extract-ca.sh        pull Netskope certs out of the combined bundle
scripts/Dockerfile.node      node image with the CA baked in
scripts/netskope-ca.sh       repair an already-running cluster
bootstrap/argocd-values.yaml values for the one-time helm install
bootstrap/root-app.yaml      app-of-apps, applied by hand once
apps/*.yaml                  one Argo Application per component
manifests/platform/*.yaml    raw CRs depending on wave-0 CRDs
```

Sync waves: `0` controllers + CRDs · `1` platform config (MetalLB pool,
issuers, Gateway) · `2` kube-prometheus-stack.

Adding a component later = drop an `Application` into `apps/` and push. The
root app recurses that directory, so nothing else needs editing.
