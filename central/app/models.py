from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


class Server(Base):
    __tablename__ = "servers"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    hostname: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    os_type: Mapped[str] = mapped_column(String(32), default="unknown")
    agent_version: Mapped[str] = mapped_column(String(64), default="")
    last_seen: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    collected_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

    bindings: Mapped[list["Binding"]] = relationship(
        "Binding",
        back_populates="server",
        cascade="all, delete-orphan",
    )


class Binding(Base):
    __tablename__ = "bindings"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    server_id: Mapped[int] = mapped_column(ForeignKey("servers.id", ondelete="CASCADE"), index=True)
    site_name: Mapped[str] = mapped_column(String(255), default="")
    protocol: Mapped[str] = mapped_column(String(16), default="http")
    ip: Mapped[str] = mapped_column(String(128), default="*")
    port: Mapped[int] = mapped_column(Integer, default=80)
    hostname: Mapped[str] = mapped_column(String(255), default="")
    has_ssl: Mapped[bool] = mapped_column(Boolean, default=False)
    cert_subject: Mapped[str | None] = mapped_column(Text, nullable=True)
    cert_issuer: Mapped[str | None] = mapped_column(Text, nullable=True)
    fingerprint: Mapped[str | None] = mapped_column(String(128), nullable=True)
    not_before: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    not_after: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    san: Mapped[str | None] = mapped_column(Text, nullable=True)
    days_remaining: Mapped[int | None] = mapped_column(Integer, nullable=True)

    server: Mapped[Server] = relationship("Server", back_populates="bindings")
