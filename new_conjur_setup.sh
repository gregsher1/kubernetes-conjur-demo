#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Parse kwargs
###############################################################################
SKIP_PREREQS=false

for arg in "$@"; do
  case "$arg" in
    --skip-prereqs|-s) SKIP_PREREQS=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

###############################################################################
# 0. Prerequisites (kubectl v1.30.0, kind v0.23.0, Helm, Conjur CLI v8.1.1)
###############################################################################
# Inspired by the tooling installation steps in **ci/Dockerfile**
# (see lines 6-33) which install kubectl, Helm and other dependencies.
if [ "$SKIP_PREREQS" = false ]; then
  sudo apt-get update -y
  sudo apt-get install -y curl jq ca-certificates gnupg lsb-release

  # kubectl
  curl -LO https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl
  curl -LO https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl.sha256
  # sha256sum expects "<hash><space><space><filename>"
  printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check
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
else
  echo "⚠️  Skipping prerequisite install (user requested --skip-prereqs)"
fi


###############################################################################
# 1. Spin up - or reuse - a Kind cluster
###############################################################################
# Simplified alternative to the Kubernetes cluster setup performed in
# **ci/test** during automated testing.
if [ "$SKIP_PREREQS" = false ]; then
  echo "1. Spin up - or reuse - a Kind cluster"
  CLUSTER=conjur-poc
  K8S_VERSION=v1.30.0

  if kind get clusters | grep -qx "$CLUSTER"; then
    echo "Kind cluster '$CLUSTER' already exists - re-using it"
  else
    echo "Creating Kind cluster '$CLUSTER'"
    kind create cluster --name "$CLUSTER" --image "kindest/node:${K8S_VERSION}"
  fi

  kubectl cluster-info --context "kind-${CLUSTER}"
fi   # <--- add this



###############################################################################
# 2. Install (or reuse) Conjur OSS with authenticator enabled
###############################################################################
# Adapted from the Helm install logic in **ci/test** (see lines 132-153)
# that deploy Conjur OSS and retrieve the admin API key.
echo "2. Install (or reuse) Conjur OSS with authenticator enabled"

helm repo add cyberark https://cyberark.github.io/helm-charts
helm repo update

RELEASE=conjur-oss
NAMESPACE=conjur-system
AUTHNS='authn-k8s/dev-cluster\,authn'        # comma must be escaped for Helm
DATA_KEY=$(docker run --rm cyberark/conjur data-key generate)

if helm -n "$NAMESPACE" ls | grep -q "^${RELEASE}\b"; then
  echo "👉 Helm release '$RELEASE' already exists - upgrading in place"
  helm upgrade "$RELEASE" cyberark/conjur-oss \
    --namespace "$NAMESPACE" --reuse-values \
    --set "authenticators=${AUTHNS}"
else
  echo "👉 Installing Conjur OSS"
  helm install "$RELEASE" cyberark/conjur-oss \
    --namespace "$NAMESPACE" --create-namespace \
    --set "dataKey=${DATA_KEY}" \
    --set "authenticators=${AUTHNS}" \
    --set account.create=true \
    --set account.name=demo
fi

sleep 10

kubectl -n conjur-system wait pod -l app=conjur-oss --for=condition=ready --timeout=120s

POD=$(kubectl -n conjur-system get pod -l app=conjur-oss -o jsonpath='{.items[0].metadata.name}')
ADMIN_API_KEY=$(kubectl -n conjur-system exec "$POD" -c conjur-oss -- \
  conjurctl role retrieve-key demo:user:admin | tail -1)
echo "$ADMIN_API_KEY" > /tmp/conjur_admin.key

###############################################################################
# 2 b. Ensure we have a valid admin API-key
###############################################################################
# Mirrors the admin API-key retrieval in **ci/test** around lines 156-163
# where the Conjur pod is queried for the admin user's key.
echo "2 b. Ensure we have a valid admin API-key"

# Identify the Conjur pod we’ll exec into
POD=$(kubectl -n conjur-system get pod -l app=conjur-oss \
              -o jsonpath='{.items[0].metadata.name}')

# First attempt: retrieve the key for an *existing* demo account.
#    If the account is present, this returns a non-empty string.
set +e   # suppress immediate exit so we can test the result
ADMIN_API_KEY=$(
  kubectl -n conjur-system exec "$POD" -c conjur-oss -- \
    conjurctl role retrieve-key demo:user:admin 2>/dev/null | tail -1
)

# Second attempt (only if ➋ failed): create the account once and
#    capture the new admin key. This runs only the first time.
if [[ -z "$ADMIN_API_KEY" ]]; then
  ADMIN_API_KEY=$(
    kubectl -n conjur-system exec "$POD" -c conjur-oss -- \
      conjurctl account create demo 2>/dev/null | \
      awk '/API key for admin:/ {print $NF}'
  )
fi
set -e   # restore “exit on error” behaviour

# Safety check: if we *still* don’t have a key, bail out early.
if [[ -z "$ADMIN_API_KEY" ]]; then
  echo "ERROR: could not obtain Conjur admin API-key; aborting." >&2
  exit 1
fi

# Persist the key for later CLI login
echo "$ADMIN_API_KEY" > /tmp/conjur_admin.key


###############################################################################
# 3. Expose Conjur with a hostname that matches the TLS certificate & log in
###############################################################################
# Port-forward and login flow adapted from **8_app_verify_authentication.sh**
# (see lines 92-99) which set up temporary access to Conjur.
echo "3. Expose Conjur locally and log in with CLI (hostname = conjur.myorg.com)"

