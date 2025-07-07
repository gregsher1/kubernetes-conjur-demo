#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 0. Prerequisites (kubectl v1.30.0, kind v0.23.0, Helm, Conjur CLI v8.1.1)
###############################################################################
sudo apt-get update -y
sudo apt-get install -y curl jq ca-certificates gnupg lsb-release

# kubectl
curl -LO https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl
curl -LO https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl.sha256
sha256sum --check kubectl.sha256
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# kind
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x kind && sudo mv kind /usr/local/bin/

# Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Conjur CLI
curl -L -o conjur-cli.deb \
  https://github.com/cyberark/conjur-cli-go/releases/download/v8.1.1/conjur-cli-go_8.1.1_amd64.deb
sudo dpkg -i conjur-cli.deb

###############################################################################
# 1. Spin up a Kind cluster
###############################################################################
kind create cluster --name conjur-poc --image kindest/node:v1.30.0
kubectl cluster-info --context kind-conjur-poc

###############################################################################
# 2. Install Conjur OSS with authenticator enabled
###############################################################################
helm repo add cyberark https://cyberark.github.io/helm-charts
helm repo update

helm install conjur-oss cyberark/conjur-oss \
  --namespace conjur-system --create-namespace \
  --set "dataKey=$(docker run --rm cyberark/conjur data-key generate)" \
  --set authenticators="authn,authn-k8s/dev-cluster" \
  --set account.create=true \
  --set account.name=demo

kubectl -n conjur-system wait pod -l app=conjur-oss --for=condition=ready --timeout=120s

POD=$(kubectl -n conjur-system get pod -l app=conjur-oss -o jsonpath='{.items[0].metadata.name}')
ADMIN_API_KEY=$(kubectl -n conjur-system exec "$POD" -c conjur-oss -- \
  conjurctl role retrieve-key demo:user:admin | tail -1)
echo "$ADMIN_API_KEY" > /tmp/conjur_admin.key

###############################################################################
# 3. Expose Conjur locally and log in with CLI
###############################################################################
pkill -f "kubectl .*8443:443" || true
kubectl -n conjur-system port-forward svc/conjur-oss 8443:443 &
sleep 3

conjur init -u https://localhost:8443 -a demo --self-signed
conjur login -i admin -p "$(cat /tmp/conjur_admin.key)"

###############################################################################
# 4. Define authn-k8s webservice (service-id: dev-cluster)
###############################################################################
cat > k8s-authn.yml <<'POLICY'
- !policy
  id: conjur/authn-k8s/dev-cluster
  body:
    - !webservice
    - !group admins
    - !permit
      role: !group admins
      privilege: [ read, authenticate ]
      resource: !webservice
    - !variable api-url
    - !variable ca-cert
    - !variable service-account-token
POLICY

conjur policy load -b root -f k8s-authn.yml

###############################################################################
# 5. Kubernetes resources for Conjur authentication
###############################################################################
cat <<'MANIFEST' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: conjur-authn
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: authn-k8s-sa
  namespace: conjur-authn
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: conjur-authn-k8s
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: authn-k8s-sa
  namespace: conjur-authn
MANIFEST

###############################################################################
# 6. Store cluster details in Conjur variables
###############################################################################
SA_JWT=$(kubectl -n conjur-authn create token authn-k8s-sa)
API_URL=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.server}')
CLUSTER_CA=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d)

conjur variable set -i conjur/authn-k8s/dev-cluster/api-url -v "$API_URL"
conjur variable set -i conjur/authn-k8s/dev-cluster/ca-cert -v "$CLUSTER_CA"
conjur variable set -i conjur/authn-k8s/dev-cluster/service-account-token -v "$SA_JWT"

###############################################################################
# 7. Application policy and secret
###############################################################################
kubectl create namespace app-ns || true

cat > app-policy.yml <<'POLICY'
- !policy
  id: app
  body:
    - !host
      id: system:serviceaccount:app-ns:default
    - !variable db/creds/url
POLICY

conjur policy load -b root -f app-policy.yml

cat > grant-app-host.yml <<'POLICY'
- !grant
  role: !group conjur/authn-k8s/dev-cluster/admins
  member: !host app/system:serviceaccount:app-ns:default
POLICY

conjur policy load -b root -f grant-app-host.yml
conjur variable set -i app/db/creds/url -v 'postgres://localhost'

###############################################################################
# 8. Install Conjur authn-k8s client sidecar injector
###############################################################################
helm repo add cyberark https://cyberark.github.io/helm-charts
helm repo update

helm install conjur-authn-client cyberark/conjur-authn-k8s-client \
  --namespace app-ns \
  --set conjur.account=demo \
  --set conjur.applianceURL=https://conjur-oss.conjur-system.svc.cluster.local \
  --set conjur.authenticatorID=dev-cluster \
  --set conjur.sslCA.cert="$CLUSTER_CA" \
  --set appServiceAccount.name=default \
  --set appServiceAccount.create=false

###############################################################################
# 9. Demo pod that retrieves the secret
###############################################################################
cat > demo.yml <<'POD'
apiVersion: v1
kind: Pod
metadata:
  name: demo
  namespace: app-ns
  annotations:
    conjur.org/conjur-secrets: |
      - db/creds/url
spec:
  serviceAccountName: default
  containers:
  - name: alpine
    image: alpine:3.20
    command: ["sh","-c","sleep 3600"]
POD

kubectl -n app-ns apply -f demo.yml
kubectl -n app-ns wait pod/demo --for=condition=ready --timeout=120s
kubectl -n app-ns exec demo -- cat /conjur/secrets/db/creds/url

###############################################################################
# 10. Cleanup (optional)
###############################################################################
# kind delete cluster --name conjur-poc
