# Case Zero on Cloud Run. The build context has the repository layout (deploy.sh stages it),
# so the synth packages, the mule scorer artefacts and the seed files are included.
# To build by hand from the repository root:
#   docker build -f services/case-zero/Dockerfile -t case-zero .
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY services/case-zero/requirements.txt services/case-zero/requirements.txt
RUN pip install --no-cache-dir -r services/case-zero/requirements.txt
COPY libs/synth/bhorosha_graph libs/synth/bhorosha_graph
COPY libs/synth/bhorosha_synth libs/synth/bhorosha_synth
COPY models/mule models/mule
COPY data/seed/device_links.jsonl data/seed/device_links.jsonl
COPY data/seed/sims.jsonl data/seed/sims.jsonl
COPY services/risk-mw/config/models.yaml services/risk-mw/config/models.yaml
COPY services/case-zero/case_zero services/case-zero/case_zero
COPY services/case-zero/static services/case-zero/static
ENV CASE_ZERO_PROJECT_DIR=/app PYTHONUNBUFFERED=1
WORKDIR /app/services/case-zero
CMD exec uvicorn case_zero.app:app --host 0.0.0.0 --port ${PORT:-8080}
