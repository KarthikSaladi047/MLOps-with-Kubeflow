from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
import httpx
import os

# 1. Initialize the FastAPI application
app = FastAPI(
    title="MLOps API Gateway",
    description="Middleware connecting frontend clients to the KServe ML backend."
)

# KServe internal cluster URL (using the exact one from your earlier curl command)
KSERVE_URL = os.getenv(
    "KSERVE_URL", 
    "http://huggingface-classifier.default.svc.cluster.local/v2/models/huggingface-classifier/infer"
)

# 2. Pydantic Models for strict input/output validation
class InferenceRequest(BaseModel):
    text: str = Field(..., min_length=2, max_length=1000, description="The text to classify.")

class InferenceResponse(BaseModel):
    sentiment: str
    confidence: float
    raw_label: str

# 3. The primary prediction route
@app.post("/predict", response_model=InferenceResponse)
async def predict(request: InferenceRequest):
    # A. Format the payload into the strict V2 Inference Protocol that KServe expects
    kserve_payload = {
        "inputs": [
            {
                "name": "text",
                "shape": [1],
                "datatype": "BYTES",
                "data": [request.text]
            }
        ]
    }

    # B. Send the request to KServe asynchronously 
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                KSERVE_URL, 
                json=kserve_payload, 
                headers={"Content-Type": "application/json"},
                timeout=10.0
            )
            response.raise_for_status()
    except httpx.RequestError as e:
        raise HTTPException(status_code=503, detail=f"Failed to connect to ML backend: {str(e)}")
    
    # C. Parse the ugly KServe JSON response
    kserve_data = response.json()
    outputs = kserve_data.get("outputs", [])
    
    if not outputs:
        raise HTTPException(status_code=500, detail="Invalid response from ML backend.")

    # Extract the raw label (LABEL_0 or LABEL_1) and the score
    raw_label = outputs[0]["data"][0]
    score = outputs[1]["data"][0]

    # D. Business Logic: Translate the raw label into human-readable text
    sentiment = "Negative" if raw_label == "LABEL_0" else "Positive" if raw_label == "LABEL_1" else "Neutral"

    # E. Return a clean, user-friendly JSON response
    return InferenceResponse(
        sentiment=sentiment,
        confidence=round(score * 100, 2), # Convert to percentage (e.g., 98.45)
        raw_label=raw_label
    )

# Health check route for Kubernetes liveness probes
@app.get("/health")
def health_check():
    return {"status": "healthy"}