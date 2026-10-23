# Imagem do Cloud Run Job clima-diario (ingestao/atualizar_clima.py).
# Build a partir desta pasta: gcloud run jobs deploy clima-diario --source ingestao/
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY atualizar_clima.py .

# saida sem buffer: cada linha de log chega ao Cloud Logging na hora
ENV PYTHONUNBUFFERED=1
CMD ["python", "atualizar_clima.py"]
