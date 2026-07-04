# Use a slim Python 3.10 image to keep the container tiny
FROM python:3.10-slim

# Set the working directory
WORKDIR /app

# Install dependencies (FastAPI, Gradio, HTTP client, and Uvicorn server)
RUN pip install --no-cache-dir fastapi uvicorn pydantic httpx gradio requests

# Copy both application scripts into the container
COPY main.py .
COPY gradio_app.py .

# Expose both potential ports (8000 for FastAPI, 7860 for Gradio)
EXPOSE 8000 7860