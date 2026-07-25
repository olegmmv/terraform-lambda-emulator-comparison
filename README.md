# TypeScript Lambda hot-reload with Terraform and LocalStack

Sub-second Lambda iteration cycles using the same Terraform config that deploys to production.

No second config file. No manual `aws lambda update-function-code`. No re-running `tflocal apply` on every edit.

---

## How it works

The key is LocalStack's **hot-reload magic bucket**.

When `s3_bucket = "hot-reload"` is set on a Lambda resource, LocalStack does not treat it as a real S3 bucket. Instead it:

1. bind-mounts `s3_key` (an absolute path on the **host** machine) into `/var/task`
2. watches that path for file changes
3. reloads the function runtime on the next invoke — no container restart, no re-deploy

Combined with `esbuild --watch` rebuilding TypeScript in under 100ms, the total feedback loop is **under one second**.

```
Edit src/handlers/hello.ts
  → esbuild rebuilds dist/hello.js (~80ms)
    → LocalStack detects the change
      → next invoke runs new code (~500ms)
```

The same `main.tf` works for real AWS — switch `stage=prod` and it deploys a zip instead.

---

## Prerequisites

| Tool                        | Install                                                                                                                               |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Docker                      | [docker.com](https://www.docker.com/)                                                                                                 |
| Node.js 20+                 | [nodejs.org](https://nodejs.org/)                                                                                                     |
| Terraform ≥ 1.5 or OpenTofu | [terraform.io](https://www.terraform.io/) / [opentofu.org](https://opentofu.org/)                                                     |
| `awslocal`                  | `pip install awscli-local`                                                                                                            |
| `tflocal`                   | `pip install terraform-local`                                                                                                         |
| LocalStack account          | Free [Hobby plan](https://www.localstack.cloud/pricing) — get your auth token at [app.localstack.cloud](https://app.localstack.cloud) |

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

# 2. Set environment variables
export HOST_DIST_PATH="$(pwd)/dist"
export LOCALSTACK_AUTH_TOKEN="your-token-here"  # from app.localstack.cloud

# 3. Start LocalStack
docker compose up -d

# 4. Deploy to LocalStack (once)
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
> LocalStack spawns a child Docker container for each Lambda invocation and mounts
> `lambda_mount_path` from the **host** filesystem directly — not from inside the
> LocalStack container. So the path must be a real path on your machine, and it must
> be the same in both the `docker-compose.yml` volume and the `lambda_mount_path` variable.
>
> **`LOCALSTACK_AUTH_TOKEN`** is required since LocalStack 2026.03.0.
> Get yours free at [app.localstack.cloud](https://app.localstack.cloud) (Hobby plan, non-commercial use).

---

## Docker Desktop: File Sharing (macOS)

On macOS with Docker Desktop you must explicitly allow the path to be mounted.

Go to **Docker Desktop → Settings → Resources → File Sharing** and add:

```
/Users/<your-username>
```

Or the specific project path if you prefer a narrower scope. Click **Apply & Restart**.

Without this step Docker will refuse to mount the `dist/` folder and Lambda invocations
will fail with `mounts denied`.

---

## OpenTofu

```bash
export HOST_DIST_PATH="$(pwd)/dist"
export LOCALSTACK_AUTH_TOKEN="your-token-here"
docker compose up -d
cd infra
TF_CMD=tofu tflocal init
TF_CMD=tofu tflocal apply -auto-approve \
  -var="stage=local" \
  -var="lambda_mount_path=${HOST_DIST_PATH}"
```

---

## Deploy to real AWS

```bash
cd infra
terraform init
terraform apply -var="stage=prod"
```

The `stage != "local"` path skips the hot-reload bucket and builds a zip from `dist/`.

---

## Platform gotchas

**Docker Desktop macOS (most common issue)** — Docker must be allowed to mount the project path. Go to **Settings → Resources → File Sharing** and add `/Users/<your-username>` or the specific project path. Click **Apply & Restart**. Without this you get `mounts denied` errors on Lambda invoke.

**Rancher Desktop / Colima / WSL2** — polling-based file watching is enabled by default via `LAMBDA_DOCKER_FLAGS` in `docker-compose.yml`. If hot-reload doesn't pick up changes, see the [LocalStack hot-reload docs](https://docs.localstack.cloud/aws/tooling/lambda-tools/hot-reloading/) for platform-specific setup. Not tested with this repository — PRs welcome.

**Terraform state drift** — `tflocal` writes to `terraform.tfstate` in `infra/`. Never run bare `terraform apply` in `infra/` after `tflocal apply` — it will try to recreate resources that LocalStack "owns". Use a separate workspace or state file:

```bash
# Option A: separate workspace
terraform workspace new local

# Option B: separate state file
tflocal apply -state=local.tfstate \
  -var="stage=local" \
  -var="lambda_mount_path=${HOST_DIST_PATH}"
```

---

## What works on LocalStack Hobby plan (free)

Everything in this repository runs on the free [Hobby plan](https://www.localstack.cloud/pricing) (non-commercial use, requires auth token).

Verified with this repository:

- Lambda execution + hot-reload
- CloudWatch Logs
- IAM roles (created, but **not enforced** — a Lambda that passes locally may fail in AWS due to missing permissions)

The Hobby plan includes 30+ emulated AWS services. For the full list by plan, see [Emulated Services](https://docs.localstack.cloud/aws/licensing/).

---

## Project structure

```
.
├── docker-compose.yml        # LocalStack + volume mount
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

- [LocalStack hot-reload docs](https://docs.localstack.cloud/aws/tooling/lambda-tools/hot-reloading/)
- [tflocal (terraform-local)](https://github.com/localstack/terraform-local)
- [AWS SAM CLI with Terraform](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/using-samcli-terraform.html) — alternative for step-through debugging