# ── 3-a. Ensure /etc/hosts maps conjur.myorg.com → 127.0.0.1 ────────────────
if ! grep -qE '^\s*127\.0\.0\.1\s+conjur\.myorg\.com' /etc/hosts; then
  echo "Adding conjur.myorg.com → 127.0.0.1 mapping"
  echo "127.0.0.1  conjur.myorg.com" | sudo tee -a /etc/hosts
fi

# ── 3-b. (Re)start the port-forward, killing any stale one first ────────────
PF_PID=$(pgrep -f "kubectl .*8443:443") || true
if [[ -n "${PF_PID:-}" ]]; then
  echo "Stopping existing port-forward (PID $PF_PID)"
  kill "$PF_PID"
fi

kubectl -n conjur-system port-forward svc/conjur-oss 8443:443 >/dev/null 2>&1 &
sleep 3   # give kubectl a moment to connect

# ── 3-c. (Re)init the CLI so it uses the SAN on the cert ────────────────────
conjur init --force \
  -u https://conjur.myorg.com:8443 \
  -a demo \
  --self-signed

# ── 3-d. Login using the admin API key ──────────────────────────────────────
if ! conjur login -i admin -p "$ADMIN_API_KEY"; then
  echo "ERROR: Conjur login failed - please verify ADMIN_API_KEY" >&2
  exit 1
fi
echo "✅  Conjur CLI authenticated as admin"


###############################################################################
# 4. Define authn-k8s webservice (service-id: dev-cluster)
###############################################################################
# Policy structure mirrors **policy/templates/cluster-authn-svc-def.template.yml**
echo "4. Define authn-k8s webservice (service-id: dev-cluster)"
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
# See **kubernetes/test-app-conjur-authenticator-role-binding.yml** for the
# original RBAC manifests this step corresponds to.


# ###############################################################################
# 6. Store cluster details in Conjur variables  (token & audience aligned)
# ###############################################################################
# Sets Conjur variables similar to the logic in **policy/load_policies.sh**
# (see lines 30-63) where database credentials are populated.
# ensure workload namespace exists before we mint its JWT
kubectl create namespace app-ns 2>/dev/null || true

echo "6. Store cluster details in Conjur variables"

AUDIENCE=kubernetes.default.svc                      # ← must match URL later
SA_JWT=$(kubectl -n app-ns create token default \
                 --audience="$AUDIENCE")

API_URL=$(kubectl config view --raw --minify --flatten \
          -o jsonpath='{.clusters[].cluster.server}')
CLUSTER_CA=$(kubectl config view --raw --minify --flatten \
             -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d)

conjur variable set -i conjur/authn-k8s/dev-cluster/api-url  -v "$API_URL"
conjur variable set -i conjur/authn-k8s/dev-cluster/ca-cert  -v "$CLUSTER_CA"
conjur variable set -i conjur/authn-k8s/dev-cluster/service-account-token -v "$SA_JWT"


###############################################################################
# 7. Application policy and secret
###############################################################################
# Based on the policy definitions generated in **policy/load_policies.sh** and
# templates under **policy/templates/** such as *app-identity-def.template.yml*.
echo "7. Application policy and secret"

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
# 8. Install / upgrade Conjur Secrets Provider (Job mode) - idempotent
###############################################################################
# This step is unique to this script; the repo's other automation deploys
# different demo apps but does not use the Secrets Provider helm chart.
echo "8. Install / upgrade Conjur Secrets Provider"

RELEASE=conjur-secrets-provider
NS=app-ns

# 8-a.  Stub Secret so the Job has a target to populate
kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: app-ns
type: Opaque
stringData:
  conjur-map: |
    app/db/creds/url: url
EOF

# 8-b.  Extract Conjur’s TLS cert for the Helm value
TLS_SECRET=$(kubectl -n conjur-system get secret -o jsonpath='{range .items[*]}{@.metadata.name}{"\n"}{end}' |
             grep -E 'conjur-oss-conjur-ssl-(ca-)?cert' | head -1)

kubectl -n conjur-system get secret "$TLS_SECRET" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/conjur_ca.pem

# 8-c.  Remove any previous Job (avoids immutable-field errors)
helm -n "$NS" uninstall "$RELEASE" --wait 2>/dev/null || true

# 8-d.  Install
helm install "$RELEASE" cyberark/secrets-provider \
  --namespace "$NS" --create-namespace \
  --set environment.k8sSecrets[0]=app-secrets \
  --set environment.conjur.account=demo \
  --set environment.conjur.applianceUrl=https://conjur-oss.conjur-system.svc.cluster.local \
  --set environment.conjur.authnUrl="https://conjur-oss.conjur-system.svc.cluster.local/authn-k8s/dev-cluster?audience=$AUDIENCE" \
  --set-file environment.conjur.sslCertificate.value=/tmp/conjur_ca.pem \
  --set environment.conjur.authnLogin=host/app/system:serviceaccount:app-ns:default \
  --set rbac.create=true \
  --set serviceAccount.create=false \
  --set serviceAccount.name=default

# 8-e.  Wait for first sync
kubectl -n "$NS" wait --for=condition=complete job/conjur-secrets-provider --timeout=180s


###############################################################################
# 9. Demo pod that retrieves the secret
###############################################################################
# Similar to the verification logic in **8_app_verify_authentication.sh**, but
# using a lightweight Alpine pod.
echo "9. Demo pod that retrieves the secret"
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
