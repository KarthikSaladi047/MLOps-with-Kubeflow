#!/usr/bin/env bash
# MLOps with Kubeflow — interactive infra installer.
# Walks through every section in Readme.md, collects the values it needs,
# previews them for approval, then installs the stack end-to-end.
#
# Usage:  ./install.sh
# Rerun-safe: helm/kubectl commands are idempotent where possible; failures halt the script.

set -euo pipefail

# ---------- pretty output ----------
if [[ -t 1 ]]; then
  C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

info()  { printf "${C_BLUE}[INFO]${C_RESET}  %s\n" "$*"; }
ok()    { printf "${C_GREEN}[ OK ]${C_RESET}  %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"; }
err()   { printf "${C_RED}[FAIL]${C_RESET}  %s\n" "$*" >&2; }
step()  { printf "\n${C_BOLD}${C_CYAN}=== %s ===${C_RESET}\n" "$*"; }

die() { err "$*"; exit 1; }

# ---------- prompt helpers ----------
ask() {
  # ask <var-name> <prompt> [default]
  local var="$1" prompt="$2" default="${3:-}"
  local val
  if [[ -n "$default" ]]; then
    read -rp "$(printf "${C_BOLD}?${C_RESET} %s [%s]: " "$prompt" "$default")" val
    val="${val:-$default}"
  else
    while :; do
      read -rp "$(printf "${C_BOLD}?${C_RESET} %s: " "$prompt")" val
      [[ -n "$val" ]] && break
      warn "Value cannot be empty."
    done
  fi
  printf -v "$var" '%s' "$val"
}

ask_secret() {
  # ask_secret <var-name> <prompt>   (reads twice, must match, no echo)
  local var="$1" prompt="$2" v1 v2
  while :; do
    read -srp "$(printf "${C_BOLD}?${C_RESET} %s: " "$prompt")" v1; echo
    [[ -z "$v1" ]] && { warn "Value cannot be empty."; continue; }
    read -srp "$(printf "${C_BOLD}?${C_RESET} %s (confirm): " "$prompt")" v2; echo
    [[ "$v1" == "$v2" ]] && break
    warn "Values did not match. Try again."
  done
  printf -v "$var" '%s' "$v1"
}

