# Cloud Run image for the backend.
#
# Deliberately copies only pyproject.toml and app/. Copying the whole directory would put
# .env (which holds the Groq key), .state (which holds a Notion token) and the eval
# transcripts inside a distributable image. .dockerignore repeats the point; both are here
# because leaking a key into an image layer is not recoverable by deleting the file later.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /srv

# pyproject is the single source of truth for dependencies. Listing them again in a
# requirements.txt is how the two copies drift, which has already cost this project a day
# when a model name was duplicated between two files and only one was updated.
COPY pyproject.toml ./
COPY app ./app
RUN pip install --no-cache-dir .

# Cloud Run's filesystem is in-memory and resets on every scale to zero, so the state
# directory is somewhere writable and is treated as disposable. The consequence is real:
# the Notion token and the protected-word list do not survive an instance recycling. That
# is acceptable for development and is exactly the gap the per-user storage work closes.
ENV CP_STATE_DIR=/tmp/state

# Cloud Run injects PORT. The default matches so the image behaves the same locally.
ENV PORT=8080
EXPOSE 8080

CMD exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT}
