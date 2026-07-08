# UI — FastAPI gateway + Gradio frontend

This branch holds the **application code** for the human-facing side of the
MLOps stack: a FastAPI service that translates friendly HTTP requests into
KServe's V2 inference protocol, and a Gradio app that gives users a text-box
to talk to it.

For the wider project, see the [`main` branch README](../../tree/main#readme).
For the platform this deploys onto, see [`Infra-Setup`](../../tree/Infra-Setup#readme).
The deployment manifests live on the [`ArgoCD` branch](../../tree/ArgoCD#readme)
and are updated by this branch's CI — you should not check them out to run the
app locally.

---

## What's on this branch

| Path                                         | What it does                                                                    |
| -------------------------------------------- | ------------------------------------------------------------------------------- |
| [main.py](main.py)                           | FastAPI API gateway. `POST /predict` accepts `{text}`, forwards a V2 inference payload to KServe, returns `{sentiment, confidence, raw_label}`. |
| [gradio_app.py](gradio_app.py)               | Gradio UI that calls the FastAPI gateway on `http://api-gateway:8000/predict`. |
| [Dockerfile](Dockerfile)                     | Single image containing both processes. The container `command:` in the Deployment picks which one to launch. |
| [.github/workflows/build-and-deploy.yaml](.github/workflows/build-and-deploy.yaml) | On every push to `UI`: build the image, push to GHCR tagged with the short SHA, then check out `ArgoCD`, rewrite the `image:` line in `UI/k8s-ui-backend.yaml`, and push back. Argo CD reconciles the change onto the cluster. |

---

## How the pieces connect

```
   browser ──HTTP──► gradio-ui (7860)  ──HTTP──► api-gateway (8000, FastAPI)
                                                   │
                                                   │  V2 inference protocol
                                                   ▼
                             KServe: huggingface-classifier.default.svc.cluster.local
                                (backed by MLflow model in MinIO)
```

Both `gradio-ui` and `api-gateway` are `Deployment`s in the `default` namespace
on the `apps` node pool — see `UI/k8s-ui-backend.yaml` on the `ArgoCD` branch.

- `KSERVE_URL` (env var on `api-gateway`) points at the internal KServe
  service. Default value is baked into [main.py](main.py); override via env if
  the InferenceService name/namespace changes.
- `API_URL` (env var on `gradio-ui`) points at the FastAPI service. Default:
  `http://api-gateway:8000/predict`.

---

## Local development

You can iterate on either process without a cluster — you just won't get real
predictions unless you point `KSERVE_URL` somewhere that answers.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install fastapi uvicorn pydantic httpx gradio requests

# Terminal 1: FastAPI gateway
export KSERVE_URL="http://localhost:9999/mock"   # or a real KServe endpoint via port-forward
uvicorn main:app --host 0.0.0.0 --port 8000 --reload

# Terminal 2: Gradio UI (talks to the FastAPI process above)
export API_URL="http://localhost:8000/predict"
python3 gradio_app.py     # serves on http://localhost:7860
```

Port-forward a real KServe endpoint if you want end-to-end:

```bash
kubectl -n default port-forward svc/huggingface-classifier-predictor 9999:80
export KSERVE_URL="http://localhost:9999/v2/models/huggingface-classifier/infer"
```

---

## Building the image manually

CI does this on every push, but you can build locally too:

```bash
docker build -t mlops-ui:local .

# FastAPI
docker run --rm -p 8000:8000 mlops-ui:local \
  uvicorn main:app --host 0.0.0.0 --port 8000

# Gradio
docker run --rm -p 7860:7860 -e API_URL="http://host.docker.internal:8000/predict" \
  mlops-ui:local python3 gradio_app.py
```

---

## CI flow (`.github/workflows/build-and-deploy.yaml`)

Triggered on every push to `UI`:

1. Log in to GHCR using `GITHUB_TOKEN`.
2. Compute the short SHA and lowercase the repo name (GHCR requires lowercase).
3. `docker build` this Dockerfile and push to
   `ghcr.io/<owner>/mlops-with-kubeflow/mlops-ui:<sha>`.
4. Check out the `ArgoCD` branch into a sub-path, `sed` the new image tag into
   `UI/k8s-ui-backend.yaml`, commit as `github-actions[bot]`, push back.
5. Argo CD (running on the cluster, installed from `Infra-Setup`) sees the
   commit and rolls out the new image.

You don't need to touch anything on `ArgoCD` — every merge to `UI` produces a
new image + a corresponding manifest commit automatically.

---

## Things to watch out for

- **Don't rename the FastAPI Service.** `gradio_app.py`'s default `API_URL`
  and the Deployment's env var both assume it's called `api-gateway` in the
  `default` namespace. Change one, change both.
- **Don't rename the InferenceService.** `main.py`'s default `KSERVE_URL`
  assumes `huggingface-classifier.default`. If you rename the model in the
  training pipeline (`registered_model_name` in `hf_pipeline.py` on `main`),
  the InferenceService name follows and you'll need to update `KSERVE_URL`.
- **Sentiment mapping is hard-coded.** `main.py` maps `LABEL_0 → Negative`,
  `LABEL_1 → Positive`. If you retrain with a different label schema, update
  the translation.
