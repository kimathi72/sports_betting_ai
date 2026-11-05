FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    ML_MODEL_PATH=/app/artifacts/model_1x2.joblib \
    ML_METRICS_PATH=/app/artifacts/metrics.json

WORKDIR /app
ENV PYTHONPATH=/app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . /app/ml
COPY artifacts /app/artifacts

EXPOSE 8000

CMD ["uvicorn", "ml.app.main:app", "--host", "0.0.0.0", "--port", "8000"]