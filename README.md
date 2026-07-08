# ArgoCD — GitOps deployment state

This branch is **not edited by humans in normal operation.** It holds the
runtime state of the cluster as YAML — the KServe `InferenceService` that
serves the model, and the FastAPI + Gradio `Deployment`/`Service` manifests.

Two automated processes keep it in sync:

- The **CD `CronWorkflow`** (defined on the `Infra-Setup` branch,
  `argo-workflows/cd-cronworkflow.yaml`) polls MLflow every 30 min for the
  latest `enterprise-text-classifier-production` and `-canary` model versions,
  rewrites `storageUri` (and canary weight) in `Kserve/kserve-inference.yaml`,
  and pushes back here.
- The **UI branch's GitHub Action** (`.github/workflows/build-and-deploy.yaml`
  on the `UI` branch) rebuilds the container image on every push, updates the
  `image:` tag inside `UI/k8s-ui-backend.yaml`, and pushes back here.

**Argo CD** (installed by `Infra-Setup`) reconciles this branch onto the
cluster. When something lands here, it rolls out shortly after.

For the wider project, see the [`main` branch README](../../tree/main#readme).
For the automation that writes to this branch, see
[`Infra-Setup`](../../tree/Infra-Setup#readme) and
[`UI`](../../tree/UI#readme).

---

## What's on this branch

| Path                                                     | Written by                                | Purpose                                                                 |
| -------------------------------------------------------- | ----------------------------------------- | ----------------------------------------------------------------------- |
| [Kserve/kserve-inference.yaml](Kserve/kserve-inference.yaml) | CD CronWorkflow (`Infra-Setup` branch)    | KServe `InferenceService` with production + canary blocks; `storageUri` points at MLflow-registered artifact paths in the `mlflow-artifacts` MinIO bucket. |
| [Kserve/kserve-sa.yaml](Kserve/kserve-sa.yaml)               | Human, one-time                           | Service account `kserve-sa` that references `kserve-minio-secret` so KServe can pull models from MinIO. |
| [UI/k8s-ui-backend.yaml](UI/k8s-ui-backend.yaml)             | UI-branch CI (`build-and-deploy.yaml`)    | `api-gateway` (FastAPI) + `gradio-ui` (Gradio) Deployments and Services, running on the `apps` node pool. |

---

## How Argo CD picks these up

Two Argo CD `Application` manifests point at this branch. They live on the
`main` branch under `argo-apps/`:

- `argo-apps/argo-kserve-app.yaml` → `targetRevision: ArgoCD`, `path: Kserve`
- `argo-apps/argo-ui-app.yaml`     → `targetRevision: ArgoCD`, `path: UI`

Both use `syncPolicy.automated` with `prune: true` and `selfHeal: true`, so
Argo CD reconciles this branch onto the cluster as soon as commits land.

After `Infra-Setup` finishes, apply them once:

```bash
git checkout main
kubectl apply -f argo-apps/argo-kserve-app.yaml
kubectl apply -f argo-apps/argo-ui-app.yaml
```

See the [`main` branch README](../../tree/main#readme) for the full bootstrap
sequence.

---

## Why you should not hand-edit these files

Both `kserve-inference.yaml` and `k8s-ui-backend.yaml` are **overwritten**
on every automation run:

- Editing `Kserve/kserve-inference.yaml` by hand will be undone the next time
  the CD CronWorkflow syncs from MLflow. If you need a different model, promote
  it in the MLflow registry — the workflow will pick it up.
- Editing `UI/k8s-ui-backend.yaml` by hand will be undone the next time you
  push to the `UI` branch. To change the image, push new code to `UI`; CI does
  the rest.

Legit reasons to touch this branch manually:

- Adjusting resource requests/limits, replica counts, or `nodeSelector` in
  either file (the automation only rewrites specific fields — `storageUri` /
  `image:` — everything else is preserved).
- Adding a new `Kserve/kserve-sa.yaml`-style manifest that isn't machine-managed.

If you do edit by hand, land the change quickly before the next automation
cycle so you don't get a merge conflict.

---

## Debugging a stuck rollout

```bash
# Is Argo CD in sync?
kubectl -n argocd get applications

# Force a resync
argocd app sync <app-name>

# Look at the InferenceService KServe rendered
kubectl -n default get isvc huggingface-classifier -o yaml

# Look at the underlying Knative Revisions (canary vs prod)
kubectl -n default get revisions.serving.knative.dev
```

If `kserve-inference.yaml` shows a `storageUri` that MinIO can't serve, check
the CD CronWorkflow logs on the cluster:

```bash
kubectl -n kubeflow get cronworkflow continuous-delivery-job
kubectl -n kubeflow logs -l workflows.argoproj.io/cronworkflow=continuous-delivery-job --tail=200
```
