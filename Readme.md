# MLOps with Kubeflow — Infra Setup

End-to-end infrastructure bootstrap for an on-prem MLOps stack on Kubernetes:
MinIO (object store) → PostgreSQL + MLflow (tracking / registry) → KServe (serving) →
Argo CD + Argo Events + Argo Workflows → Kubeflow Pipelines.

All Kubernetes `Secret`s are managed via **Bitnami Sealed Secrets** so this branch can be
GitOps-managed safely. Every command below assumes you have cloned the repo and are
sitting at its root:

```bash
git clone https://github.com/KarthikSaladi047/MLOps-with-Kubeflow.git
cd MLOps-with-Kubeflow
git checkout Infra-Setup
```

## Quick start — interactive installer

If you'd rather not run each command by hand, use the bundled installer.
It prompts for every required value, previews them for approval, then
executes every section below in order:

```bash
./install.sh
```

The manual steps that follow document exactly what the script does and remain
the source of truth if you want to install piecemeal or debug a failure.

---

## Prerequisites

Install these locally before starting:

- `kubectl` (>= 1.28)
- `helm` (>= 3.14)
- `kubeseal` CLI ([install guide](https://github.com/bitnami-labs/sealed-secrets/releases))
- A running Kubernetes cluster with **at least 3 node groups**:
  - `infra`   → runs platform software (MinIO, MLflow, Argo, KFP controllers, …)
  - `apps`    → runs UI / API / model consumers
  - `compute` → runs Kubeflow pipeline steps (training, data prep)
- A `StorageClass` that supports `ReadWriteOnce` (or better). This repo defaults to
  Portworx (`px-fa-direct-access`). If you use something else, edit the
  `storageClass` field in [minio/minio-values.yaml](minio/minio-values.yaml) and
  [mlflow/postgres-values.yaml](mlflow/postgres-values.yaml) before installing.

> **Important — sealed secrets are cluster-specific.**
> The `*-sealed.yaml` files checked into this branch were encrypted against the
> Sealed Secrets controller of the original cluster. A fresh cluster's controller
> will have a different key pair and **cannot decrypt them**. Each secret step
> below therefore starts by having you create a local `*-raw.yaml` (never
> committed — it's in `.gitignore`) and re-seal it with `kubeseal`.

---

## 1. Label & taint the nodes

Divide nodes into three groups: `infra`, `apps`, `compute`.

```bash
# infra runs all required platform software
kubectl label nodes <infra-node-name>   node-role.kubernetes.io/infra=true

# apps runs UI, API, model consumers
kubectl label nodes <app-node-name>     node-role.kubernetes.io/apps=true
kubectl taint  nodes <app-node-name>    dedicated=apps:NoSchedule

# compute runs Kubeflow pipelines
kubectl label nodes <compute-node-name> node-role.kubernetes.io/compute=true
kubectl taint  nodes <compute-node-name> dedicated=compute:NoSchedule
```

---

## 2. Install Sealed Secrets controller (on `infra` nodes)

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace sealed-secrets --create-namespace \
  --set-string nodeSelector."node-role\.kubernetes\.io/infra"=true
```

Wait for it to be ready:

```bash
kubectl -n sealed-secrets rollout status deploy/sealed-secrets
```

---

## 3. Install MinIO

Create the raw secret (**do not commit** — path is in `.gitignore`):

```bash
cat > minio/minio-secret-raw.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
  namespace: minio
type: Opaque
stringData:
  rootUser: <CHOOSE-A-USERNAME>
  rootPassword: <CHOOSE-A-STRONG-PASSWORD>
EOF
```

Create namespace, seal & apply the secret, then install MinIO:

```bash
kubectl apply -f minio/minio-ns.yaml

kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets \
  --format=yaml < minio/minio-secret-raw.yaml > minio/minio-secret-sealed.yaml
kubectl apply -f minio/minio-secret-sealed.yaml

helm repo add minio https://charts.min.io/
helm repo update minio
helm install minio minio/minio -f minio/minio-values.yaml --namespace minio
```

This provisions three buckets: `dvc-storage`, `mlflow-artifacts`, `kserve-models`.

---

## 4. Install PostgreSQL (backing store for MLflow)

Create the raw secret:

```bash
cat > mlflow/postgres-secret-raw.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: mlflow
type: Opaque
stringData:
  postgres-password: <CHOOSE-A-STRONG-ADMIN-PASSWORD>
  password: <CHOOSE-A-STRONG-USER-PASSWORD>
  replication-password: <CHOOSE-A-STRONG-REPL-PASSWORD>
  # mlflow-uri must match the user/password/db defined in mlflow/postgres-values.yaml
  # (user=mlflow_user, db=mlflow, service=postgres-postgresql)
  mlflow-uri: postgresql+psycopg2://mlflow_user:<SAME-USER-PASSWORD>@postgres-postgresql.mlflow.svc.cluster.local:5432/mlflow
EOF
```

Create namespace, seal & apply the secret, then install Postgres:

```bash
kubectl apply -f mlflow/mlflow-ns.yaml

kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets \
  --format=yaml < mlflow/postgres-secret-raw.yaml > mlflow/postgres-secret-sealed.yaml
kubectl apply -f mlflow/postgres-secret-sealed.yaml

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm install postgres bitnami/postgresql \
  -f mlflow/postgres-values.yaml \
  --namespace mlflow
```

---

## 5. Install MLflow

MLflow needs the MinIO credentials in its own namespace to write artifacts.
Create a raw secret pointing at the same MinIO user/password from step 3:

```bash
cat > mlflow/minio-secret-raw.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
  namespace: mlflow
type: Opaque
stringData:
  rootUser: <SAME-VALUE-AS-STEP-3>
  rootPassword: <SAME-VALUE-AS-STEP-3>
EOF
```

Seal & apply, then install MLflow from the upstream chart:

```bash
kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets \
  --format=yaml < mlflow/minio-secret-raw.yaml > mlflow/minio-secret-sealed.yaml
kubectl apply -f mlflow/minio-secret-sealed.yaml

git clone https://github.com/mlflow/mlflow.git /tmp/mlflow-src
helm install mlflow /tmp/mlflow-src/charts \
  --namespace mlflow \
  -f mlflow/mlflow-values.yaml
```

---

## 6. Install Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set server.service.type=NodePort

# Retrieve the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

---

## 7. Install KServe (serverless mode)

### 7a. Knative Serving

```bash
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.22.1/serving-crds.yaml
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.22.1/serving-core.yaml
```

### 7b. Istio (Knative network layer)

```bash
kubectl apply -f https://github.com/knative-extensions/net-istio/releases/download/knative-v1.22.1/istio.yaml
kubectl apply -f https://github.com/knative-extensions/net-istio/releases/download/knative-v1.22.1/net-istio.yaml
```

### 7c. cert-manager

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.20.3 \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

### 7d. KServe

```bash
helm install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
  --version v0.18.0 -n kserve --wait --create-namespace

helm install kserve oci://ghcr.io/kserve/charts/kserve-resources \
  --version v0.18.0 -n kserve \
  --set kserve.controller.deploymentMode=Knative --wait --create-namespace

helm install kserve-runtimes oci://ghcr.io/kserve/charts/kserve-runtime-configs \
  --version v0.18.0 -n kserve \
  --set kserve.servingruntime.enabled=true --wait

kubectl apply -f kserve/kserve-mlflow-runtime.yaml

kubectl patch cm config-features -n knative-serving -p \
  '{"data":{"kubernetes.podspec-nodeselector":"enabled","kubernetes.podspec-tolerations":"enabled","kubernetes.podspec-affinity":"enabled"}}'
```

### 7e. MinIO credentials for KServe (in the `default` namespace)

Create the raw secret that KServe will use to pull models from the
`kserve-models` bucket in MinIO:

```bash
cat > kserve/kserve-secret-raw.yaml <<'EOF'
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
  AWS_ACCESS_KEY_ID: <SAME-VALUE-AS-STEP-3>
  AWS_SECRET_ACCESS_KEY: <SAME-VALUE-AS-STEP-3>
EOF

kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets \
  --format=yaml < kserve/kserve-secret-raw.yaml > kserve/kserve-secret-sealed.yaml
kubectl apply -f kserve/kserve-secret-sealed.yaml
```

---

## 8. Install Argo Events

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argo-events argo/argo-events \
  --set global.nodeSelector."node-role\.kubernetes\.io/infra"=true \
  -n argo-events --create-namespace
```

---

## 9. Install Kubeflow Pipelines (KFP) + Katib + infra credentials

Install the cluster-scoped resources first, then the kustomization in this repo.

```bash
export PIPELINE_VERSION=2.16.1

kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=$PIPELINE_VERSION"
kubectl wait --for=condition=established --timeout=60s crd/applications.app.k8s.io

kubectl apply -k kubeflow-Pipelines/
```

```bash
kubectl apply -k "github.com/kubeflow/katib.git/manifests/v1beta1/installs/katib-standalone?ref=v0.17.0"
```

Now create the credentials that the Argo Workflows (step 10) and the training
pipeline components need. These live in the `kubeflow` namespace:

```bash
cat > kubeflow-Pipelines/infra-creds-raw.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: infra-credentials
  namespace: kubeflow
type: Opaque
stringData:
  # MinIO access (same values as step 3)
  AWS_ACCESS_KEY_ID: <MINIO-ROOT-USER>
  AWS_SECRET_ACCESS_KEY: <MINIO-ROOT-PASSWORD>
  AWS_DEFAULT_REGION: us-east-1
  AWS_ENDPOINT_URL: http://minio.minio.svc.cluster.local:9000
  # MLflow tracking (Service name is 'mlflow' in the 'mlflow' namespace by default)
  MLFLOW_TRACKING_URI: http://mlflow.mlflow.svc.cluster.local:5000
  # Git repo the CT/CD workflows pull from
  GIT_REPO_URL: https://github.com/<YOUR-GITHUB-USER>/MLOps-with-Kubeflow.git
  # PAT used by the CD workflow to push manifest updates back to the ArgoCD branch
  GITHUB_TOKEN: <YOUR-GITHUB-PAT>
EOF

kubeseal --controller-name=sealed-secrets --controller-namespace=sealed-secrets \
  --format=yaml < kubeflow-Pipelines/infra-creds-raw.yaml > kubeflow-Pipelines/infra-creds-sealed.yaml
kubectl apply -f kubeflow-Pipelines/infra-creds-sealed.yaml
```

---

## 10. Deploy the Argo CronWorkflows (CT + CD)

These run every 30 minutes: continuous training triggers a KFP run when new
commits arrive, and continuous delivery syncs the KServe manifest with the
MLflow model registry.

```bash
kubectl apply -f argo-workflows/ct-cronworkflow.yaml
kubectl apply -f argo-workflows/cd-cronworkflow.yaml
```

> `argo-workflows/cd-argo-sensor.yaml` is an **event-driven** alternative to the
> CD cron. It's kept for reference but **not applied by default** because the
> MLflow webhook requires HTTPS (see the note at the top of that file).

---

## Verifying the stack

```bash
kubectl get pods -A | grep -E 'minio|mlflow|argocd|argo-events|kserve|knative|kubeflow|sealed-secrets|cert-manager'
kubectl -n kubeflow get cronworkflow
```

Access the UIs via their NodePorts:

```bash
kubectl -n minio    get svc minio-console
kubectl -n mlflow   get svc mlflow
kubectl -n argocd   get svc argocd-server
kubectl -n kubeflow get svc ml-pipeline-ui
```

---

## Notes & gotchas

- **Storage class**: replace `px-fa-direct-access` in
  [minio/minio-values.yaml](minio/minio-values.yaml) and
  [mlflow/postgres-values.yaml](mlflow/postgres-values.yaml) if you're not on
  Portworx.
- **Namespace ordering**: sealed secrets must be applied *after* their
  target namespace exists. Follow the sections in order.
- **Sealed secrets in git are placeholders**: they were encrypted against the
  original cluster's controller. Always re-generate them on a fresh cluster,
  as described in each section.
- **Raw secrets**: `*-raw.yaml` files are ignored by git (see [.gitignore](.gitignore))
  and should never be committed.