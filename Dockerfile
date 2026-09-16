FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY kk.py .
COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt
RUN pip install --no-cache-dir waitress flask requests urllib3

ENV DATA_DIR=/data
ENV PORT=8000
RUN mkdir -p /data

EXPOSE 8000

CMD ["python", "kk.py"]
