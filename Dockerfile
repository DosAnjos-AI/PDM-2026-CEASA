# Imagem do ciclo diario de ingestao das cotacoes da CEASA-GO.
#
# Parte da imagem do Google Cloud SDK porque o entrypoint precisa de dois
# binarios dela: gcloud (upload do CSV) e bq (execucao dos .sql). Instalar o
# SDK por cima de uma imagem python daria mais camada e mais superficie.
#
# Dependencias externas do pipeline, todas necessarias:
#   poppler-utils      -> pdftotext e pdftoppm, usados pelo extrator
#   tesseract-ocr      -> OCR dos PDFs sem camada de texto
#   tesseract-ocr-por  -> pacote de portugues do tesseract
#   python3-requests   -> scraper
#   python3-bs4        -> scraper
#
# As bibliotecas python vem do apt, nao do pip: a imagem base tem o ambiente
# python gerenciado externamente (PEP 668) e pip install falharia sem venv.

FROM google/cloud-sdk:slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-requests \
        python3-bs4 \
        poppler-utils \
        tesseract-ocr \
        tesseract-ocr-por \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
