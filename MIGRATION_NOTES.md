# MiniStack migration — research notes (Stage 0)

Source of truth: MiniStack official docs (https://ministack.org, https://ministack.org/docs)
and the GitHub README (https://github.com/ministackorg/ministack). All quotes verified by
reading raw README/docs, not memory, not the `floci` branch.

## Facts from MiniStack docs

| Item | Value | Source |
|---|---|---|
| Docker image | `ministackorg/ministack` (default; `:latest` used in docs' compose example). `:full` variant (~360MB, Debian/glibc, DuckDB/psycopg2) for Athena/native DB drivers. | README Quick Start / compose example |
| Port | `4566` (`GATEWAY_PORT`, default). `EDGE_PORT` accepted as LocalStack alias | README Configuration table |
| Auth token | **NONE.** MIT licensed, "free forever". Positioned as free LocalStack-Community replacement. | README intro |
| AWS creds | Any values; 12-digit `AWS_ACCESS_KEY_ID` selects account (multi-tenancy) | README |
| Docker socket | Required **only** for real-container services (RDS, ECS, EKS, `LAMBDA_EXECUTOR=docker`, `provided.*` runtimes, `PackageType: Image`). "Basic usage without the socket works but uses mock/in-memory only." | README Quick Start |
| **Lambda Node.js execution** | **Node.js + Python runtimes execute with a warm worker pool as a LOCAL SUBPROCESS inside the MiniStack process** (`LAMBDA_EXECUTOR=local`, the default). Only `provided.al2023`/`provided.al2` and `PackageType: Image` use Docker RIE. | README Lambda row + executor section |
| Node runtimes | `nodejs14.x` – `nodejs24.x` (our `nodejs20.x` ✓) | README runtime table |
| Lambda code sources | `ZipFile`, `S3Bucket`/`S3Key` (+ optional `S3ObjectVersion`), or `ImageUri`. | README Lambda row |
| tflocal / awslocal | LocalStack-compatible: serves `/_localstack/health`, accepts `EDGE_PORT`, works with `aws --endpoint-url=http://localhost:4566`, "Compatible with boto3, AWS CLI, Terraform, CDK, Pulumi". `tflocal` not named explicitly but it just points TF at :4566 → expected to work. | README |
| Warm pool TTL | `LAMBDA_WARM_TTL_SECONDS` (default 300s) — idle **container** eviction (docker executor). | README executor section |
| Docker-in-docker mount | `LAMBDA_REMOTE_DOCKER_VOLUME_MOUNT` + `/var/task` volume — ONLY when MiniStack runs in a container AND uses the docker executor with sibling Lambda containers. Not for the Node local executor. | README |

## THE key question: hot-reload magic bucket

- **`s3_bucket = "hot-reload"` magic bucket → NOT documented anywhere.** grep of the full README
  for `hot-reload` / `hot.reload` / `watch` / `mount`(as code-reload) found **nothing**. MiniStack
  treats `S3Bucket`/`S3Key` as a **real S3 object reference**, not a magic marker.
- Node.js Lambda runs as an in-process warm worker (no per-invoke container, no `/var/task`
  bind-mount of host code). So the LocalStack magic-bucket mechanic almost certainly does NOT
  exist here.
- **Not yet confirmed** whether:
  (a) `CreateFunction` with `S3Bucket="hot-reload"` errors (no such bucket), and
  (b) the zip path (`stage=prod`) works against MiniStack, and
  (c) the warm worker re-reads code from disk without redeploy.
  → All three are Stage 1 experiments. "not found in docs" for hot-reload; do NOT assume.

## docker.sock decision for the minimal test
Our Lambda is `nodejs20.x` → local executor → docs say socket is NOT required. Removing it for
the minimal test; will add back only if invoke fails.

## Stage 1 results — RAN AGAINST REAL MiniStack (ministackorg/ministack:latest)

Setup: `docker-compose.yml` → `image: ministackorg/ministack:latest`, removed
`LOCALSTACK_AUTH_TOKEN`, removed `docker.sock` (Node local executor works without it),
kept `${HOST_DIST_PATH}` volume. tflocal/awslocal target :4566 unchanged.

1. **Startup**: `docker compose up -d` → log `Ready — 69 services available on port 4566` in <2s.
   `/_localstack/health` served (LocalStack-compat). `awslocal lambda list-functions` OK.
   No auth token, no docker.sock needed. ✅
2. **tflocal init/apply** works (LocalStack-compatible endpoints). ✅

3. **`stage=local` (magic bucket `s3_bucket="hot-reload"`) — BROKEN, but silently.**
   - `apply` **succeeds** (`4 added`, no error).
   - BUT `get-function` → `CodeSize: 0`; `Code.Location` = `.../_ministack/lambda-code/hello`.
   - `invoke` → `{"statusCode": 200, "body": "Mock response - no code deployed"}`.
   - → MiniStack treats `S3Bucket="hot-reload"` as a **real** (missing) S3 object, registers a
     hollow function with no code, and returns a mock. **The LocalStack magic bucket does NOT
     exist on MiniStack.** Worse than an error: apply is green but the Lambda is fake.

4. **`stage=prod` (zip deploy via `filename`/`ZipFile`) — WORKS.** ✅
   - `apply` → `CodeSize: 880`, `State: Active`.
   - `invoke` → real handler output: `{"message":"Hello, MiniStack!", ... "stage":"prod"}`.
     Genuine Node.js execution in the warm worker pool (log shows a real Node runtime warning).

5. **Hot-reload without redeploy — does NOT work.**
   - Edited greeting → `npm run build` → `invoke` WITHOUT re-apply → returned **STALE** old code
     (`Hello, X!`, not the new marker). The warm worker does not re-read code from disk.
6. **Re-apply picks up changes.** `tflocal apply -var=stage=prod` after an edit → Terraform sees
   the `source_code_hash` change → `UpdateFunctionCode` → next invoke returns the NEW marker.
   Verified NEW ✓ across 3 consecutive edit→build→apply→invoke cycles.

### Verdict
| Mechanic | LocalStack | MiniStack | Note |
|---|---|---|---|
| `ministackorg/ministack:latest`, port 4566 | ✅ | ✅ | drop-in start |
| Auth token | required | **not needed** | removed |
| docker.sock | needed | **not needed** for nodejs | Node runs in-process (local executor) |
| `awslocal` / `tflocal` | ✅ | ✅ | LocalStack-compat |
| `s3_bucket="hot-reload"` magic bucket | ✅ | **❌ silent mock** | apply green, but CodeSize 0 + "Mock response - no code deployed" |
| Zip deploy (`filename`) | ✅ | ✅ | real code runs |
| Edit→invoke reload, no redeploy | ✅ | **❌** | must re-apply (UpdateFunctionCode) |

### Measured performance on MiniStack (this machine, macOS)
- Container startup → `Ready`: **<2 s**
- esbuild rebuild: **~1–10 ms**
- Warm invoke (steady state, 6 back-to-back, drop #1): **0.50 s median** (range 0.50–0.51 s)
- First invoke right after a (re)deploy (worker pool cold): **~2.5–2.8 s**
- Redeploy cycle `tflocal apply -var=stage=prod`: **~8.7 s** (8.72 / 8.73 / 8.76 s), each
  reliably updating the code (invoke returned the new marker every time).
- NOTE: the LocalStack-style hot-reload benchmark (edit→invoke, no redeploy) is N/A — that path
  doesn't work here. The real MiniStack dev loop is edit → build (~ms) → `tflocal apply` (~8.7 s)
  → invoke (~0.5 s).

## Stage 2 — reproduced verbatim (used in README)

- CreateFunction w/ `S3Bucket=hot-reload` → `CodeSize: 0`, invoke →
  `{"statusCode": 200, "body": "Mock response - no code deployed"}`.
- UpdateFunctionCode w/ same source → loud:
  `An error occurred (InvalidParameterValueException) when calling the UpdateFunctionCode
  operation: Failed to fetch code from s3://hot-reload/<absolute-dist-path>`
  → Create doesn't validate the S3 source, Update does. (Reproduced directly via awslocal.)
- `aws s3 cp` (default modern CLI checksum) → `An error occurred (InvalidRequest) ... PutObject ...
  Checksum algorithm not supported in this ministack build: CRC64NVME. Supported: SHA256, SHA1,
  CRC32.` Workaround: `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` (or `--checksum-algorithm
  SHA256`) → upload succeeds. Does not affect the Lambda zip deploy.
- **OpenTofu v1.11.6**: `TF_CMD=tofu tflocal apply -state=tofu.tfstate -var stage=local` →
  `Apply complete! Resources: 4 added`; invoke → `Hello, OpenTofu!` (stage=local, real zip). ✅

### Decision applied
Kept the `stage` switch (structural parity with main/floci branches) but removed the magic-bucket
branch: `local` and `prod` both zip-deploy; only the endpoints differ (via tflocal). Removed
`lambda_mount_path`, `HOST_DIST_PATH` volume, docker.sock, auth token.

### Migration implication (for Stage 2 decision)
The whole premise of this repo — "sub-second local iteration via the hot-reload magic bucket" —
**does not carry over to MiniStack**. On MiniStack there is only the ordinary zip-deploy path
(the same one this repo labels `stage=prod`). The `stage=local` / `s3_bucket="hot-reload"` branch
must be removed or it silently ships a broken (mock) Lambda. Open question for the user in Stage 2:
make `local` use the zip path too (drop the magic-bucket branch), and reframe the README around
"real zip deploy, re-apply to update" instead of hot-reload.

