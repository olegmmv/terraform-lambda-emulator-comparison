#!/usr/bin/env bash
# setup.sh — one-shot local environment bootstrap
set -euo pipefail

# awslocal/tflocal are LocalStack's host CLIs; they target http://localhost:4566,
# where Floci is API-compatible, so they work unchanged. Floci needs no auth token.
for cmd in docker node npm awslocal tflocal; do
  command -v "$cmd" &>/dev/null || { echo "Error: $cmd not found." >&2; exit 1; }
done

export HOST_DIST_PATH="$(pwd)/dist"

echo "▶ Installing Node dependencies..."
npm install

echo "▶ Building TypeScript → dist/..."
npm run build

echo "▶ Starting Floci (HOST_DIST_PATH=${HOST_DIST_PATH})..."
docker compose up -d

echo "▶ Waiting for Floci to be ready..."
elapsed=0
until awslocal lambda list-functions &>/dev/null 2>&1; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -ge 30 ]; then
    echo "Error: Floci didn't start within 30s. Check: docker compose logs floci" >&2
    exit 1
  fi
done
echo "  Floci is up."

echo "▶ Running tflocal apply..."
cd infra
tflocal init -input=false
tflocal apply -auto-approve \
  -var="stage=local" \
  -var="lambda_mount_path=${HOST_DIST_PATH}"
cd ..

echo ""
echo "✅ Done. Run the following to test:"
echo "   npm run invoke"
echo ""
echo "For hot-reload, open a second terminal and run:"
echo "   npm run watch"
