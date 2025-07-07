#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CONFIG – tweak as desired
###############################################################################
# tool versions
K8S_VERSION=v1.30.0          # kubectl & kind node image
KIND_VERSION=v0.23.0
HELM_INSTALL_SCRIPT=https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
CONJUR_CLI_VERSION=8.1.1     # conjur-cli-go

# cluster & Conjur naming
CLUSTER=conjur-poc
ACCOUNT=demo
NAMESPACE=conjur-system
RELEASE=conjur-oss           # helm release
AUTHENTICATOR_ID=dev-cluster # demo scripts use this later

###############################################################################
# 0. OS packages + CLIs
###############################################################################
sudo apt-get update -y
sudo apt-get install -y curl jq ca-certificates gnupg lsb-release

# kubectl
if ! command -v kubectl >/dev/null 2>&1; then
  curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
  curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl.sha256"
  echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/
fi

# kind
if ! command -v kind >/dev/null 2>&1; then
  curl -Lo kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  chmod +x kind && sudo mv kind /usr/local/bin/
fi

# Helm
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL "$HELM_INSTALL_SCRIPT" | bash
fi

# Conjur CLI (Go implementation)
if ! command -v conjur >/dev/null 2>&1; then
  curl -L -o conjur-cli.deb \
    "https://github.com/cyberark/conjur-cli-go/releases/download/v${CONJUR_CLI_VERSION}/conjur-cli-go_${CONJUR_CLI_VERSION}_amd64.deb"
  sudo dpkg -i conjur-cli.deb
fi

###############################################################################
# 1. Local Kubernetes cluster (skip if already present)
###############################################################################
if ! kubectl config get-contexts "kind-${CLUSTER}" >/dev/null 2>&1; then
  kind create cluster --name "$CLUSTER" --image "kindest/node:${K8S_VERSION}"
fi
kubectl cluster-info --context "kind-${CLUSTER}"

###############################################################################
# 2. Install Conjur OSS via Helm
###############################################################################
helm repo add cyberark https://cyberark.github.io/helm-charts
helm repo update

# generate the Postgres encryption key once – per chart docs :contentReference[oaicite:0]{index=0}
DATA_KEY=$(docker run --rm cyberark/conjur data-key generate)

# install if not already present
if ! helm -n "$NAMESPACE" get values "$RELEASE" >/dev/null 2>&1; then
  helm install "$RELEASE" cyberark/conjur-oss \
    --namespace "$NAMESPACE" --create-namespace \
    --set dataKey="$DATA_KEY" \
    --set account.create=true,account.name="$ACCOUNT"
fi

# wait for Conjur to be ready
kubectl -n "$NAMESPACE" wait pod -l app=conjur-oss \
  --for=condition=ready --timeout=180s

###############################################################################
# 3. Retrieve *or* create the admin API key
###############################################################################
POD=$(kubectl -n "$NAMESPACE" get pod -l app=conjur-oss \
      -o jsonpath='{.items[0].metadata.name}')

set +e                                # allow a non-zero exit temporarily
ADMIN_KEY=$(kubectl -n "$NAMESPACE" exec "$POD" -c conjur-oss -- \
             conjurctl account create "$ACCOUNT" 2>/dev/null | \
             awk '/API key for admin:/ {print $NF}')
if [[ -z "$ADMIN_KEY" ]]; then        # account already exists → just fetch the key
  ADMIN_KEY=$(kubectl -n "$NAMESPACE" exec "$POD" -c conjur-oss -- \
               conjurctl role retrieve-key "$ACCOUNT":user:admin | tail -1)
fi
set -e                                # restore “exit on error”

echo "$ADMIN_KEY" | tee /tmp/conjur_admin.key

###############################################################################
# 4. One-liner env file for the demo repo
###############################################################################
cat > ~/.conjur_demo_env <<EOF
# ── Conjur connection ───────────────────────────
export CONJUR_OSS_HELM_INSTALLED=true
export CONJUR_ACCOUNT=${ACCOUNT}
export CONJUR_NAMESPACE_NAME=${NAMESPACE}
export CONJUR_ADMIN_PASSWORD=${ADMIN_KEY}
export AUTHENTICATOR_ID=${AUTHENTICATOR_ID}
export CONJUR_CLI_VERSION=8
export DOCKER_REGISTRY_PATH=
export HELM_RELEASE=${RELEASE}

# ── Demo repo defaults ──────────────────────────
export PULL_DOCKER_REGISTRY_URL=docker.io
export PULL_DOCKER_REGISTRY_PATH=docker.io/library
export DOCKER_REGISTRY_URL=docker.io
export USE_DOCKER_LOCAL_REGISTRY=true

EOF

# ── automatically load the env in the current shell if script is sourced ──
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && source ~/.conjur_demo_env


echo -e "\n🎉  Prereqs done.  Run:  source ~/.conjur_demo_env && ./start"

