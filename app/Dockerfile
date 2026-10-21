FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

ENV PYTHONUNBUFFERED=1
# O Cloud Run informa a porta pela variável PORT.
CMD streamlit run app.py --server.port=${PORT:-8080} --server.address=0.0.0.0
