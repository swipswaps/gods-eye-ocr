FROM python:3.12-slim

WORKDIR /app

# curl is required by the docker-compose healthcheck.
RUN apt-get update && apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PYTHONPATH=/app
ENV DB_PATH=/app/data/app.db
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
