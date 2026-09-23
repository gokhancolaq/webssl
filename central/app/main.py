from datetime import datetime
from pathlib import Path

from fastapi import Depends, FastAPI, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import delete, select
from sqlalchemy.orm import Session
from starlette.middleware.sessions import SessionMiddleware

from .auth import is_logged_in, login_user, logout_user, verify_agent_token, verify_credentials
from .config import settings
from .db import Base, engine, get_db
from .models import Binding, Server
from .schemas import IngestPayload
from .status import STATUS_LABELS, binding_view, days_until, is_stale, utcnow

APP_DIR = Path(__file__).resolve().parent

app = FastAPI(title="WEBSSL", docs_url=None, redoc_url=None)
app.add_middleware(SessionMiddleware, secret_key=settings.secret_key, max_age=60 * 60 * 12, same_site="lax")
app.mount("/static", StaticFiles(directory=APP_DIR / "static"), name="static")
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))
templates.env.filters["dt"] = lambda value: value.strftime("%Y-%m-%d %H:%M") if value else "—"
templates.env.filters["date"] = lambda value: value.strftime("%Y-%m-%d") if value else "—"


@app.on_event("startup")
def on_startup() -> None:
    Base.metadata.create_all(bind=engine)


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request, next: str = "/") -> HTMLResponse:
    if is_logged_in(request):
        return RedirectResponse(url=next, status_code=303)
    return templates.TemplateResponse(request, "login.html", {"error": None, "next": next})


@app.post("/login", response_model=None)
def login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    next: str = Form("/"),
):
    if verify_credentials(username, password):
        login_user(request)
        target = next if next.startswith("/") else "/"
        return RedirectResponse(url=target, status_code=303)
    return templates.TemplateResponse(
        request,
        "login.html",
        {"error": "Kullanıcı adı veya şifre hatalı.", "next": next},
        status_code=401,
    )


@app.post("/logout")
def logout(request: Request) -> RedirectResponse:
    logout_user(request)
    return RedirectResponse(url="/login", status_code=303)


@app.get("/", response_class=HTMLResponse)
def dashboard(
    request: Request,
    db: Session = Depends(get_db),
    q: str = Query(""),
    server: str = Query(""),
    status: str = Query(""),
) -> HTMLResponse:
    if not is_logged_in(request):
        return RedirectResponse(url="/login", status_code=303)

    now = utcnow()
    servers = list(db.scalars(select(Server).order_by(Server.hostname)).all())
    rows = [binding_view(binding, binding.server, now) for binding in db.scalars(select(Binding)).all()]

    stale_servers = [item for item in servers if is_stale(item, now)]
    unique_sites = {(row["server_name"], row["site_name"]) for row in rows if row["site_name"]}
    expiring = [row for row in rows if row["status"] in {"warning", "critical"}]
    expired = [row for row in rows if row["status"] == "expired"]

    filtered = rows
    if q:
        needle = q.lower()
        filtered = [
            row
            for row in filtered
            if needle in row["server_name"].lower()
            or needle in row["site_name"].lower()
            or needle in row["hostname"].lower()
            or needle in row["cert_subject"].lower()
            or needle in row["fingerprint"].lower()
            or needle in row["binding_text"].lower()
        ]
    if server:
        filtered = [row for row in filtered if row["server_name"] == server]
    if status == "stale":
        filtered = [row for row in filtered if row["stale"]]
    elif status:
        filtered = [row for row in filtered if row["status"] == status]

    status_order = {"expired": 0, "critical": 1, "warning": 2, "no_ssl": 3, "ok": 4}
    filtered.sort(
        key=lambda row: (
            status_order.get(row["status"], 9),
            row["days_remaining"] if row["days_remaining"] is not None else 10_000,
            row["server_name"],
            row["site_name"],
        )
    )

    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {
            "rows": filtered,
            "servers": servers,
            "q": q,
            "selected_server": server,
            "selected_status": status,
            "status_labels": STATUS_LABELS,
            "summary": {
                "sites": len(unique_sites),
                "bindings": len(rows),
                "expiring": len(expiring),
                "expired": len(expired),
                "stale": len(stale_servers),
                "servers": len(servers),
            },
            "now": now,
        },
    )


@app.post("/api/ingest")
def ingest(
    payload: IngestPayload,
    request: Request,
    db: Session = Depends(get_db),
) -> dict:
    if not verify_agent_token(request.headers.get("authorization"), request.headers.get("x-agent-token")):
        raise HTTPException(status_code=401, detail="Geçersiz agent token")

    now = utcnow()
    hostname = payload.hostname.strip()
    server = db.scalar(select(Server).where(Server.hostname == hostname))
    if server is None:
        server = Server(hostname=hostname)
        db.add(server)
        db.flush()

    server.os_type = (payload.os_type or "unknown").lower()
    server.agent_version = payload.agent_version or ""
    server.last_seen = now
    server.collected_at = payload.collected_at or now

    db.execute(delete(Binding).where(Binding.server_id == server.id))

    for item in payload.bindings:
        san = item.san
        if isinstance(san, list):
            san_text = ", ".join(name for name in san if name)
        else:
            san_text = san
        remaining = days_until(item.not_after, now) if item.has_ssl else None
        db.add(
            Binding(
                server_id=server.id,
                site_name=item.site_name or item.hostname or "",
                protocol=(item.protocol or "http").lower(),
                ip=item.ip or "*",
                port=item.port,
                hostname=item.hostname or "",
                has_ssl=item.has_ssl,
                cert_subject=item.cert_subject,
                cert_issuer=item.cert_issuer,
                fingerprint=item.fingerprint,
                not_before=_naive(item.not_before),
                not_after=_naive(item.not_after),
                san=san_text,
                days_remaining=remaining,
            )
        )

    db.commit()
    return {"ok": True, "hostname": server.hostname, "bindings": len(payload.bindings)}


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "time": utcnow().isoformat(timespec="seconds")}


def _naive(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is not None:
        return value.replace(tzinfo=None)
    return value
