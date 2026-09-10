# HR Policy Assistant (RAG)

A retrieval-augmented generation (RAG) chatbot that answers employee questions
about a company's HR policy document. Built with LangChain, a Groq-hosted LLM
routed through the Portkey gateway, Jina embeddings, and a Qdrant Cloud vector
store, with input/output safety guardrails, LangSmith tracing, and a LangSmith
evaluation suite.

## How it works

1. **Ingest** — [`hr_assistant/document_loader.py`](hr_assistant/document_loader.py)
   loads `data/hr_policy.txt`, and [`hr_assistant/splitter.py`](hr_assistant/splitter.py)
   splits it into chunks (`CHUNK_SIZE=500`, `CHUNK_OVERLAP=60`).
2. **Embed & store** — [`hr_assistant/embeddings.py`](hr_assistant/embeddings.py)
   creates embeddings with Jina (`jina-embeddings-v2-base-en`), and
   [`hr_assistant/vector_store.py`](hr_assistant/vector_store.py) uploads them to
   a Qdrant Cloud collection. On later runs the existing collection is reused
   (checked by name) instead of re-embedding.
3. **Retrieve** — [`hr_assistant/tools.py`](hr_assistant/tools.py) wraps the
   vector store retriever (top-k = 3) as a `search_hr_policy` tool.
4. **LLM via gateway** — [`hr_assistant/gateway.py`](hr_assistant/gateway.py) /
   [`hr_assistant/llm.py`](hr_assistant/llm.py) build a `ChatOpenAI` pointed at
   the Portkey gateway, routed through the `@hrpolicy` provider slug (the real
   Groq key lives in Portkey, not in this repo). Model: `openai/gpt-oss-20b`.
   There is no Portkey-side fallback — see
   [`docs/05_portkey_gateway.md`](docs/05_portkey_gateway.md).
5. **Agent** — [`hr_assistant/agent.py`](hr_assistant/agent.py) builds a
   LangChain agent (`create_agent`) that calls the search tool to ground its
   answers.
