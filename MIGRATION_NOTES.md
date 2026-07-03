# Floci migration — research notes (Stage 0)

Source of truth: Floci official repo (https://github.com/floci-io/floci), README @ main,
and its own compatibility test suite. All quotes verified by reading raw files, not memory.

## Facts from Floci docs

| Item | Value | Source |
|---|---|---|
| Docker image | `floci/floci:latest` (standard), `floci/floci:latest-compat` (bundles AWS CLI + boto3, for init scripts) | README "Migrating from LocalStack" / "Image Tags" |
| Port | `4566` (same as LocalStack) | README, `docker-compose.yml` |
| Auth token | **NONE.** "No account. No auth token. No feature gates. Just `docker compose up`." | README header |
| AWS creds | Any non-empty values work | README "All AWS services... Credentials can be any non-empty values" |
| Docker socket | Required for Lambda (real Docker execution): `-v /var/run/docker.sock:/var/run/docker.sock` | README "Real Docker Integration" |
| Lambda backing | Real Docker, image `public.ecr.aws/lambda/<runtime>`, warm container pool | README service table |
| LocalStack compat | "drop-in replacement for LocalStack Community"; env vars auto-translated (`DEBUG=1`→`QUARKUS_LOG_LEVEL=DEBUG`, `PERSISTENCE=1`→`FLOCI_STORAGE_MODE=persistent`, etc.). Opt out with `LOCALSTACK_PARITY=false` | README "Migrating from LocalStack" |
| Terraform/OpenTofu | Explicitly supported; compat tests exist (compat-terraform, compat-opentofu) | README + repo tree |
| Invoke method | Standard AWS SDK/CLI against `http://localhost:4566` (e.g. `aws --endpoint-url http://localhost:4566 ...`). No Floci-specific invoke CLI. `awslocal`/`tflocal` are LocalStack host tools that target :4566 → work unchanged. | README SDK examples |

## THE key question: hot-reload magic bucket

- **README prose: hot-reload / mount / bind / watch → NOT documented** (grep found nothing about the hot-reload bucket in prose).
- **BUT the repo ships a passing compatibility test**: `compatibility-tests/sdk-test-java/.../LambdaHotReloadTest.java` (issue #553).
  It creates a function with `S3Bucket=hot-reload, S3Key=/host/path`, invokes (gets v1),
  overwrites the handler file on disk, invokes again → gets v2 **without UpdateFunctionCode**.
  → Same magic bucket name `hot-reload`, same host-path-as-S3Key mechanic as LocalStack.
- Conclusion for Stage 0: hot-reload is **very likely supported and API-compatible**, but
  NOT confirmed until we see it in real command output (Stage 1).

## Untranslated / uncertain

- `LAMBDA_DOCKER_FLAGS=-e LOCALSTACK_FILE_WATCHER_STRATEGY=polling` — LocalStack-specific,
  **not** in Floci's env translation table. Whether Floci needs a polling flag for its
  watcher: **not found in docs.** Left out of the minimal test; revisit if reload fails.
- `HOT_RELOAD_BASE_DIR` appears in the test (CI-only, for host-visible mount path). Not a
  documented runtime env var for end users.

## Stage 1 results — RAN AGAINST REAL FLOCI (image floci/floci:latest = v1.5.30 native)

Setup used: `docker-compose.yml` → `image: floci/floci:latest`, removed `LOCALSTACK_AUTH_TOKEN`,
kept the docker.sock + `${HOST_DIST_PATH}` volume mechanic. tflocal/awslocal unchanged (target :4566).

1. **Startup**: `docker compose up -d` → log ends with `=== AWS Local Emulator Ready ===` / `Ready.`
   in <1s (native binary). `awslocal lambda list-functions` succeeded immediately.
2. **tflocal init/apply**: works unchanged. BUT first apply FAILED with a real, useful error:
   ```
   InvalidParameterValueException: Hot-reload is disabled.
   Set FLOCI_SERVICES_LAMBDA_HOT_RELOAD_ENABLED=true to enable it.
   ```
   → **Hot-reload exists in Floci but is OFF by default.** This env var is NOT in the README;
     it came straight from Floci's own CreateFunction response. Added it to docker-compose.yml.
3. After enabling, `tflocal apply` → `Apply complete! Resources: 4 added`. Same main.tf, same
   `s3_bucket = "hot-reload"` / `s3_key = <host path>` — no HCL changes needed.
4. **Invoke #1** (`npm run invoke`, payload name=LocalStack):
   `{"message":"Hello, LocalStack!", ... "stage":"local"}` — StatusCode 200. ✅
5. **Hot-reload test**: edited greeting → `Hot-reloaded greeting for ${name}!`, `npm run build`,
   invoked again **WITHOUT tflocal apply**:
   `{"message":"Hot-reloaded greeting for LocalStack!", ...}` — StatusCode 200. ✅
   → **Response changed. Hot-reload magic bucket WORKS on Floci** (once the flag is set).
   (Greeting reverted to original afterwards.)

### Verdict
| Mechanic | LocalStack | Floci | Note |
|---|---|---|---|
| `floci/floci:latest` image, port 4566 | ✅ | ✅ | drop-in |
| Auth token | required | **not needed** | removed `LOCALSTACK_AUTH_TOKEN` entirely |
| `awslocal` invoke / `tflocal` apply | ✅ | ✅ | unchanged, target :4566 |
| `s3_bucket="hot-reload"` magic bucket | ✅ | ✅ | **but** needs `FLOCI_SERVICES_LAMBDA_HOT_RELOAD_ENABLED=true` |
| Reload-on-invoke, no redeploy | ✅ | ✅ | confirmed by real invoke output |

### Measured performance on Floci (final, canonical — used in README)
- esbuild rebuild: ~1–7 ms
- Floci container startup to `Ready.`: **<1 s** (native binary)
- Cold invoke (first call): **~3.7 s**
- Warm invoke: **~1.4 s** (median of 6)
- First invoke after a code change (hot-reload), 6 runs, each = sed→build→sleep 2→time invoke:
  **1.40 / 1.38 / 3.40 / 1.40 / 1.38 / 1.40 s** → median **1.40 s**, range **1.38–3.40 s**.
  All 6 invokes returned the NEW marker text → reload really happened before each invoke.
  (run 3 spike = reload landing during the invoke.)
- Verified with flag on vs off: warm invoke timing identical — invoke cost is unrelated to
  hot-reload; the flag only controls whether the code is reloaded.
  (Old README's ~0.5s/~1.2s/~10ms were LocalStack numbers — removed.)

### OpenTofu
- `TF_CMD=tofu tflocal init && tflocal apply -state=tofu.tfstate` against Floci → `Apply
  complete! Resources: 4 added`. Invoke returned `Hello, Floci!`. Hot-reload works identically.
  Verified with **OpenTofu v1.11.6**. (tofu.tfstate removed after; gitignored anyway.)

### Not needed / dropped for Floci
- `LOCALSTACK_AUTH_TOKEN` — Floci has no auth token.
- `LAMBDA_DOCKER_FLAGS=-e LOCALSTACK_FILE_WATCHER_STRATEGY=polling` — dropped; not needed,
  hot-reload picked up the change without it on macOS.

