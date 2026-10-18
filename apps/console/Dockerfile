# FinNest Admin on Cloud Run.
#
# The layout inside the image mirrors the repo on purpose. api/risk_mw.py finds risk-mw, the seed
# and the model files by walking up from its own file, and aggregate.py reads the eval results by
# repo-relative path; flattening everything into /app would mean teaching both of them a second set
# of paths that only exists in production. So the build context is assembled to look like a
# trimmed checkout - apps/console/ beside data/, models/ and eval/ - and /srv is its root.
#
# scripts/deploy.sh builds that context. Do not `docker build` the repo directly.

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080 \
    RISK_MW_MULE_ARTEFACTS_DIR=/srv/models/mule

# LightGBM needs libgomp; the mule scorer is imported at start-up to warm it.
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
COPY apps/console/api/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY . /srv

# vendor/ holds risk-mw's `app` package plus bhorosha_graph, bhorosha_synth and bhorosha_ato, copied
# by scripts/deploy.sh. api/risk_mw.py falls back to it when services/risk-mw is absent.
ENV PYTHONPATH=/srv/apps/console/vendor

WORKDIR /srv/apps/console
CMD exec uvicorn api.main:app --host 0.0.0.0 --port ${PORT} --workers 1
