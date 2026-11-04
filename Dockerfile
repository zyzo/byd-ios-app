FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .

# Settings (BYD_*, APP_TOKEN, BLE_KEY_JSON) come from Cloudflare vars and secrets as environment variables.
ENV PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080"]
