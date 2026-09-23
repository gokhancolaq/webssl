from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

ROOT_DIR = Path(__file__).resolve().parents[2]
CENTRAL_DIR = Path(__file__).resolve().parents[1]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(ROOT_DIR / ".env", CENTRAL_DIR / ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    dashboard_user: str = "admin"
    dashboard_password: str = "changeme"
    agent_token: str = "changeme-token"
    secret_key: str = "change-this-secret-key"
    database_url: str = f"sqlite:///{(CENTRAL_DIR / 'webssl.db').as_posix()}"
    host: str = "0.0.0.0"
    port: int = 8080
    stale_after_hours: int = 24


settings = Settings()
