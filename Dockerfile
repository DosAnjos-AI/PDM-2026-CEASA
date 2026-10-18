# Imagem do ciclo de ingestao das cotacoes da CEASA-GO e das outras sedes
# (MS, SC, MG e ES).
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
#   python3-xlrd       -> planilhas .xls da CEASA-MS
#   python3-openpyxl   -> planilhas .xlsx da CEASA-MS
#   python3-msoffcrypto-tool -> planilhas da CEASA-MS protegidas contra gravacao
#
# As bibliotecas python vem do apt, nao do pip: a imagem base tem o ambiente
# python gerenciado externamente (PEP 668) e pip install falharia sem venv.

FROM google/cloud-sdk:slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-requests \
        python3-bs4 \
        python3-xlrd \
        python3-openpyxl \
        python3-msoffcrypto-tool \
        poppler-utils \
        tesseract-ocr \
        tesseract-ocr-por \
    && rm -rf /var/lib/apt/lists/*

# Sem isto o Python guarda a saida e so a solta no fim de cada script: o log
# do Cloud Run fica mudo por minutos e todas as linhas chegam com o mesmo
# horario, sem dar para medir cada fase.
ENV PYTHONUNBUFFERED=1

WORKDIR /app
COPY . /app
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
