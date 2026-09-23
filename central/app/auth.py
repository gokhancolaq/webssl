import secrets

from fastapi import Request

from .config import settings

SESSION_KEY = "webssl_user"


def verify_credentials(username: str, password: str) -> bool:
    user_ok = secrets.compare_digest(username.encode("utf-8"), settings.dashboard_user.encode("utf-8"))
    pass_ok = secrets.compare_digest(password.encode("utf-8"), settings.dashboard_password.encode("utf-8"))
    return user_ok and pass_ok


def verify_agent_token(authorization: str | None, token_header: str | None) -> bool:
    token = ""
    if token_header:
        token = token_header.strip()
    elif authorization:
        scheme, _, value = authorization.partition(" ")
        if scheme.lower() == "bearer" and value:
            token = value.strip()
        else:
            token = authorization.strip()
    if not token:
        return False
    return secrets.compare_digest(token.encode("utf-8"), settings.agent_token.encode("utf-8"))


def is_logged_in(request: Request) -> bool:
    return request.session.get(SESSION_KEY) == settings.dashboard_user


def login_user(request: Request) -> None:
    request.session[SESSION_KEY] = settings.dashboard_user


def logout_user(request: Request) -> None:
    request.session.clear()
