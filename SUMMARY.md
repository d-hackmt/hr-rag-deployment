# Session handoff — HR Policy Assistant

Handoff notes for the next Claude session. Focus: **deployment**. For how the
app itself works, read [`README.md`](README.md) and [`docs/`](docs/).

Repo: `github.com/d-hackmt/hr-rag-deployment` · branch `main`

---

## 1. What this project is (30 seconds)

A RAG chatbot answering employee questions about `data/hr_policy.txt`.
LangChain agent + `search_hr_policy` tool → retrieval from **Qdrant Cloud** →
LLM (`openai/gpt-oss-20b` on Groq) routed through the **Portkey** gateway →
input/output **guardrails** (separate Groq safeguard model) → LangSmith
tracing + evals. Runs as a **Streamlit** app on port **8501**
([`app.py`](app.py)); CLI demo is [`main.py`](main.py); eval is
[`evaluate.py`](evaluate.py). Containerised ([`Dockerfile`](Dockerfile),
[`docker-compose.yml`](docker-compose.yml)).

---

## 2. Deployment — current state

**Nothing is deployed to any cloud yet.** The CI/CD *code* is written and
locally validated (YAML parses, `remote.sh` passes `bash -n`, the `envsubst`
render was tested). The one-time AWS setup has **not** been run, and the
required GitHub secrets/variables are **not** set. First push to `main` will
run the workflow and it will fail at the AWS auth step until setup is done.

### Target architecture (already coded)

```
git push main
  └─ GitHub Actions (.github/workflows/deploy.yml)
       1. OIDC → assume IAM role  (no AWS keys stored in GitHub)
       2. docker build → push to Amazon ECR   (tags: <git-sha> + latest)
       3. write runtime .env → AWS SSM Parameter Store (SecureString)
       4. SSM send-command → EC2 runs deploy/remote.sh:
            docker login ECR → pull .env from Parameter Store → docker pull
            → docker rm -f + docker run -p 8501:8501 → curl /_stcore/health
  └─ live at  http://<EC2 public IP>:8501
```

No SSH anywhere — GitHub talks to the box through AWS SSM.

### Files that implement it

| File | Purpose | Status |
|---|---|---|
| [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) | The pipeline (6 steps, one job) | written, untested against real AWS |
| [`deploy/remote.sh`](deploy/remote.sh) | Runs **on** the EC2 box, delivered via SSM | written, `bash -n` clean |
| [`docs/09_cicd_aws_ecr_ec2.md`](docs/09_cicd_aws_ecr_ec2.md) | Full teaching doc: concepts, every setup step explained, workflow walkthrough, day-to-day ops, troubleshooting | complete |
| [`docs/cicd_commands.md`](docs/cicd_commands.md) | Copy-paste AWS CLI flow for the one-time setup + teardown | complete |

### What still has to happen (in order)

