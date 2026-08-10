import os

OPENAI_API_KEY = os.environ["OPENAI_API_KEY"]
OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o")

RAILS_INTERNAL_API_TOKEN = os.environ["RAILS_INTERNAL_API_TOKEN"]
RAILS_BASE_URL = os.environ["RAILS_BASE_URL"]

MAX_TOOL_ITERATIONS = int(os.environ.get("MAX_TOOL_ITERATIONS", "8"))
RAILS_TOOL_TIMEOUT = int(os.environ.get("RAILS_TOOL_TIMEOUT", "30"))
