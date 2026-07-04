import gradio as gr
import requests
import os

# The internal Kubernetes service name for our FastAPI backend
API_URL = os.getenv("API_URL", "http://api-gateway:8000/predict")

def classify_text(text):
    try:
        # Send the user's text to our FastAPI Gateway
        response = requests.post(API_URL, json={"text": text}, timeout=10)
        response.raise_for_status()
        
        data = response.json()
        sentiment = data.get("sentiment", "Unknown")
        confidence = data.get("confidence", 0.0)
        
        return f"Prediction: {sentiment}", f"Confidence: {confidence}%"
        
    except requests.exceptions.RequestException as e:
        return "Error connecting to backend API.", str(e)

# Build the Gradio Interface
with gr.Blocks(title="MLOps Text Classifier", theme=gr.themes.Soft()) as demo:
    gr.Markdown("# 🚀 Enterprise Text Classification")
    gr.Markdown("Type a sentence below to see the internal KServe model in action.")
    
    with gr.Row():
        with gr.Column():
            input_text = gr.Textbox(lines=4, placeholder="Enter text here...", label="Input Text")
            submit_btn = gr.Button("Classify", variant="primary")
        
        with gr.Column():
            output_label = gr.Label(label="Sentiment")
            output_conf = gr.Text(label="Confidence Score")
            
    submit_btn.click(
        fn=classify_text,
        inputs=input_text,
        outputs=[output_label, output_conf]
    )

if __name__ == "__main__":
    # Server name 0.0.0.0 is required for Docker/Kubernetes routing
    demo.launch(server_name="0.0.0.0", server_port=7860)