# MLOps with Kubeflow

End-to-end MLOps reference implementation on Kubernetes. Data lives in MinIO
(versioned with DVC), training runs on Kubeflow Pipelines, models are tracked
and registered in MLflow, served through KServe (Knative + Istio), and the
whole system is kept in sync with Argo CD + Argo Workflows. A small FastAPI +
Gradio UI sits in front of the inference endpoint.

This repository is split across four branches so each concern can evolve on its
own cadence — infra, training code, application code, and deployment state —
and be automated separately.

---

## Branch layout

| Branch          | Purpose                                                                                  | README                                      |
| --------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------- |
| **`main`**      | ML training pipeline source (`hf_pipeline.py`) + DVC pointer to the dataset. This file.  | *(you are here)*                            |
| **`Infra-Setup`** | Kubernetes manifests + Helm values + `install.sh` that stand up the whole platform.    | [see branch](../../tree/Infra-Setup#readme) |
| **`UI`**        | FastAPI gateway (`main.py`) + Gradio frontend (`gradio_app.py`) + Dockerfile + CI.       | [see branch](../../tree/UI#readme)          |
| **`ArgoCD`**    | GitOps state — deployment manifests that Argo CD reconciles onto the cluster.            | [see branch](../../tree/ArgoCD#readme)      |

Each branch has its own README covering what lives there and how to work on it.

---

## Architecture at a glance

The stack runs on a single Kubernetes cluster split into three node pools by
role: **`infra`** (platform services), **`apps`** (user-facing endpoints), and
**`compute`** (ephemeral training pods, tainted so nothing else lands on them).
Data is versioned in DVC-backed MinIO, models are tracked and registered in
MLflow, deployment state is reconciled from git by Argo CD, and Argo Workflows
runs the two automation loops that connect them.

### Cluster topology

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                        K U B E R N E T E S   C L U S T E R                    ║
╚═══════════════════════════════════════════════════════════════════════════════╝

┌── infra pool ────────────────────────────────────────────────────────────────┐
│  platform services  ·  nodeSelector = infra                                  │
│                                                                              │
│   ╭─────────────╮   ╭─────────────╮   ╭─────────────╮   ╭─────────────╮      │
│   │    MinIO    │   │   MLflow    │   │  Argo CD    │   │  Argo Wf +  │      │
│   │  (S3 API)   │◀──│ tracking +  │   │             │   │ Argo Events │      │
│   │             │   │  registry   │   │ reconciles  │   │             │      │
│   │ dvc-storage │   │             │   │  ArgoCD br  │   │  CT + CD    │      │
│   │ mlflow-art. │   ╰──────┬──────╯   │             │   │  crons      │      │
│   │ kserve-mod. │          │          ╰─────────────╯   ╰─────────────╯      │
│   ╰─────────────╯          │  backend                                        │
│                            ▼                                                 │
│   ╭─────────────╮   ╭─────────────╮   ╭─────────────╮   ╭─────────────╮      │
│   │   Sealed    │   │  Postgres   │   │  Kubeflow   │   │  Knative +  │      │
│   │   Secrets   │   │  (mlflow    │   │  Pipelines  │   │  Istio +    │      │
│   │             │   │   backend)  │   │             │   │ cert-manager│      │
│   ╰─────────────╯   ╰─────────────╯   ╰─────────────╯   ╰─────────────╯      │
└──────────────────────────────────────────────────────────────────────────────┘

┌── apps pool ─────────────────────────────────────────────────────────────────┐
│  user-facing  ·  nodeSelector = apps  ·  taint dedicated=apps:NoSchedule     │
│                                                                              │
│       user (browser)                                                         │
│            │                                                                 │
│            │ HTTP                                                            │
│            ▼                                                                 │
│      ╭─────────────╮      ╭──────────────╮      ╭──────────────╮             │
│      │  gradio-ui  │─────▶│ api-gateway  │─────▶│    KServe    │             │
│      │  (Gradio)   │ HTTP │  (FastAPI)   │  V2  │  Inference   │             │
│      ╰─────────────╯      ╰──────────────╯      │   Service    │             │
│                                                 │ ┌──────────┐ │             │
│                                                 │ │ prod 90% │ │             │
│                                                 │ ├──────────┤ │             │
│                                                 │ │canary 10%│ │             │
│                                                 │ └──────────┘ │             │
│                                                 ╰──────────────╯             │
└──────────────────────────────────────────────────────────────────────────────┘

┌── compute pool ──────────────────────────────────────────────────────────────┐
│  ephemeral KFP training pods  ·  taint dedicated=compute:NoSchedule          │
│                                                                              │
│         ╭──────────────╮                    ╭──────────────────────╮         │
│         │  prep_data   │─── artifact ──────▶│  train_and_register  │         │
│         │  (DVC pull   │                    │  (HF fine-tune +     │         │
│         │  from MinIO) │                    │   log to MLflow)     │         │
│         ╰──────────────╯                    ╰──────────────────────╯         │
│                                                                              │
│         spawned by Kubeflow Pipelines on schedule; deleted after each run    │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Continuous Training loop  (CT — every 30 min)

A commit to `main` eventually becomes a new registered model version in MLflow.

```
      developer
          │  git push (main)
          ▼
     ╭──────────╮     clone every 30 min     ╭──────────────╮
     │  GitHub  │◀────────────────────────── │   CT Cron    │
     │   main   │                            │  (Argo Wf)   │
     ╰──────────╯                            ╰──────┬───────╯
                                                    │ compile + submit
                                                    ▼
                                            ╭──────────────╮
                                            │   Kubeflow   │
                                            │   Pipelines  │
                                            ╰──────┬───────╯
                                                   │
                    ┌──────────────────────────────┴─────────────────────────┐
                    ▼                                                        ▼
           ╭─────────────────╮                                    ╭─────────────────────╮
           │    prep_data    │──── DVC pull ─────────────────────▶│        MinIO        │
           │  (compute pod)  │◀── dataset.csv ────────────────────│    (dvc-storage)    │
           ╰────────┬────────╯                                    ╰─────────────────────╯
                    │  KFP artifact
                    ▼
           ╭────────────────────╮      register model    ╭─────────────────────╮
           │ train_and_register │───────────────────────▶│       MLflow        │
           │  (compute pod, HF) │      + artifact        │  registry + MinIO   │
           ╰────────────────────╯───────────────────────▶╰─────────────────────╯
```

### Continuous Delivery loop  (CD — every 30 min)

A promotion in the MLflow registry eventually becomes a rolled-out
`InferenceService`.

```
   ╭─────────────╮                            ╭──────────────╮ 
   │   MLflow    │◀── poll every 30 min ───── │   CD Cron    │  git commit + push ╭──────────────╮
   │   registry  │                            │  (Argo Wf)   │───────────────────▶│    GitHub    │
   │             │── latest prod + canary ───▶│              │                    │  ArgoCD br.  │
   ╰─────────────╯                            ╰──────────────╯                    │ Kserve/*.yaml│
                                                                                  ╰──────┬───────╯
                                                                         Argo CD watches │  
                                                                                         ▼
                                                                                 ╭──────────────╮
                                                                                 │   Argo CD    │
                                                                                 │  reconciles  │
                                                                                 ╰───-──┬-──────╯
                                                                                applies │  
                                                                                        ▼
                                                                                 ╭──────────────╮
                                                                                 │    KServe    │
                                                                                 │  Inference   │
                                                                                 │   Service    │
                                                                                 │ (new storage │
                                                                                 │     URI)     │
                                                                                 ╰──────────────╯
```

### Inference request path

A click in the browser eventually becomes a scored sentiment.

```
                                                                             ╭──────────────╮
                                                                             │    KServe    │
   ╭─────────╮   HTTP    ╭─────────────╮   HTTP    ╭──────────────╮  V2 inf  │  Inference   │
   │  user   │──────────▶│  gradio-ui  │──────────▶│ api-gateway  │─────────▶│   Service    │
   │(browser)│◀──────────│  (Gradio)   │◀──────────│  (FastAPI)   │◀─────────│              │
   ╰─────────╯  sentiment╰─────────────╯  scores   ╰──────────────╯          ╰──────┬───────╯
                                                                                    │  pull artifact
                                                                                    │  (first request)
                                                                                    ▼
                                                                             ╭──────────────╮
                                                                             │    MinIO     │
                                                                             │  (mlflow-    │
                                                                             │  artifacts)  │
                                                                             ╰──────────────╯
```

## End-to-end flow

1. **Data lands in MinIO.** `dataset.csv` is tracked by DVC (`dataset.csv.dvc`)
   and stored under the `dvc-storage` bucket configured in [.dvc/config](.dvc/config).
2. **Continuous Training (CT).** Argo `CronWorkflow` (on the `Infra-Setup` branch)
   clones this `main` branch every 30 min, runs [hf_pipeline.py](hf_pipeline.py)
   which compiles `hf_pipeline.yaml`, then submits it to Kubeflow Pipelines. The
   pipeline pulls the DVC-tracked dataset, fine-tunes `prajjwal1/bert-tiny`, and
   registers the artifact under the model name `enterprise-text-classifier` in
   MLflow.
3. **Continuous Delivery (CD).** A second Argo `CronWorkflow` polls MLflow for
   the latest `enterprise-text-classifier-production` / `-canary` versions,
   rewrites `Kserve/kserve-inference.yaml` on the `ArgoCD` branch with the new
   `storageUri`, and pushes.
4. **GitOps.** Argo CD watches the `ArgoCD` branch and reconciles the
   `InferenceService` + UI deployments onto the cluster.
5. **Serving.** KServe (Knative + Istio + MLflow runtime) exposes the model.
   FastAPI (`main.py` on the `UI` branch) proxies user requests to KServe;
   Gradio provides the human-facing frontend.

---

## Getting started

Fresh cluster, no infra yet:

```bash
git clone https://github.com/KarthikSaladi047/MLOps-with-Kubeflow.git
cd MLOps-with-Kubeflow

# 1. Bootstrap the platform from the Infra-Setup branch
git checkout Infra-Setup
./install.sh

# 2. Register the Argo CD Applications so it starts reconciling the ArgoCD branch
git checkout main
kubectl apply -f argo-apps/argo-kserve-app.yaml
kubectl apply -f argo-apps/argo-ui-app.yaml
```

The installer prompts for node names, credentials, and versions, previews them
for approval, then bootstraps MinIO → PostgreSQL → MLflow → Argo CD → KServe →
Argo Events → Kubeflow Pipelines → CT/CD CronWorkflows. See the
[Infra-Setup README](../../tree/Infra-Setup#readme) for what happens under the hood.

Step 2 hands Argo CD two `Application` objects — one pointing at
`ArgoCD/Kserve/` (the InferenceService) and one at `ArgoCD/UI/` (the FastAPI +
Gradio Deployments). If you're not using the upstream `KarthikSaladi047` repo,
edit `repoURL` in both files first to point at your fork.

Once infra is up and the Applications are registered, the CT/CD workflows pick
up commits to `main` and `ArgoCD` automatically — you don't need to run
anything on this branch by hand.

---

## What's on this (`main`) branch

| Path                | What it does                                                                 |
| ------------------- | ---------------------------------------------------------------------------- |
| [hf_pipeline.py](hf_pipeline.py)      | KFP pipeline: two components (`prep_data`, `train_and_register`) wired together and compiled to `hf_pipeline.yaml`. |
| [dataset.csv.dvc](dataset.csv.dvc)    | DVC pointer file. Actual `dataset.csv` lives in MinIO (bucket `dvc-storage`). |
| [.dvc/config](.dvc/config)            | DVC configured with the in-cluster MinIO endpoint (`http://minio.minio.svc.cluster.local:9000`). |
| [.dvcignore](.dvcignore)              | DVC ignore rules.                                                             |
| [argo-apps/](argo-apps/)              | Argo CD `Application` manifests — one for the KServe `InferenceService`, one for the UI Deployments. Applied once after `Infra-Setup` finishes; they register the `ArgoCD` branch's `Kserve/` and `UI/` folders with Argo CD so it can reconcile them onto the cluster. |

### Working on the training pipeline locally

The CT CronWorkflow re-runs the pipeline for you, but for local iteration:

```bash
# Prereqs: python3.10+, kfp, kfp-kubernetes
pip install "kfp==2.*" kfp-kubernetes

# Compile hf_pipeline.py -> hf_pipeline.yaml
python3 hf_pipeline.py

# Submit to your cluster (needs kubectl port-forward or in-cluster access
# to the KFP API at http://ml-pipeline.kubeflow.svc.cluster.local:8888)
```

### Updating the dataset

```bash
# Fetch the current dataset locally
dvc pull

# Edit dataset.csv, then version + push
dvc add dataset.csv
git add dataset.csv.dvc
git commit -m "data: refresh training set"
git push origin main
dvc push
```

The next CT run will train on the new data.

---

## Repository conventions

- **Never commit secrets.** Sealed Secrets is used everywhere on `Infra-Setup`;
  see that branch's README for the flow.
- **Never edit `Kserve/kserve-inference.yaml` or `UI/k8s-ui-backend.yaml` by
  hand.** Both are rewritten by automation — the CD CronWorkflow updates the
  KServe manifest from MLflow, and the UI branch's GitHub Action bumps the UI
  image tag. Manual edits get overwritten.
- **Branch-per-concern.** Land changes on the branch that owns that concern
  (`main` → training code + data, `UI` → app code, `Infra-Setup` → platform
  manifests, `ArgoCD` → generated deployment state).
