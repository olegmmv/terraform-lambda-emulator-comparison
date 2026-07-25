# Local AWS emulators compared: LocalStack vs Floci vs MiniStack

In March 2026 LocalStack removed its free Community edition — the emulator now requires
an account and a `LOCALSTACK_AUTH_TOKEN` even on the Hobby plan. Two MIT-licensed,
LocalStack-compatible alternatives appeared in its wake: [Floci](https://github.com/floci-io/floci)
and [MiniStack](https://github.com/ministackorg/ministack). This repository runs **the same
Terraform + TypeScript Lambda setup** through all three emulators — one `main.tf`, one
`hello.ts` handler, one esbuild pipeline — and measures the inner development loop
(edit → build → invoke) on each.

Each implementation lives on its own branch; `main` is this comparison hub. The numbers below
come from a single machine on the dates noted — see [Methodology](#methodology).

---

## Comparison

|                                    | LocalStack (Hobby)                      | Floci                                                          | MiniStack                                                                                                        |
| ---------------------------------- | --------------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Account / auth token               | required                                | none                                                          | none                                                                                                            |
| Container startup                  | ~4.6–5.4 s                              | < 1 s                                                         | < 2 s                                                                                                          |
| Cold invoke (first call)           | ~4.0 s                                  | ~3.7 s                                                        | ~2.5–2.8 s ¹                                                                                                    |
| Hot-reload                         | ✅ on by default                         | ✅ behind `FLOCI_SERVICES_LAMBDA_HOT_RELOAD_ENABLED`           | ❌ none (in-process worker pool)                                                                                |
| Magic bucket w/ missing code       | works                                   | works                                                         | ⚠️ Create: silent stub (CodeSize 0, `"Mock response - no code deployed"`); Update: loud `InvalidParameterValueException` |
| Warm invoke                        | ~0.56 s                                 | ~1.4 s                                                        | ~0.5 s                                                                                                         |
| Loop after code edit               | ~1.2 s                                  | ~1.4 s                                                        | ~9.2 s ² (rebuild + re-apply + invoke)                                                                          |
| esbuild rebuild                    | ~1–7 ms                                 | ~1–7 ms                                                       | ~1–10 ms                                                                                                       |
| tflocal / OpenTofu v1.11.6         | ✅ / ✅                                   | ✅ / ✅                                                         | ✅ / ✅                                                                                                          |
| Branch-specific gotchas            | host-path mount, macOS File Sharing     | hot-reload flag off by default                               | CRC64NVME checksums unsupported                                                                                 |

¹ MiniStack's first-invoke cost is warm **worker-pool** warming, not container spin-up — it runs
Node.js Lambdas in-process, with no per-function container.

² MiniStack has no hot-reload; the loop is rebuild + `tflocal apply` (~8.7 s) + invoke (~0.5 s).

---

## Methodology

All figures are from **one machine**: macOS on Apple Silicon (arm64), Docker Desktop. Same repo,
same handler, same esbuild config across all three; only the emulator (and the branch's
`docker-compose.yml` / `main.tf` wiring) differs.

Images and measurement dates:

- **LocalStack** — `localstack/localstack:latest`, image ID `24bfb26791eb` (created 2026-04-28).
  Measured **2026-07-13**.
- **Floci** — `floci/floci:latest` (Floci 1.5.30), image ID `51c2a38d394f` (created 2026-07-03).
  Measured **July 2026** (see the [floci branch README](../../tree/floci)).
- **MiniStack** — `ministackorg/ministack:latest`, image ID `65f91ff15e63` (created 2026-06-30).
  Measured **July 2026** (see the [ministack branch README](../../tree/ministack)).

Protocol:

- **Container startup** — `docker compose up -d`, then poll until the Lambda API answers.
- **Warm invoke** — 5 consecutive runs, first (cold) discarded, median of remaining 4 (LocalStack,
  this session; Floci and MiniStack report medians of 6 runs — see their branch READMEs).
- **Loop after code edit** — 6× of: `sed` a unique marker into `src/handlers/hello.ts` →
  `npm run build` → `sleep 2` → timed `npm run invoke`, verifying every invoke returned the new
  marker. For LocalStack and Floci this is a hot-reload cycle (no re-apply); for MiniStack the
  loop includes `tflocal apply` (~8.7 s), since a rebuild alone does nothing until re-deploy.

> **Single machine — your numbers will vary** with hardware, Docker settings, and image version.
> Treat these as relative shapes, not benchmarks.

---

## Branches

Each emulator has a complete, self-contained implementation with its own README, `main.tf`,
and `docker-compose.yml`. `main`'s code is the LocalStack implementation (mirrored on the
`localstack` branch for symmetry).

| Branch                             | What's inside                                                                                  | Clone                                                                    |
| ---------------------------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| [`localstack`](../../tree/localstack) | LocalStack Hobby plan — hot-reload magic bucket, requires an auth token.                        | `git clone -b localstack https://github.com/olegmmv/terraform-lambda-emulator-comparison` |
| [`floci`](../../tree/floci)           | Floci — same magic-bucket hot-reload, no account, hot-reload gated behind an env flag.          | `git clone -b floci https://github.com/olegmmv/terraform-lambda-emulator-comparison`      |
| [`ministack`](../../tree/ministack)   | MiniStack — zip deploy to an in-process worker pool, no hot-reload; rebuild + re-apply to update. | `git clone -b ministack https://github.com/olegmmv/terraform-lambda-emulator-comparison`  |

---

## Findings

**Three reload mechanisms, three inner loops.** The emulators reload code in fundamentally
different ways, and the inner loop follows directly. LocalStack and Floci both implement the
`s3_bucket = "hot-reload"` magic bucket: they bind-mount the host `dist/` into the Lambda
environment and pick up a rebuild on the next invoke, so the edit→invoke loop is roughly one
invoke long (~1.2 s LocalStack, ~1.4 s Floci). MiniStack has no equivalent — it runs Node.js
Lambdas in an in-process warm worker pool that holds the code loaded at deploy time, so a
rebuild does nothing until `tflocal apply` re-deploys the zip, making the loop ~9.2 s
(rebuild + ~8.7 s re-apply + invoke).

**MiniStack's Create-vs-Update inconsistency is the sharpest gotcha.** On MiniStack the
LocalStack magic bucket is just an ordinary — and missing — S3 source, and the two Lambda code
paths disagree about it. `CreateFunction` does **not** validate the source: `tflocal apply` goes
green (`4 added`) but the function has `CodeSize: 0` and invoking it returns a silent stub,
`"Mock response - no code deployed"` — a fake Lambda that looks deployed. `UpdateFunctionCode`
**does** validate, failing loudly with `InvalidParameterValueException: Failed to fetch code from
s3://hot-reload/…`. The ministack branch removes the magic-bucket path entirely and always
deploys a real zip.

**Floci trades startup and account for a costlier invoke.** Floci starts in under a second and
needs no account or auth token, but each warm invoke runs ~1.4 s — noticeably more than
LocalStack's ~0.56 s or MiniStack's ~0.5 s. Its one setup catch is that hot-reload is off by
default: `CreateFunction` on the hot-reload bucket fails with
`InvalidParameterValueException: Hot-reload is disabled.` until
`FLOCI_SERVICES_LAMBDA_HOT_RELOAD_ENABLED=true` is set (already done in the floci branch).

**LocalStack has the shortest measured loop but the heaviest requirements.** Its ~1.2 s
edit→invoke loop and ~0.56 s warm invoke were the lowest of the three here, but it is the only
one that requires an account and a `LOCALSTACK_AUTH_TOKEN`, and it sits on a paid product
trajectory rather than a free/MIT one.

**Observation — both container-backed emulators pay for the first edit.** On LocalStack and
Floci (both of which run each Lambda in a real container), the first invoke *after the first code
change* was more expensive than steady state — ~3.4–3.5 s (LocalStack's first after-edit invoke
was 3.47 s; Floci's after-edit runs ranged 1.38–3.40 s), after which subsequent edits settled to
the steady per-invoke cost (~1.2 s LocalStack, ~1.4 s Floci). This is reported here purely as an
observation from the measurements, without claim as to cause.

---

## License

MIT — see [LICENSE](LICENSE).

<!-- article link -->
