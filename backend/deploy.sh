#!/usr/bin/env bash
#
# Deploys the backend to Cloud Run. Development only: see the note about state below.
#
# Usage:
#   GCP_PROJECT=your-project-id ./deploy.sh
#
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${GCP_REGION:-us-central1}"
SERVICE="${SERVICE_NAME:-journal-backend}"

if [[ -z "${PROJECT}" || "${PROJECT}" == "(unset)" ]]; then
  echo "Set GCP_PROJECT, or run: gcloud config set project <id>" >&2
  exit 1
fi

# Values come from the environment, or from .env, and are never printed or passed on a
# command line where they would land in shell history and in the process table.
if [[ -f .env ]]; then
  set -a; . ./.env; set +a
fi

if [[ -z "${GROQ_API_KEY:-}" ]]; then
  echo "GROQ_API_KEY is not set, and without it transcription and organising do nothing." >&2
  exit 1
fi

# The guard that matters.
#
# require_auth in app/main.py returns early when no key is configured, so a deploy without
# CP_API_KEY is an unauthenticated proxy to your Groq account on a public URL. Anyone who
# finds it spends your quota. Refusing here is the only reliable place to catch it, because
# nothing about the running service looks wrong afterwards.
if [[ -z "${CP_API_KEY:-}" ]]; then
  CP_API_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  echo
  echo "No CP_API_KEY was set, so one has been generated:"
  echo
  echo "    ${CP_API_KEY}"
  echo
  echo "Put it in the app: Settings, then the API key field. Add it to backend/.env too,"
  echo "or the next deploy will generate a different one and the app will get a 401."
  echo
  read -r -p "Press return once you have copied it. " _
fi

secret() {  # name, value — created on first use, new version after that.
  local name="$1" value="$2"
  if ! gcloud secrets describe "${name}" --project "${PROJECT}" >/dev/null 2>&1; then
    gcloud secrets create "${name}" --project "${PROJECT}" --replication-policy=automatic >/dev/null
  fi
  printf '%s' "${value}" | gcloud secrets versions add "${name}" --project "${PROJECT}" --data-file=- >/dev/null
}

echo "Storing secrets in Secret Manager..."
secret groq-api-key "${GROQ_API_KEY}"
secret cp-api-key "${CP_API_KEY}"

# --timeout 300 because organising is two sequential model calls and the default 60s is not
#   enough for a ten minute transcript.
# --max-instances 3 caps the blast radius of a runaway loop or a found URL.
# --allow-unauthenticated because the phone authenticates with CP_API_KEY, not with Google
#   credentials. That is only safe because of the check above.
echo "Deploying ${SERVICE} to ${REGION}..."
gcloud run deploy "${SERVICE}" \
  --project "${PROJECT}" \
  --region "${REGION}" \
  --source . \
  --allow-unauthenticated \
  --timeout 300 \
  --memory 512Mi \
  --max-instances 3 \
  --set-secrets "GROQ_API_KEY=groq-api-key:latest,CP_API_KEY=cp-api-key:latest"

URL="$(gcloud run services describe "${SERVICE}" --project "${PROJECT}" --region "${REGION}" --format='value(status.url)')"
echo
echo "Live at ${URL}"
echo
echo "Check it:  curl -s ${URL}/health | python3 -m json.tool"
echo "In the app: Settings, server address, ${URL}"