1. **Run the one-time AWS setup** — [`docs/cicd_commands.md`](docs/cicd_commands.md)
   steps 0–7. Creates: ECR repo `hr-assistant`, GitHub OIDC provider, IAM role
   `github-actions-hr-assistant`, EC2 instance profile `hr-assistant-ec2`,
   security group (inbound 8501 only), a `t3.micro` EC2 running Amazon Linux
   2023 with Docker, and seeds the runtime env into SSM Parameter Store
   `/hr-assistant/env`. Region in the code is **`eu-west-2`** — change it in
   both the docs and [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml#L18)
   if a different region is wanted.
2. **Set GitHub secrets/variables** — repo → Settings → Secrets and variables
   → Actions:
   - Secret `AWS_ROLE_ARN` = `arn:aws:iam::<ACCT>:role/github-actions-hr-assistant`
   - Secret `APP_ENV_FILE` = full contents of `.env.docker` (strict format,
     **must include the `:443` on `QDRANT_URL`** — see §3)
   - Variable `EC2_INSTANCE_ID` = the `i-0...` id
3. **Push** — commit + `git push origin main`, watch the Actions tab.
4. **Verify** — `curl http://<public-ip>:8501/_stcore/health` → `200`.

### Decisions already made (don't re-litigate without reason)

- Compute: **EC2 + Docker** (not ECS/App Runner) — cheapest, simplest, Free
  Tier friendly.
- Auth: **GitHub OIDC → IAM role** — no long-lived AWS keys in GitHub.
- Runtime secrets: **GitHub secret `APP_ENV_FILE` → SSM Parameter Store →
  instance reads at deploy time**. Secrets never appear in Actions logs.
- No SSH / no port 22 — **AWS SSM** for both deploy and shell access
  (`aws ssm start-session --target <id>`).

---

## 3. CRITICAL gotcha — Qdrant port `:443`

`qdrant-client` defaults to REST port **6333**, which is **blocked on many
networks** (symptom: `ResponseHandlingException: [WinError 10054] ... forcibly
closed` / "connection reset"). Qdrant Cloud also serves on **443**.

**Every `QDRANT_URL` must end in `:443`** — the local `.env`, `.env.docker`,
the `APP_ENV_FILE` GitHub secret, and the SSM parameter. This was fixed
locally this session (`.env` and `.env.docker` both updated) but `.env` is
gitignored, so it is **not** in the repo — anyone cloning fresh must add it.

Example: `QDRANT_URL=https://<cluster>.eu-west-2-0.aws.cloud.qdrant.io:443`

---

## 4. Runtime env vars (names only — values are in local `.env` / `.env.docker`)

`config.check_api_keys()` hard-fails if any of the first five are missing:

| Var | Used by |
|---|---|
| `PORTKEY_API_KEY` | main LLM (via gateway) |
| `GROQ_API_KEY` | guardrail safeguard model (called **directly**, not via Portkey) |
| `JINA_API_KEY` | embeddings |
| `QDRANT_URL` | vector store — **needs `:443`** |
| `QDRANT_API_KEY` | vector store |
| `QDRANT_COLLECTION_NAME` | defaults to `hr_policy` |
| `LANGSMITH_TRACING` / `_ENDPOINT` / `_API_KEY` / `_PROJECT` | tracing + eval (optional; set `LANGSMITH_TRACING=false` to disable) |

`.env` (local, python-dotenv, tolerant format) and `.env.docker` (strict
`KEY=value` for `docker run --env-file`) currently hold identical values —
verified this session. `docker compose` uses `.env` directly.

---

## 5. Uncommitted work in this session (about to be pushed)

- `.gitignore` — added `hrenv/`, `ragenv/`
- `.dockerignore` — added `hrenv/`, `ragenv/`, `SUMMARY.md`, `deploy/`, `.github/`
- `.github/workflows/deploy.yml` — **new**
- `deploy/remote.sh` — **new**
- `docs/09_cicd_aws_ecr_ec2.md`, `docs/cicd_commands.md` — **new**
- `SUMMARY.md` — this file

Already in the `first commit` (7d36514): the rewritten `README.md` and the
`document_loader.py` import cleanup.

---

## 6. Known issues / smaller notes

- **`python main.py` on Windows** can end with `UnicodeEncodeError` (`‑`)
  when the console codepage is `cp1252`. Console-only, does **not** affect
  Streamlit or Docker. Fix: run with `PYTHONUTF8=1`.
- Local venv `hrenv/` is **Python 3.14**; stray `__pycache__` shows 3.11/3.13
  from earlier. Harmless; `hrenv/` is now gitignored.
- `rag.ipynb` has diverged from the `hr_assistant/` package (local FAISS,
  `openai/gpt-oss-120b`, no guardrails/gateway). It's a teaching artifact, not
  the app — don't treat it as source of truth.
- `app.py` title `"HR Policy Assistantttttttttt"` is intentional (per repo owner).

---

## 7. Suggested next actions for the incoming session

1. Ask the user whether the AWS account + region are decided, then walk
   [`docs/cicd_commands.md`](docs/cicd_commands.md) with them.
2. After the first successful deploy, consider the assignments in
   [`docs/09_cicd_aws_ecr_ec2.md`](docs/09_cicd_aws_ecr_ec2.md) §11 —
   especially a pre-deploy test gate and HTTPS via Caddy (it's currently
   plain `http` on `:8501`).
3. If the user wants GCP instead of AWS later: the OIDC pattern and the
   build→push→pull→restart shape port directly; swap ECR→Artifact Registry,
   EC2/SSM→Cloud Run.
