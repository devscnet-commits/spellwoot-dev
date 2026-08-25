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

# Teto por chamada à OpenAI. Sem isto vale o default do SDK (600s): uma chamada travada segurava uma
# thread do pool do uvicorn por 10 minutos DEPOIS que o Rails (AI_ORCHESTRATOR_TIMEOUT) já tinha
# desistido do turno. OPENAI_MAX_RETRIES é o retry automático do próprio SDK (429/5xx) — 1 em vez do
# default 2 porque cada tentativa extra multiplica o pior caso pelo timeout acima.
OPENAI_TIMEOUT = float(os.environ.get("OPENAI_TIMEOUT", "45"))
OPENAI_MAX_RETRIES = int(os.environ.get("OPENAI_MAX_RETRIES", "1"))
# Orçamento de parede do turno inteiro: passado disto o orquestrador para de abrir RODADA NOVA de
# ferramenta e vai fechar a resposta com o que já tem. Existe porque o Rails abandona o POST em
# AI_ORCHESTRATOR_TIMEOUT e força handoff, enquanto o Python seguia trabalhando num turno que, para o
# cliente, nunca aconteceu — salvando dado, avançando etapa e até transferindo sozinho. Mantenha
# SEMPRE menor que o AI_ORCHESTRATOR_TIMEOUT do Rails.
TURN_BUDGET = float(os.environ.get("TURN_BUDGET_SECONDS", "90"))

# INFO (default) keeps only the short per-turn signal (reply sent, which tool was called/with what
# result) — enough to follow along without wading through the full prompt/raw-response dump. Set to
# DEBUG (env var, no code change) when actively investigating a bug: unlocks the full system_prompt,
# tools_schema, create_kwargs and raw OpenAI response on every turn (orchestrator.py/main.py).
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
