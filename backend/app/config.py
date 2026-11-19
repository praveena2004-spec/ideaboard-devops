"""Environment-based configuration.

Every setting comes from an environment variable so the same container image
can run unchanged in development, staging and production. Nothing secret
(passwords, API keys) has a default value here.
"""
import os

from sqlalchemy.engine import URL


def _bool(name: str, default: bool = False) -> bool:
    return os.getenv(name, str(default)).strip().lower() in {"1", "true", "yes", "on"}


class Settings:
    def __init__(self) -> None:
        # development | staging | production
        self.app_env = os.getenv("APP_ENV", "development")
        # Injected by CI (git SHA) so /api/version shows which release is live.
        self.app_version = os.getenv("APP_VERSION", "dev")

        # Comma-separated list of allowed browser origins (only needed when the
        # frontend is served from a different origin, e.g. `npm run dev`).
        self.cors_origins = [
            o.strip() for o in os.getenv("CORS_ORIGINS", "http://localhost:5173").split(",") if o.strip()
        ]

        # Rollback demo switch: when true, /ready reports unhealthy so a
        # Kubernetes rollout of this "bad release" never becomes ready and the
        # pipeline's rollback path is exercised.
        self.simulate_unhealthy = _bool("SIMULATE_UNHEALTHY")

        # AI settings. With no key set, the app falls back to a rule-based
        # analyzer so the demo still works offline.
        self.anthropic_api_key = os.getenv("ANTHROPIC_API_KEY", "")
        self.ai_model = os.getenv("AI_MODEL", "claude-opus-5-5")
        self.ai_max_log_chars = int(os.getenv("AI_MAX_LOG_CHARS", "200000"))

    @property
    def database_url(self) -> str:
        """DATABASE_URL wins if set; otherwise build it from POSTGRES_* parts."""
        explicit = os.getenv("DATABASE_URL")
        if explicit:
            return explicit
        return URL.create(
            "postgresql+psycopg2",
            username=os.getenv("POSTGRES_USER", "ideaboard"),
            password=os.getenv("POSTGRES_PASSWORD"),  # no default: must be provided
            host=os.getenv("POSTGRES_HOST", "localhost"),
            port=int(os.getenv("POSTGRES_PORT", "5432")),
            database=os.getenv("POSTGRES_DB", "ideaboard"),
        ).render_as_string(hide_password=False)


settings = Settings()
