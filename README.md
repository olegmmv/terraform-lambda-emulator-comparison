# TypeScript Lambda hot-reload with Terraform and Floci

Iterate on a Lambda in seconds — no redeploy, no `aws lambda update-function-code`, no
re-running `tflocal apply` on every edit — using the same Terraform config that deploys to
production.

[Floci](https://github.com/floci-io/floci) is an AWS local emulator (a LocalStack-compatible
"Always Free" alternative). This repo runs against it with no account and no auth token.

---

## How it works

The key is Floci's **hot-reload magic bucket**.

When `s3_bucket = "hot-reload"` is set on a Lambda resource, Floci does not treat it as a real
S3 bucket. Instead it:

1. bind-mounts `s3_key` (an absolute path on the **host** machine) into the Lambda container
2. watches that path for file changes
3. reloads the function on the next invoke — no container restart, no re-deploy

Combined with `esbuild --watch` rebuilding TypeScript in ~1–7 ms, you edit a handler and the
next invoke runs the new code.

```
Edit src/handlers/hello.ts
  → esbuild rebuilds dist/hello.js (~1–7 ms)
    → Floci detects the change
      → next invoke runs new code
```

The same `main.tf` works for real AWS — switch `stage=prod` and it deploys a zip instead.

> [!IMPORTANT]
> **Hot-reload is OFF by default in Floci** — unlike LocalStack, where it is always on.
> You must set `FLOCI_SERVICES_LAMBDA_HOT_RELOAD_ENABLED=true` (already done in this repo's
> `docker-compose.yml`). Without it, `CreateFunction` on the `hot-reload` bucket fails with:
> `InvalidParameterValueException: Hot-reload is disabled.`
> See the [Floci environment variables docs](https://floci.io/floci/configuration/environment-variables/).

---

## Prerequisites

| Tool                        | Install                                                                            |
| --------------------------- | --------------------------------------------------------------------------------- |
| Docker                      | [docker.com](https://www.docker.com/)                                             |
| Node.js 20+                 | [nodejs.org](https://nodejs.org/)                                                 |
| Terraform ≥ 1.5 or OpenTofu | [terraform.io](https://www.terraform.io/) / [opentofu.org](https://opentofu.org/) |
| `awslocal`                  | `pip install awscli-local`                                                         |
| `tflocal`                   | `pip install terraform-local`                                                      |

No account and no auth token are required — Floci is free and needs neither.

> `awslocal` and `tflocal` are LocalStack's host-side CLIs. They just point standard `aws`
> and `terraform` at `http://localhost:4566`, so they work unchanged against Floci. (Equivalent:
> `aws --endpoint-url http://localhost:4566 …` and plain `terraform` with the endpoint set.)

---

## Quickstart

```bash
git clone https://github.com/olegmmv/terraform-lambda-emulator-comparison
cd terraform-lambda-emulator-comparison
bash scripts/setup.sh
```

Or step by step:

```bash
# 1. Install dependencies and build
npm install
npm run build

# 2. Set the host path to mount (see note below)
export HOST_DIST_PATH="$(pwd)/dist"

# 3. Start Floci
docker compose up -d

# 4. Deploy to Floci (once)
cd infra
tflocal init
tflocal apply -auto-approve \
  -var="stage=local" \
  -var="lambda_mount_path=${HOST_DIST_PATH}"
cd ..

# 5. Invoke the function
npm run invoke

# 6. Start watch mode (separate terminal)
npm run watch

# 7. Edit src/handlers/hello.ts, save, then invoke — see updated response
npm run invoke

# 8. Tail logs
npm run logs
```

> **Why `HOST_DIST_PATH`?**
> Floci runs each Lambda in a real Docker container and mounts `lambda_mount_path` from the
> **host** filesystem directly — not from inside the Floci container. So the path must be a
> real path on your machine, and it must be the same in both the `docker-compose.yml` volume
> and the `lambda_mount_path` variable.
>
> Floci needs the host Docker socket (`/var/run/docker.sock`, already in `docker-compose.yml`)
> to launch those Lambda containers.

---

## Deploy to real AWS

```bash
cd infra
terraform init
terraform apply -var="stage=prod"
```

The `stage != "local"` path skips the hot-reload bucket and builds a zip from `dist/`.

---

## OpenTofu

```bash
export HOST_DIST_PATH="$(pwd)/dist"
docker compose up -d
cd infra
TF_CMD=tofu tflocal init
TF_CMD=tofu tflocal apply -auto-approve \
  -var="stage=local" \
  -var="lambda_mount_path=${HOST_DIST_PATH}"
```

Verified with OpenTofu v1.11.6 against Floci — same config, hot-reload works identically.

---

## Platform gotchas

**Docker Desktop (macOS)** — works out of the box; this repo was verified on Docker Desktop /
macOS. If you ever hit `mounts denied` on invoke, add the project path under **Settings →
Resources → File Sharing** and **Apply & Restart**.

**Rancher Desktop / Colima** — untested. If hot-reload does not pick up changes there, check
[Floci issues](https://github.com/floci-io/floci/issues).

**Terraform state drift** — `tflocal` writes to `terraform.tfstate` in `infra/`. Never run bare
`terraform apply` in `infra/` after `tflocal apply` — it will try to recreate resources that the
local emulator "owns". Use a separate workspace or state file:

```bash
# Option A: separate workspace
terraform workspace new local

# Option B: separate state file
tflocal apply -state=local.tfstate \
  -var="stage=local" \
  -var="lambda_mount_path=${HOST_DIST_PATH}"
```

---

## Measured performance

Measured on this repo against `floci/floci:latest` (Floci 1.5.30, native), macOS. Your numbers
will vary with hardware.

| Step                                             | Time            |
| ------------------------------------------------ | --------------- |
| Floci container startup → `Ready.`               | < 1 s           |
| esbuild rebuild (`npm run build`)                | ~1–7 ms         |
| Cold invoke (first call, container spin-up)      | ~3.7 s          |
| Warm invoke                                      | ~1.4 s (median of 6) |
| First invoke **after a code change** (hot-reload)| ~1.4 s median, 1.38–3.40 s range (6 runs) |

The hot-reload row was measured as: edit handler → `npm run build` → wait ~2 s → invoke, six
times. All six invokes served the reloaded code, confirming the change is picked up before the
call. The occasional spike toward ~3.4 s is when the reload lands during the invoke itself.

Hot-reload does not add per-invoke cost: warm invoke timing is the same with the flag on or off
— the code just isn't reloaded without it. The feedback loop after an edit is roughly a second
or two, dominated by invoke time, not by the ~ms rebuild.

---

## What works here

Floci is [free](https://github.com/floci-io/floci) with no account or auth token. Verified in
this repository against `floci/floci:latest`:

- Lambda execution + hot-reload (with `FLOCI_SERVICES_LAMBDA_HOT_RELOAD_ENABLED=true`)
- CloudWatch Logs (`npm run logs`)
- IAM roles (created, but **not enforced** — a Lambda that passes locally may fail on real AWS
  due to missing permissions)

Floci emulates many more AWS services; see the [Floci README](https://github.com/floci-io/floci)
for the full list.

---

## Project structure

```
.
├── docker-compose.yml        # Floci + volume mount + hot-reload flag
├── package.json              # build / watch / invoke scripts
├── tsconfig.json
├── src/
│   └── handlers/
│       └── hello.ts          # Lambda handler
├── dist/                     # esbuild output (gitignored)
├── infra/
│   ├── main.tf               # one config for local + prod
│   ├── variables.tf
│   └── outputs.tf
└── scripts/
    └── setup.sh              # one-shot bootstrap
```

---

## Related

- [Floci](https://github.com/floci-io/floci) — the AWS local emulator used here
- [Floci environment variables](https://floci.io/floci/configuration/environment-variables/) — including the hot-reload flag
- [Migrate from LocalStack](https://floci.io/floci/getting-started/migrate-from-localstack/)
- [tflocal (terraform-local)](https://github.com/localstack/terraform-local)
