#!/bin/zsh

set -e

cd "$(dirname "$0")/backend"
source .venv/bin/activate
exec uvicorn app.main:app --reload --env-file .env