6. **Guardrails** — [`hr_assistant/guardrails.py`](hr_assistant/guardrails.py)
   runs a separate Groq safety model (`openai/gpt-oss-safeguard-20b`, called
   **directly**, not through Portkey) to screen both the incoming question
   (prompt injection, requests for other employees' data) and the outgoing
   answer (PII leaks, unauthorized promises, suspicious links/credentials)
   before it reaches the user. A blocked request returns a fixed refusal
   message.
7. **Wiring** — [`hr_assistant/pipeline.py`](hr_assistant/pipeline.py)
   (`build_hr_assistant()` / `ask()`) ties every step together and is the
   single entry point the CLI, the Streamlit app, and the evaluation all call.

Cross-cutting: [`hr_assistant/logger.py`](hr_assistant/logger.py) writes one log
file per run under `logs/`, and [`hr_assistant/tracing.py`](hr_assistant/tracing.py)
logs (once per run) whether LangSmith tracing is on. Tracing itself is driven
entirely by the `LANGSMITH_*` env vars — no code change needed to toggle it.

## Entry points

- `python main.py` — CLI demo that asks a few sample HR questions.
- `streamlit run app.py` — interactive chat UI.
- `python evaluate.py` — run the correctness + groundedness evaluation and
  upload a LangSmith experiment (see [`docs/06_evaluations.md`](docs/06_evaluations.md)).
- `rag.ipynb` — standalone notebook version (uses local FAISS + `openai/gpt-oss-120b`
  directly; kept for experimentation, has drifted from the package).

## Project layout

```
hr_assistant/
  config.py           settings, env vars, system prompt, check_api_keys()
  logger.py           shared per-run file logger (logs/)
  tracing.py          logs whether LangSmith tracing is enabled
  document_loader.py  load the HR policy text file
  splitter.py         chunk the document
  embeddings.py       Jina embeddings model
  vector_store.py     Qdrant Cloud build / load / exists / retriever
  tools.py            search_hr_policy tool for the agent
  gateway.py          Portkey-routed ChatOpenAI (@hrpolicy slug)
  llm.py              get_llm() -> gateway LLM
  agent.py            LangChain agent construction
  guardrails.py       input/output safety checks (Groq safeguard model)
  evaluation.py       LangSmith dataset + correctness/groundedness judges
  pipeline.py         build_hr_assistant(), ask() — wires everything
main.py               CLI demo
app.py                Streamlit chat UI
evaluate.py           runs the evaluation
data/hr_policy.txt    source HR policy document (demo "Acme Corp" handbook)
docs/                 branch-by-branch notes (see below)
NOTES/                reference PDFs
Dockerfile            app image (uv install, runs Streamlit on 8501)
docker-compose.yml    app service + on-demand eval job
```

### docs/

| File | Topic |
|------|-------|
| [`01_logger.md`](docs/01_logger.md) | Per-run file logging |
| [`02_langsmith.md`](docs/02_langsmith.md) | LangSmith tracing |
| [`04_qdrant_cloud.md`](docs/04_qdrant_cloud.md) | Moving the vector store to Qdrant Cloud |
| [`05_portkey_gateway.md`](docs/05_portkey_gateway.md) | Routing the LLM through Portkey (and why there's no fallback) |
| [`06_evaluations.md`](docs/06_evaluations.md) | LangSmith datasets + LLM-as-judge experiments |
| [`07_docker.md`](docs/07_docker.md) / [`docker_commands.md`](docs/docker_commands.md) | Docker basics + full command flow |
| [`08_docker_compose.md`](docs/08_docker_compose.md) / [`docker_compose_commands.md`](docs/docker_compose_commands.md) | Docker Compose + full command flow |
| [`prompt_injection_findings.md`](docs/prompt_injection_findings.md) / [`attack_test_results.md`](docs/attack_test_results.md) | Guardrail attack testing |

## Setup

1. Install [uv](https://github.com/astral-sh/uv):
   ```
   pip install uv
   ```
2. Create and activate a virtual environment:
   ```
   uv venv hrenv
   hrenv\Scripts\activate
   ```
3. Install dependencies:
   ```
   uv pip install -r requirements.txt
   ```
4. Create a `.env` file (see the variables below).
5. Run it:
   ```
   streamlit run app.py
   ```

## Environment variables

`config.py` calls `load_dotenv()`, so a `.env` file in the repo root is enough.
`check_api_keys()` fails fast if any of `GROQ_API_KEY`, `JINA_API_KEY`,
`QDRANT_URL`, `QDRANT_API_KEY`, or `PORTKEY_API_KEY` is missing.

```
# Main LLM — routed through Portkey; Portkey holds the real Groq key.
PORTKEY_API_KEY=...

# Groq — used DIRECTLY by the guardrail safety model (not via Portkey).
GROQ_API_KEY=...

# Embeddings
JINA_API_KEY=...

# Vector store — Qdrant Cloud.
# NOTE: append :443 to the URL. qdrant-client defaults to port 6333, which is
# blocked on many networks; Qdrant Cloud serves the same API on 443.
QDRANT_URL=https://<cluster-id>.<region>.aws.cloud.qdrant.io:443
QDRANT_API_KEY=...
QDRANT_COLLECTION_NAME=hr_policy

# LangSmith tracing — set LANGSMITH_TRACING=false to turn tracing off entirely.
LANGSMITH_TRACING=false
LANGSMITH_ENDPOINT=https://api.smith.langchain.com
LANGSMITH_API_KEY=...
LANGSMITH_PROJECT=hr_policy_assistant
```

Keep `.env` out of version control. Do not commit real keys.

## Docker

```
# build + run the Streamlit app
docker compose up -d app          # http://localhost:8501

# run the evaluation once (on-demand job, hidden behind a profile)
docker compose run eval

# tear down
docker compose down
```

Compose loads `.env` directly. For a plain `docker run --env-file`, Docker's
parser is stricter than python-dotenv (no spaces/quotes around `=`) — generate
a clean copy first; see [`docs/07_docker.md`](docs/07_docker.md).

## Known issues / notes

- **Qdrant port** — see the `QDRANT_URL` note above; without `:443` you get
  `[WinError 10054] connection forcibly closed` / connection reset.
- **`python main.py` on Windows** can end with `UnicodeEncodeError` when the
  model emits a non-ASCII dash and the console codepage is `cp1252`. Run with
  `PYTHONUTF8=1` or `set PYTHONIOENCODING=utf-8`. Does not affect Streamlit.
- **`rag.ipynb`** has diverged from `hr_assistant/` (local FAISS, different
  model, no guardrails/gateway) — it's a teaching artifact, not the app.
```
