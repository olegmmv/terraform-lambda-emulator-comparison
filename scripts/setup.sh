#!/usr/bin/env bash
# setup.sh — one-shot local environment bootstrap
set -euo pipefail

# awslocal/tflocal are LocalStack's host CLIs; they target http://localhost:4566,
# where MiniStack is endpoint-compatible, so they work unchanged. No auth token.
for cmd in docker node npm awslocal tflocal; do
  command -v "$cmd" &>/dev/null || { echo "Error: $cmd not found." >&2; exit 1; }
done

echo "▶ Installing Node dependencies..."
npm install

echo "▶ Building TypeScript → dist/..."
npm run build

echo "▶ Starting MiniStack..."
docker compose up -d

echo "▶ Waiting for MiniStack to be ready..."
elapsed=0
until awslocal lambda list-functions &>/dev/null 2>&1; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -ge 30 ]; then
    echo "Error: MiniStack didn't start within 30s. Check: docker compose logs ministack" >&2
    exit 1
  fi
done
echo "  MiniStack is up."

echo "▶ Running tflocal apply (zip deploy)..."
cd infra
tflocal init -input=false
tflocal apply -auto-approve -var="stage=local"
cd ..

echo ""
echo "✅ Done. Run the following to test:"
echo "   npm run invoke"
echo ""
echo "To pick up a code change: edit src/handlers/hello.ts, then re-deploy:"
echo "   npm run build && (cd infra && tflocal apply -auto-approve -var=stage=local)"
