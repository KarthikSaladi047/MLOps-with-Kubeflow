import kfp
from kfp import dsl
from kfp import compiler

# ==========================================
# Component 1: Data Preparation (via DVC)
# ==========================================
@dsl.component(
    base_image="python:3.10",
    packages_to_install=["pandas", "dvc[s3]"]
)
def prep_data(dataset: dsl.Output[dsl.Dataset]):
    import os
    import subprocess
    import pandas as pd
    
    # 1. Grab EVERYTHING from injected Kubernetes secrets
    endpoint = os.environ.get("MLFLOW_S3_ENDPOINT_URL")
    key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret = os.environ.get("AWS_SECRET_ACCESS_KEY")
    git_repo_url = os.environ.get("GIT_REPO_URL")
    
    if not git_repo_url:
        raise ValueError("GIT_REPO_URL is missing from the environment variables!")
    
    # 2. Clone the Git repository containing the .dvc pointer
    print(f"Cloning Git repository: {git_repo_url}...")
    subprocess.run(["git", "clone", git_repo_url, "/tmp/repo"], check=True)
    os.chdir("/tmp/repo")
    
    # 3. Configure DVC to use the injected credentials dynamically
    print("Configuring DVC credentials...")
    subprocess.run(["dvc", "remote", "modify", "--local", "minio-remote", "endpointurl", endpoint], check=True)
    subprocess.run(["dvc", "remote", "modify", "--local", "minio-remote", "access_key_id", key], check=True)
    subprocess.run(["dvc", "remote", "modify", "--local", "minio-remote", "secret_access_key", secret], check=True)
    
    # 4. Pull the heavy CSV file from MinIO using the .dvc pointer
    print("Pulling data from MinIO via DVC...")
    subprocess.run(["dvc", "pull"], check=True)
    
    # 5. Read the downloaded CSV and pass it to KFP artifacts
    df = pd.read_csv("dataset.csv")
    print(f"Successfully loaded {len(df)} rows from DVC.")
    
    df.to_csv(dataset.path, index=False)
    print("Data prepped and saved to KFP artifact storage.")

# ==========================================
# Component 2: Training & Model Registry
# ==========================================
@dsl.component(
    base_image="python:3.10-slim",
    packages_to_install=[
        "mlflow==2.10.2", 
        "boto3", 
        "transformers==4.37.1", 
        "torch==2.12.1", 
        "torchvision==0.27.1",
        "pandas"
    ]
)
def train_and_register(dataset: dsl.Input[dsl.Dataset]):
    import os
    import pandas as pd
    import torch
    import mlflow
    from transformers import AutoTokenizer, AutoModelForSequenceClassification
    
    print("Loading credentials from Kubernetes Secrets...")
    os.environ["MLFLOW_TRACKING_URI"] = os.environ.get("MLFLOW_TRACKING_URI", "")
    os.environ["MLFLOW_S3_ENDPOINT_URL"] = os.environ.get("MLFLOW_S3_ENDPOINT_URL", "")
    os.environ["AWS_ACCESS_KEY_ID"] = os.environ.get("AWS_ACCESS_KEY_ID", "")
    os.environ["AWS_SECRET_ACCESS_KEY"] = os.environ.get("AWS_SECRET_ACCESS_KEY", "")

    print("Loading dataset from previous step...")
    df = pd.read_csv(dataset.path)
    
    model_name = "prajjwal1/bert-tiny" 
    print(f"Downloading {model_name}...")
    
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    model = AutoModelForSequenceClassification.from_pretrained(model_name, num_labels=2)
    
    print("Running micro-training loop on CPU...")
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-4)
    model.train()
    
    inputs = tokenizer(df['text'].tolist(), padding=True, truncation=True, return_tensors="pt")
    labels = torch.tensor(df['label'].tolist())
    
    optimizer.zero_grad()
    outputs = model(**inputs, labels=labels)
    loss = outputs.loss
    loss.backward()
    optimizer.step()
    print(f"Training complete. Final Loss: {loss.item()}")

    mlflow.set_experiment("huggingface-text-classification")
    
    with mlflow.start_run():
        components = {
            "model": model,
            "tokenizer": tokenizer,
        }
        
        print("Logging and Registering model to MLflow...")
        mlflow.transformers.log_model(
            transformers_model=components,
            artifact_path="model",
            task="text-classification", 
            registered_model_name="cpu-tiny-classifier" 
        )
        print("Success! Model is now in the Registry.")

# ==========================================
# Pipeline Definition
# ==========================================
@dsl.pipeline(
    name="enterprise-mlops-pipeline",
    description="Pulls a dataset via DVC/Git, trains, and registers a model."
)
def mlops_pipeline():
    from kfp import kubernetes
    
    # Secret Mapping Dictionary
    secret_mapping = {
        "mlflow_tracking_uri": "MLFLOW_TRACKING_URI",
        "mlflow_s3_endpoint_url": "MLFLOW_S3_ENDPOINT_URL", 
        "aws_access_key_id": "AWS_ACCESS_KEY_ID",
        "aws_secret_access_key": "AWS_SECRET_ACCESS_KEY",
        "git_repo_url": "GIT_REPO_URL"  # <--- INJECTING THE GIT URL HERE
    }

    # Step 1: Prep the data
    data_task = prep_data()
    kubernetes.use_secret_as_env(
        data_task,
        secret_name="prod-infra-credentials",
        secret_key_to_env=secret_mapping
    )
    
    # Step 2: Train the model
    train_task = train_and_register(dataset=data_task.outputs["dataset"])
    kubernetes.use_secret_as_env(
        train_task,
        secret_name="prod-infra-credentials",
        secret_key_to_env=secret_mapping
    )
    
    train_task.set_caching_options(False)

if __name__ == "__main__":
    compiler.Compiler().compile(
        pipeline_func=mlops_pipeline,
        package_path="hf_pipeline_v2.yaml"
    )