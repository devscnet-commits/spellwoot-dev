import os

# config.py reads these from os.environ at IMPORT time (raises KeyError if missing) — set safe
# dummy values before any test module imports orchestrator/config, so `pytest` works standalone
# without needing a real .env. setdefault: a real .env loaded by config.py's own load_dotenv()
# (e.g. running inside the dev container) still wins if already present in the environment.
os.environ.setdefault("OPENAI_API_KEY", "test-key")
os.environ.setdefault("RAILS_INTERNAL_API_TOKEN", "test-token")
os.environ.setdefault("RAILS_BASE_URL", "http://rails.test")
