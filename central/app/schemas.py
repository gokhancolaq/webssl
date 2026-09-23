from datetime import datetime

from pydantic import BaseModel, Field


class BindingIn(BaseModel):
    site_name: str = ""
    protocol: str = "http"
    ip: str = "*"
    port: int = 80
    hostname: str = ""
    has_ssl: bool = False
    cert_subject: str | None = None
    cert_issuer: str | None = None
    fingerprint: str | None = None
    not_before: datetime | None = None
    not_after: datetime | None = None
    san: list[str] | str | None = None


class IngestPayload(BaseModel):
    hostname: str = Field(min_length=1)
    os_type: str = "unknown"
    collected_at: datetime | None = None
    agent_version: str = ""
    bindings: list[BindingIn] = Field(default_factory=list)
