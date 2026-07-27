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

# kubectl -n argocd port-forward svc/argocd-server 8080:80
# -> http://localhost:8080  (user: admin)
