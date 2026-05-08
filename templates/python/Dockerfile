FROM python:3.11-slim-bullseye AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential
COPY requirements.txt .
RUN pip wheel --no-cache-dir --no-deps --wheel-dir /app/wheels -r requirements.txt

FROM python:3.11-slim-bullseye
WORKDIR /app

# Security: Non-root user
RUN addgroup --system appgroup && adduser --system --group appuser

COPY --from=builder /app/wheels /wheels
COPY --from=builder /app/requirements.txt .
RUN pip install --no-cache /wheels/*

COPY . .
RUN chown -R appuser:appgroup /app

USER appuser
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
EXPOSE 8000

# Gunicorn for production, adjust workers based on RAM (2-4 recommended for 8GB total server)
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "main:app"]
