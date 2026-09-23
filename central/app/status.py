from datetime import datetime, timezone

from .config import settings
from .models import Binding, Server

STATUS_OK = "ok"
STATUS_WARNING = "warning"
STATUS_CRITICAL = "critical"
STATUS_EXPIRED = "expired"
STATUS_NO_SSL = "no_ssl"

STATUS_LABELS = {
    STATUS_OK: "Sağlıklı",
    STATUS_WARNING: "Yaklaşıyor",
    STATUS_CRITICAL: "Kritik",
    STATUS_EXPIRED: "Süresi dolmuş",
    STATUS_NO_SSL: "SSL yok",
}


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def days_until(not_after: datetime | None, now: datetime | None = None) -> int | None:
    if not_after is None:
        return None
    current = now or utcnow()
    return (not_after.date() - current.date()).days


def ssl_status(days_remaining: int | None, has_ssl: bool) -> str:
    if not has_ssl or days_remaining is None:
        return STATUS_NO_SSL
    if days_remaining < 0:
        return STATUS_EXPIRED
    if days_remaining <= 7:
        return STATUS_CRITICAL
    if days_remaining <= 30:
        return STATUS_WARNING
    return STATUS_OK


def is_stale(server: Server, now: datetime | None = None) -> bool:
    if not server.last_seen:
        return True
    current = now or utcnow()
    age_hours = (current - server.last_seen).total_seconds() / 3600
    return age_hours > settings.stale_after_hours


def binding_view(binding: Binding, server: Server, now: datetime | None = None) -> dict:
    current = now or utcnow()
    remaining = days_until(binding.not_after, current) if binding.has_ssl else None
    status = ssl_status(remaining, binding.has_ssl)
    return {
        "id": binding.id,
        "server_name": server.hostname,
        "os_type": server.os_type,
        "site_name": binding.site_name,
        "protocol": binding.protocol,
        "ip": binding.ip,
        "port": binding.port,
        "hostname": binding.hostname,
        "binding_text": f"{binding.protocol} {binding.ip}:{binding.port}:{binding.hostname}",
        "has_ssl": binding.has_ssl,
        "cert_subject": binding.cert_subject or "",
        "cert_issuer": binding.cert_issuer or "",
        "fingerprint": binding.fingerprint or "",
        "not_before": binding.not_before,
        "not_after": binding.not_after,
        "san": binding.san or "",
        "days_remaining": remaining,
        "status": status,
        "status_label": STATUS_LABELS[status],
        "stale": is_stale(server, current),
        "last_seen": server.last_seen,
    }
