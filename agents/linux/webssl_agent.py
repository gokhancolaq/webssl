#!/usr/bin/env python3
"""Collect nginx bindings and SSL certificate expiry, then post them to WEBSSL."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

AGENT_VERSION = "1.0.0"


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_config(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def run_nginx_t() -> str:
    for command in (["nginx", "-T"], ["nginx", "-T", "-q"]):
        try:
            result = subprocess.run(command, check=False, capture_output=True, text=True)
        except FileNotFoundError:
            continue
        output = (result.stdout or "") + "\n" + (result.stderr or "")
        if "server {" in output or "server{" in output:
            return output
    raise RuntimeError("nginx -T failed or nginx is not installed.")


def extract_server_blocks(config_text: str) -> list[str]:
    blocks: list[str] = []
    for match in re.finditer(r"\bserver\s*\{", config_text):
        start = match.end() - 1
        depth = 0
        for index in range(start, len(config_text)):
            char = config_text[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    blocks.append(config_text[start + 1 : index])
                    break
    return blocks


def strip_comments(block: str) -> str:
    lines = []
    for line in block.splitlines():
        stripped = line.split("#", 1)[0].strip()
        if stripped:
            lines.append(stripped)
    return "\n".join(lines)


def parse_listen(value: str) -> tuple[str, int, bool]:
    tokens = value.split()
    address = tokens[0] if tokens else "80"
    ssl_enabled = any(token.lower() == "ssl" for token in tokens[1:]) or address.endswith("ssl")
    ip = "*"
    port = 80
    if address.startswith("[") and "]" in address:
        ipv6, _, remainder = address[1:].partition("]")
        ip = f"[{ipv6}]"
        port = int(remainder[1:]) if remainder.startswith(":") and remainder[1:].isdigit() else 443 if ssl_enabled else 80
    elif ":" in address:
        host, port_text = address.rsplit(":", 1)
        ip = host or "*"
        port = int(port_text) if port_text.isdigit() else 80
    elif address.isdigit():
        port = int(address)
        ssl_enabled = ssl_enabled or port == 443
    else:
        ip = address
        port = 443 if ssl_enabled else 80
    if port == 443:
        ssl_enabled = True
    return ip, port, ssl_enabled


def directive_values(block: str, name: str) -> list[str]:
    pattern = re.compile(rf"^{re.escape(name)}\s+(.+?);$", re.MULTILINE)
    return [match.group(1).strip() for match in pattern.finditer(block)]


def first_directive(block: str, name: str) -> str | None:
    values = directive_values(block, name)
    return values[0] if values else None


def load_certificate(path: str) -> dict | None:
    cert_path = Path(path)
    if not cert_path.is_file():
        return None
    data = cert_path.read_bytes()
    try:
        from cryptography import x509
        from cryptography.hazmat.backends import default_backend
        from cryptography.x509.oid import ExtensionOID, NameOID
    except ImportError:
        return load_certificate_openssl(cert_path)

    cert = None
    for loader in (x509.load_pem_x509_certificate, x509.load_der_x509_certificate):
        try:
            cert = loader(data, default_backend())
            break
        except ValueError:
            continue
    if cert is None:
        return None

    def name_to_text(name: x509.Name) -> str:
        common = name.get_attributes_for_oid(NameOID.COMMON_NAME)
        if common:
            return f"CN={common[0].value}"
        return name.rfc4514_string()

    san: list[str] = []
    try:
        ext = cert.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME)
        san = list(ext.value.get_values_for_type(x509.DNSName))
    except Exception:
        san = []

    fingerprint = cert.fingerprint(hashlib.sha1()).hex().upper()
    fingerprint = ":".join(fingerprint[i : i + 2] for i in range(0, len(fingerprint), 2))
    return {
        "cert_subject": name_to_text(cert.subject),
        "cert_issuer": name_to_text(cert.issuer),
        "fingerprint": fingerprint,
        "not_before": _cert_iso(cert, "not_valid_before_utc", "not_valid_before"),
        "not_after": _cert_iso(cert, "not_valid_after_utc", "not_valid_after"),
        "san": san,
    }


def _cert_iso(cert, utc_attr: str, legacy_attr: str) -> str:
    value = getattr(cert, utc_attr) if hasattr(cert, utc_attr) else getattr(cert, legacy_attr)
    if getattr(value, "tzinfo", None) is not None:
        value = value.replace(tzinfo=None)
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def load_certificate_openssl(path: Path) -> dict | None:
    try:
        result = subprocess.run(
            ["openssl", "x509", "-in", str(path), "-noout", "-subject", "-issuer", "-dates", "-fingerprint", "-ext", "subjectAltName"],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return None
    if result.returncode != 0:
        return None
    info: dict = {"san": []}
    for line in (result.stdout or "").splitlines():
        if line.startswith("subject="):
            info["cert_subject"] = line.split("=", 1)[1].strip()
        elif line.startswith("issuer="):
            info["cert_issuer"] = line.split("=", 1)[1].strip()
        elif line.startswith("notBefore="):
            info["not_before"] = _openssl_date(line.split("=", 1)[1].strip())
        elif line.startswith("notAfter="):
            info["not_after"] = _openssl_date(line.split("=", 1)[1].strip())
        elif line.startswith("SHA1 Fingerprint=") or line.startswith("Fingerprint="):
            info["fingerprint"] = line.split("=", 1)[1].strip()
        elif "DNS:" in line:
            info["san"] = [part.split("DNS:", 1)[1].strip() for part in line.split(",") if "DNS:" in part]
    return info if info.get("not_after") else None


def _openssl_date(value: str) -> str:
    parsed = datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    return parsed.strftime("%Y-%m-%dT%H:%M:%SZ")


def collect_bindings() -> list[dict]:
    text = run_nginx_t()
    bindings: list[dict] = []
    seen: set[tuple] = set()
    for raw_block in extract_server_blocks(text):
        block = strip_comments(raw_block)
        server_names = []
        for value in directive_values(block, "server_name"):
            server_names.extend(part for part in value.split() if part and part != "_")
        if not server_names:
            server_names = [""]
        cert_path = first_directive(block, "ssl_certificate")
        cert_info = load_certificate(cert_path) if cert_path else None
        listens = directive_values(block, "listen") or ["80"]
        for listen in listens:
            ip, port, ssl_enabled = parse_listen(listen)
            has_ssl = ssl_enabled or bool(cert_info and port == 443)
            for hostname in server_names:
                key = (ip, port, hostname, "https" if has_ssl else "http")
                if key in seen:
                    continue
                seen.add(key)
                row = {
                    "site_name": hostname or server_names[0] or f"{ip}:{port}",
                    "protocol": "https" if has_ssl else "http",
                    "ip": ip,
                    "port": port,
                    "hostname": hostname,
                    "has_ssl": has_ssl,
                    "cert_subject": None,
                    "cert_issuer": None,
                    "fingerprint": None,
                    "not_before": None,
                    "not_after": None,
                    "san": [],
                }
                if has_ssl and cert_info:
                    row.update(cert_info)
                bindings.append(row)
    return bindings


def post_ingest(url: str, token: str, payload: dict) -> dict:
    request = urllib.request.Request(
        url.rstrip("/") + "/api/ingest",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "X-Agent-Token": token,
        },
        method="POST",
    )
    context = ssl.create_default_context() if url.lower().startswith("https://") else None
    try:
        with urllib.request.urlopen(request, timeout=30, context=context) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"ingest HTTP {exc.code}: {body}") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description="WEBSSL nginx agent")
    parser.add_argument("--central-url", default=os.environ.get("CENTRAL_URL"))
    parser.add_argument("--agent-token", default=os.environ.get("AGENT_TOKEN"))
    parser.add_argument("--config", default=str(Path(__file__).with_name("agent.config.json")))
    args = parser.parse_args()

    config = load_config(Path(args.config))
    central_url = args.central_url or config.get("CentralUrl") or config.get("central_url")
    agent_token = args.agent_token or config.get("AgentToken") or config.get("agent_token")
    if not central_url or not agent_token:
        print("CENTRAL_URL and AGENT_TOKEN are required.", file=sys.stderr)
        return 2

    payload = {
        "hostname": socket.gethostname(),
        "os_type": "linux",
        "collected_at": utc_now_iso(),
        "agent_version": AGENT_VERSION,
        "bindings": collect_bindings(),
    }
    result = post_ingest(central_url, agent_token, payload)
    print(f"WEBSSL ingest OK: {result.get('hostname')} bindings={result.get('bindings')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
