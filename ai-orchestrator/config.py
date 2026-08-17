import os

from dotenv import load_dotenv

# No-op in Docker (env vars already come from env_file); picks up ai-orchestrator/.env when
# running uvicorn directly on the host (venv workflow).
load_dotenv()

OPENAI_API_KEY = os.environ["OPENAI_API_KEY"]
OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o")

RAILS_INTERNAL_API_TOKEN = os.environ["RAILS_INTERNAL_API_TOKEN"]
RAILS_BASE_URL = os.environ["RAILS_BASE_URL"]

MAX_TOOL_ITERATIONS = int(os.environ.get("MAX_TOOL_ITERATIONS", "8"))
RAILS_TOOL_TIMEOUT = int(os.environ.get("RAILS_TOOL_TIMEOUT", "30"))

# INFO (default) keeps only the short per-turn signal (reply sent, which tool was called/with what
# result) — enough to follow along without wading through the full prompt/raw-response dump. Set to
# DEBUG (env var, no code change) when actively investigating a bug: unlocks the full system_prompt,
# tools_schema, create_kwargs and raw OpenAI response on every turn (orchestrator.py/main.py).
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
