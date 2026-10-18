# Security

FinNest is a hackathon prototype for a fictional bank. All accounts, people, transactions and
calls in this repository are synthetic. Do not use it with real customer data.

## Report a vulnerability

Do not open a public issue. Use GitHub's private vulnerability reporting on this repository
(**Security** tab, **Report a vulnerability**). We reply on a best-effort basis.

## What is not in this repository

- No credentials, API keys, service-account keys, Firebase configuration or signing keys.
  Each component reads them from environment variables or local files that `.gitignore` excludes.
  See the `.env.example` files and the component READMEs.
- No personal data. Behaviour models trained on third-party research datasets are not
  redistributed; `models/README.md` explains how to train them.

## Known prototype limits

- The admin console uses one operator account with a password from the environment. Production
  needs a real identity provider.
- Release Android builds are signed with the debug key. They are for demos only.
- Model files in `models/` use Python `pickle` and `joblib`. These formats can run code when they
  load. Load only files from this repository or files that you trained yourself.
