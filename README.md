# TypeScript Lambda on MiniStack with Terraform

Local TypeScript Lambda development against [MiniStack](https://github.com/ministackorg/ministack)
— a free, LocalStack-compatible AWS emulator — using the same Terraform config that deploys to
real AWS. `tflocal` only rewrites the AWS endpoints to `localhost:4566`; the `main.tf` is
identical for local and prod.

> **No hot-reload here.** Unlike LocalStack, MiniStack runs Node.js Lambdas in warm worker pools
> inside its own process — no per-function container, no bind-mount — so the LocalStack
> "hot-reload magic bucket" has no equivalent. Code is deployed from a zip; to pick up a change
> you rebuild and re-apply. See [How it works](#how-it-works) and the [gotcha](#-important-the-hot-reload-magic-bucket-does-not-exist-on-ministack).

---

## How it works

The Lambda is packaged as a zip from `dist/` (built by esbuild) and deployed with Terraform.
Both stages use the exact same code path — a normal zip deploy:

- `stage=local` → deployed to MiniStack (endpoints redirected to `localhost:4566` by `tflocal`)
- `stage=prod` → deployed to real AWS

The dev loop after editing a handler:

```
Edit src/handlers/hello.ts
  → npm run build           (esbuild rebuilds dist/hello.js, ~1–10 ms)
    → tflocal apply         (Terraform sees the new source_code_hash → UpdateFunctionCode, ~8.7 s)
      → npm run invoke      (~0.5 s)
```

There is no watch-and-reload: the warm worker holds the code loaded at deploy time and does not
re-read disk between invokes. A rebuild alone does nothing until you re-apply.

---

## > IMPORTANT: the hot-reload "magic bucket" does not exist on MiniStack

This repo used to set `s3_bucket = "hot-reload"` (a LocalStack magic marker). On MiniStack that
bucket is just an ordinary — and missing — S3 source, and the behaviour is a trap, because
**CreateFunction and UpdateFunctionCode disagree**:

- **CreateFunction does not validate the source.** `tflocal apply` goes green (`4 added`), but the
  function has no code:

  ```
  $ aws lambda get-function --function-name hello   # → CodeSize: 0
  $ aws lambda invoke ...
  {"statusCode": 200, "body": "Mock response - no code deployed"}
  ```

  A silently fake Lambda — worse than an error.

- **UpdateFunctionCode does validate it**, and fails loudly:

  ```
  An error occurred (InvalidParameterValueException) when calling the UpdateFunctionCode
  operation: Failed to fetch code from s3://hot-reload/<absolute-dist-path>
  ```

Both were reproduced directly against `ministackorg/ministack:latest` in this repo. The fix in
this branch: **drop the magic-bucket branch entirely** and always deploy the real zip (see
`infra/main.tf`).

---

## Prerequisites

| Tool                        | Install                                                                            |
| --------------------------- | --------------------------------------------------------------------------------- |
| Docker                      | [docker.com](https://www.docker.com/)                                             |
| Node.js 20+                 | [nodejs.org](https://nodejs.org/)                                                 |
| Terraform ≥ 1.5 or OpenTofu | [terraform.io](https://www.terraform.io/) / [opentofu.org](https://opentofu.org/) |
| `awslocal`                  | `pip install awscli-local`                                                         |
| `tflocal`                   | `pip install terraform-local`                                                      |

No account and no auth token — MiniStack is free (MIT). The Docker socket is **not** required for
this `nodejs20.x` function: MiniStack runs it in an in-process warm worker, not a container. (The
socket is only needed for container-backed services like RDS/ECS or `provided.*` Lambda runtimes.)

> `awslocal` and `tflocal` are LocalStack's host-side CLIs. They point standard `aws` and
> `terraform` at `http://localhost:4566`, and MiniStack is endpoint-compatible, so they work
> unchanged.

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

# 2. Start MiniStack
docker compose up -d

# 3. Deploy (zip) to MiniStack
cd infra
tflocal init
tflocal apply -auto-approve -var="stage=local"
cd ..

# 4. Invoke the function
npm run invoke

# 5. After editing src/handlers/hello.ts, rebuild AND re-deploy to pick it up
npm run build
(cd infra && tflocal apply -auto-approve -var="stage=local")
npm run invoke

# 6. Tail logs
npm run logs
```

`npm run watch` still works to rebuild `dist/` on save, but remember: on MiniStack a rebuild does
nothing until you re-apply.

---

## Deploy to real AWS

```bash
cd infra
terraform init
terraform apply -var="stage=prod"
```

Same zip, real AWS endpoints. `stage` also drives the IAM role name and the `STAGE` env var.

---

## OpenTofu

```bash
docker compose up -d
cd infra
TF_CMD=tofu tflocal init
TF_CMD=tofu tflocal apply -auto-approve -state=tofu.tfstate -var="stage=local"
```

Verified with OpenTofu v1.11.6 against MiniStack — `Apply complete! Resources: 4 added`, and
`npm run invoke` returned the real handler output (`Hello, OpenTofu!`).

---

## Platform gotchas

**Hot-reload magic bucket** — not supported; see the [callout above](#-important-the-hot-reload-magic-bucket-does-not-exist-on-ministack). This branch removed it.

**S3 uploads fail with a CRC64NVME checksum error** — modern AWS CLI (v2.3x+) defaults to the
CRC64NVME checksum on `PutObject`, which this MiniStack build does not implement:

```
$ aws --endpoint-url=http://localhost:4566 s3 cp file.txt s3://my-bucket/
An error occurred (InvalidRequest) when calling the PutObject operation: Checksum algorithm not
supported in this ministack build: CRC64NVME. Supported: SHA256, SHA1, CRC32.
```

Workaround — force a supported algorithm (or omit the checksum header):

```bash
AWS_REQUEST_CHECKSUM_CALCULATION=when_required aws --endpoint-url=http://localhost:4566 \
  s3 cp file.txt s3://my-bucket/
# or, on s3api calls:  --checksum-algorithm SHA256
```

This does not affect the Lambda deploy in this repo (Terraform's `archive_file` + `filename`
uploads the zip through the Lambda API, not `s3 cp`), but it bites any direct S3 upload.

**Terraform state drift** — `tflocal` writes to `terraform.tfstate` in `infra/`. Never run bare
`terraform apply` in `infra/` after `tflocal apply` — it will try to recreate resources that the
local emulator "owns". Use a separate workspace or state file:

```bash
# Option A: separate workspace
terraform workspace new local

# Option B: separate state file
tflocal apply -state=local.tfstate -var="stage=local"
```

---

## Measured performance

Measured in this repo against `ministackorg/ministack:latest`, macOS. Your numbers will vary.

| Step                                       | Time                       |
| ------------------------------------------ | -------------------------- |
| MiniStack container startup → `Ready`      | < 2 s                      |
| esbuild rebuild (`npm run build`)          | ~1–10 ms                   |
| Warm invoke (steady state)                 | ~0.5 s (median of 6)       |
| First invoke right after a (re)deploy      | ~2.5–2.8 s (worker warming)|
| Re-deploy (`tflocal apply -var=stage=local`)| ~8.7 s                     |

The edit→see-it loop is therefore dominated by the ~8.7 s re-apply, not by the millisecond
rebuild or the sub-second invoke. There is no sub-second hot-reload cycle on MiniStack.

---

## What works here

Verified in this repository against `ministackorg/ministack:latest`:

- Lambda zip deploy + execution (`nodejs20.x`, real Node.js runtime in the warm worker pool)
- CloudWatch Logs (`npm run logs`)
- IAM roles (created, but **not enforced** — a Lambda that passes locally may fail on real AWS
  due to missing permissions)

MiniStack emulates many more AWS services; see the
[MiniStack README](https://github.com/ministackorg/ministack) for the full list.

---

## Project structure

```
.
├── docker-compose.yml        # MiniStack (image + port only)
├── package.json              # build / watch / invoke scripts
├── tsconfig.json
├── src/
│   └── handlers/
│       └── hello.ts          # Lambda handler
├── dist/                     # esbuild output (gitignored)
├── infra/
│   ├── main.tf               # one config for local + prod (zip deploy)
│   ├── variables.tf
│   └── outputs.tf
└── scripts/
    └── setup.sh              # one-shot bootstrap
```

---

## Related

- [MiniStack](https://github.com/ministackorg/ministack) — the AWS emulator used here
- [ministack.org](https://ministack.org) — docs
- [tflocal (terraform-local)](https://github.com/localstack/terraform-local)
