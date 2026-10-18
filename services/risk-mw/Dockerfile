# risk-mw on Cloud Run. A Dockerfile (not buildpacks) so LightGBM's libgomp dependency is explicit.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080 \
    RISK_MW_MULE_ARTEFACTS_DIR=/app/artifacts/mule \
    RISK_MW_ATO_ARTEFACTS_DIR=/app/artifacts/ato \
    RISK_MW_APPSAFETY_ARTEFACTS_DIR=/app/artifacts/app-safety-check

RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# scripts/deploy.sh fills two build-time directories before the build:
#   vendor/     bhorosha_graph and bhorosha_synth (libs/synth), bhorosha_ato (libs/ato) and
#               bhorosha_app_safety_check (libs/app-safety-check);
#   artifacts/  mule/ (graph.pkl, model.lgb, features.parquet, scorer.json from models/mule),
#               ato/ (the behaviour artefacts from models/ato, when present) and
#               app-safety-check/ (model.txt, columns.json, meta.json from models/app-safety-check).
# .dockerignore keeps tests, eval data and caches out of the image.
COPY . .
ENV PYTHONPATH=/app/vendor

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
