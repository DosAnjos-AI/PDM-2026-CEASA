FROM python:3.13-slim

# libgomp1: paralelismo (OpenMP) exigido pelo LightGBM
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# PyTorch só para CPU (a versão padrão do PyPI traz CUDA e deixa a imagem ~4 GB maior)
RUN pip install --no-cache-dir torch==2.14.1 --index-url https://download.pytorch.org/whl/cpu
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pesos dos modelos Chronos listados no treino.yaml, baixados no build: a execução não
# depende do Hugging Face e sempre usa os mesmos pesos da imagem.
ENV HF_HOME=/app/hf
COPY config/ config/
RUN python -c "import yaml; from huggingface_hub import snapshot_download; \
    cfg = yaml.safe_load(open('config/treino.yaml', encoding='utf-8')); \
    [snapshot_download(m['repo']) for m in cfg['modelos'].values() if m.get('tipo') == 'chronos']"
ENV HF_HUB_OFFLINE=1 \
    HF_HUB_DISABLE_PROGRESS_BARS=1 \
    TRANSFORMERS_VERBOSITY=error

COPY pipeline/ pipeline/

ENV PYTHONUNBUFFERED=1
# O comando padrão é o treino; outros módulos rodam trocando os args da execução, ex.:
#   gcloud run jobs execute treino-precos --args=pipeline.rollback,--versao,naive
ENTRYPOINT ["python", "-m"]
CMD ["pipeline.treinar"]