confirm() {
  # confirm <prompt>  -> returns 0/1
  local prompt="$1" reply
  read -rp "$(printf "${C_BOLD}?${C_RESET} %s [y/N]: " "$prompt")" reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

mask() { local s="$1"; local n=${#s}; ((n<=4)) && printf '****' || printf '%s****' "${s:0:2}"; }

# ---------- prerequisite checks ----------
step "Checking prerequisites"

for bin in kubectl helm kubeseal; do
  command -v "$bin" >/dev/null 2>&1 || die "Required command not found: $bin"
  ok "found $bin ($($bin version --client --short 2>/dev/null || $bin version --client 2>/dev/null | head -1 || echo present))"
done

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "kubectl cannot reach a cluster. Fix your kubeconfig and rerun."
fi
ok "kubectl talks to cluster: $(kubectl config current-context)"

# ---------- collect inputs ----------
step "Node assignment"

info "Provide comma-separated node names (as shown by 'kubectl get nodes')."
ask INFRA_NODES   "Infra   node name(s)"
ask APPS_NODES    "Apps    node name(s)"
ask COMPUTE_NODES "Compute node name(s)"

step "Storage & versions"

ask STORAGE_CLASS "StorageClass for MinIO + Postgres PVCs" "px-fa-direct-access"
ask PIPELINE_VERSION "Kubeflow Pipelines version" "2.16.1"
ask KNATIVE_VERSION  "Knative serving version"    "v1.22.1"
ask KSERVE_VERSION   "KServe version"             "v0.18.0"
ask CERT_MGR_VERSION "cert-manager version"       "v1.20.3"

step "MinIO credentials"

ask        MINIO_USER "MinIO root user (>= 3 chars)"
ask_secret MINIO_PASS "MinIO root password (>= 8 chars)"

step "PostgreSQL passwords (for MLflow backend)"

ask_secret PG_ADMIN_PASS "Postgres admin (postgres-password)"
ask_secret PG_USER_PASS  "Postgres mlflow_user password"
ask_secret PG_REPL_PASS  "Postgres replication password"

step "Kubeflow / GitOps credentials"

ask GIT_REPO_URL "Git repo URL that CT/CD workflows will clone" "https://github.com/KarthikSaladi047/MLOps-with-Kubeflow.git"
ask_secret GITHUB_TOKEN "GitHub PAT with 'repo' scope (used by CD workflow to push)"

# ---------- preview ----------
step "Preview — review before install"

cat <<EOF
${C_BOLD}Node labels/taints${C_RESET}
  infra   : ${INFRA_NODES}
  apps    : ${APPS_NODES}     (taint: dedicated=apps:NoSchedule)
  compute : ${COMPUTE_NODES}  (taint: dedicated=compute:NoSchedule)

${C_BOLD}Storage / versions${C_RESET}
  StorageClass       : ${STORAGE_CLASS}
  KFP version        : ${PIPELINE_VERSION}
  Knative version    : ${KNATIVE_VERSION}
  KServe version     : ${KSERVE_VERSION}
  cert-manager       : ${CERT_MGR_VERSION}

${C_BOLD}MinIO${C_RESET}
  root user     : ${MINIO_USER}
  root password : $(mask "$MINIO_PASS")

${C_BOLD}Postgres (namespace: mlflow)${C_RESET}
  admin password       : $(mask "$PG_ADMIN_PASS")
  mlflow_user password : $(mask "$PG_USER_PASS")
  replication password : $(mask "$PG_REPL_PASS")

${C_BOLD}GitOps${C_RESET}
  GIT_REPO_URL : ${GIT_REPO_URL}
  GITHUB_TOKEN : $(mask "$GITHUB_TOKEN")
EOF

confirm "Proceed with installation using the values above?" || die "Aborted by user."

# ---------- helpers used by install steps ----------
apply_sealed_from_stdin() {
  # apply_sealed_from_stdin <raw-file>
  # Reads raw YAML from stdin, seals it with kubeseal, applies it.
  # Writes raw file to disk first (in .gitignore) so it can be re-sealed later if needed.
  local raw_path="$1"
  local sealed_path="${raw_path/-raw.yaml/-sealed.yaml}"
  cat > "$raw_path"
  kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets \
    --format=yaml < "$raw_path" > "$sealed_path"
  kubectl apply -f "$sealed_path"
}

wait_for_deploy() {
  local ns="$1" name="$2"
  kubectl -n "$ns" rollout status "deploy/$name" --timeout=300s
}

label_taint_nodes() {
  local role="$1" taint="$2" nodes_csv="$3"
  IFS=',' read -ra arr <<< "$nodes_csv"
  for n in "${arr[@]}"; do
    n="$(echo "$n" | xargs)"  # trim
    [[ -z "$n" ]] && continue
    kubectl label  node "$n" "node-role.kubernetes.io/${role}=true" --overwrite
    [[ -n "$taint" ]] && kubectl taint node "$n" "$taint" --overwrite
  done
}

# ---------- STEP 1: label & taint ----------
step "1. Label & taint the nodes"
label_taint_nodes infra   ""                       "$INFRA_NODES"
label_taint_nodes apps    "dedicated=apps:NoSchedule"    "$APPS_NODES"
label_taint_nodes compute "dedicated=compute:NoSchedule" "$COMPUTE_NODES"
ok "Nodes labeled and tainted."

# ---------- STEP 2: sealed-secrets ----------
step "2. Install Sealed Secrets controller"
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
helm repo update sealed-secrets >/dev/null
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace sealed-secrets --create-namespace \
  --set-string nodeSelector."node-role\.kubernetes\.io/infra"=true
wait_for_deploy sealed-secrets sealed-secrets
ok "Sealed Secrets ready."

# Ensure kubeseal can reach the controller before we start piping raw secrets in.
if ! kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets \
      --fetch-cert >/dev/null 2>&1; then
  die "kubeseal cannot fetch the controller certificate. Check that the sealed-secrets pod is Ready."
fi

# ---------- STEP 3: MinIO ----------
step "3. Install MinIO"
kubectl apply -f minio/minio-ns.yaml

apply_sealed_from_stdin minio/minio-secret-raw.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
  namespace: minio
type: Opaque
stringData:
  rootUser: ${MINIO_USER}
  rootPassword: ${MINIO_PASS}
EOF

# Patch storage class into minio-values.yaml on-the-fly if needed.
MINIO_VALUES_FILE="minio/minio-values.yaml"
if ! grep -q "storageClass: \"${STORAGE_CLASS}\"" "$MINIO_VALUES_FILE"; then
  info "Rewriting storageClass in $MINIO_VALUES_FILE → ${STORAGE_CLASS}"
  sed -i.bak -E "s|storageClass: \".*\"|storageClass: \"${STORAGE_CLASS}\"|" "$MINIO_VALUES_FILE"
  rm -f "${MINIO_VALUES_FILE}.bak"
fi

helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo update minio >/dev/null
helm upgrade --install minio minio/minio -f "$MINIO_VALUES_FILE" --namespace minio
ok "MinIO installed."

# ---------- STEP 4: Postgres ----------
step "4. Install PostgreSQL (MLflow backend)"
kubectl apply -f mlflow/mlflow-ns.yaml

apply_sealed_from_stdin mlflow/postgres-secret-raw.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: mlflow
type: Opaque
stringData:
  postgres-password: ${PG_ADMIN_PASS}
  password: ${PG_USER_PASS}
  replication-password: ${PG_REPL_PASS}
  mlflow-uri: postgresql+psycopg2://mlflow_user:${PG_USER_PASS}@postgres-postgresql.mlflow.svc.cluster.local:5432/mlflow
EOF

PG_VALUES_FILE="mlflow/postgres-values.yaml"
if ! grep -q "storageClass: ${STORAGE_CLASS}" "$PG_VALUES_FILE"; then
  info "Rewriting storageClass in $PG_VALUES_FILE → ${STORAGE_CLASS}"
  sed -i.bak -E "s|storageClass: .*|storageClass: ${STORAGE_CLASS}|" "$PG_VALUES_FILE"
  rm -f "${PG_VALUES_FILE}.bak"
fi

helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update bitnami >/dev/null
helm upgrade --install postgres bitnami/postgresql \
  -f "$PG_VALUES_FILE" --namespace mlflow
ok "PostgreSQL installed."

# ---------- STEP 5: MLflow ----------
step "5. Install MLflow"
apply_sealed_from_stdin mlflow/minio-secret-raw.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
  namespace: mlflow
type: Opaque
stringData:
  rootUser: ${MINIO_USER}
  rootPassword: ${MINIO_PASS}
EOF

MLFLOW_SRC_DIR="$(mktemp -d)/mlflow"
git clone --depth 1 https://github.com/mlflow/mlflow.git "$MLFLOW_SRC_DIR"
helm upgrade --install mlflow "${MLFLOW_SRC_DIR}/charts" \
  --namespace mlflow -f mlflow/mlflow-values.yaml
ok "MLflow installed."

# ---------- STEP 6: Argo CD ----------
step "6. Install Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set server.service.type=NodePort
ok "Argo CD installed. Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# ---------- STEP 7: KServe (Knative + Istio + cert-manager + KServe) ----------
step "7a. Knative Serving"
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-crds.yaml"
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-core.yaml"

step "7b. Istio for Knative"
kubectl apply -f "https://github.com/knative-extensions/net-istio/releases/download/knative-${KNATIVE_VERSION}/istio.yaml"
kubectl apply -f "https://github.com/knative-extensions/net-istio/releases/download/knative-${KNATIVE_VERSION}/net-istio.yaml"

step "7c. cert-manager"
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version "$CERT_MGR_VERSION" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

step "7d. KServe"
helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
  --version "$KSERVE_VERSION" -n kserve --wait --create-namespace
helm upgrade --install kserve oci://ghcr.io/kserve/charts/kserve-resources \
  --version "$KSERVE_VERSION" -n kserve \
  --set kserve.controller.deploymentMode=Knative --wait --create-namespace
helm upgrade --install kserve-runtimes oci://ghcr.io/kserve/charts/kserve-runtime-configs \
  --version "$KSERVE_VERSION" -n kserve \
  --set kserve.servingruntime.enabled=true --wait

kubectl apply -f kserve/kserve-mlflow-runtime.yaml
kubectl patch cm config-features -n knative-serving \
  -p '{"data":{"kubernetes.podspec-nodeselector":"enabled","kubernetes.podspec-tolerations":"enabled","kubernetes.podspec-affinity":"enabled"}}'
ok "KServe stack ready."

step "7e. MinIO credentials for KServe (in default namespace)"
apply_sealed_from_stdin kserve/kserve-secret-raw.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kserve-minio-secret
  namespace: default
  annotations:
    serving.kserve.io/s3-endpoint: minio.minio.svc.cluster.local:9000
    serving.kserve.io/s3-region: us-east-1
    serving.kserve.io/s3-usehttps: "0"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: ${MINIO_USER}
  AWS_SECRET_ACCESS_KEY: ${MINIO_PASS}
EOF

# ---------- STEP 8: Argo Events ----------
step "8. Install Argo Events"
helm upgrade --install argo-events argo/argo-events \
  --set global.nodeSelector."node-role\.kubernetes\.io/infra"=true \
  -n argo-events --create-namespace
ok "Argo Events installed."

# ---------- STEP 9: Kubeflow Pipelines + infra creds ----------
step "9. Install Kubeflow Pipelines"
kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=${PIPELINE_VERSION}"
kubectl wait --for=condition=established --timeout=120s crd/applications.app.k8s.io
kubectl apply -k kubeflow-Pipelines/

step "9b. Infra credentials secret (kubeflow namespace)"
apply_sealed_from_stdin kubeflow-Pipelines/infra-creds-raw.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: infra-credentials
  namespace: kubeflow
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: ${MINIO_USER}
  AWS_SECRET_ACCESS_KEY: ${MINIO_PASS}
  AWS_DEFAULT_REGION: us-east-1
  AWS_ENDPOINT_URL: http://minio.minio.svc.cluster.local:9000
  MLFLOW_TRACKING_URI: http://mlflow.mlflow.svc.cluster.local:5000
  GIT_REPO_URL: ${GIT_REPO_URL}
  GITHUB_TOKEN: ${GITHUB_TOKEN}
EOF
ok "Kubeflow Pipelines + credentials in place."

# ---------- STEP 10: Argo CronWorkflows ----------
step "10. Deploy Argo CronWorkflows (CT + CD)"
kubectl apply -f argo-workflows/ct-cronworkflow.yaml
kubectl apply -f argo-workflows/cd-cronworkflow.yaml
ok "CronWorkflows deployed."

# ---------- done ----------
step "Done"
cat <<EOF
${C_GREEN}Installation complete.${C_RESET}

Quick verification:
  kubectl get pods -A | grep -E 'minio|mlflow|argocd|argo-events|kserve|knative|kubeflow|sealed-secrets|cert-manager'
  kubectl -n kubeflow get cronworkflow

Service endpoints (NodePorts):
  kubectl -n minio    get svc minio-console
  kubectl -n mlflow   get svc mlflow
  kubectl -n argocd   get svc argocd-server
  kubectl -n kubeflow get svc ml-pipeline-ui

${C_YELLOW}Reminder:${C_RESET} the *-raw.yaml files written by this script contain plaintext secrets.
They are covered by .gitignore, but do delete them (or move to a secure location)
once you have verified the sealed versions apply cleanly.
EOF
