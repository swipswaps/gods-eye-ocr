FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN apt-get update && apt-get install -y gcc g++ make && \
    git clone https://github.com/asg017/sqlite-vec.git && \
    cd sqlite-vec && make && make install && \
    apt-get remove -y gcc g++ make && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

COPY . .

ENV PYTHONPATH=/app
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
