#!/usr/bin/env bash
# WEBSSL merkezi dashboard — Ubuntu Server kurulum script'i
# Kullanım (root): sudo bash /opt/webssl/scripts/install-ubuntu.sh
set -euo pipefail

APP_ROOT="/opt/webssl"
CENTRAL="${APP_ROOT}/central"
ENV_FILE="${APP_ROOT}/.env"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Bu script root olarak çalışmalı: sudo bash $0"
  exit 1
fi

if [[ ! -f "${CENTRAL}/requirements.txt" ]]; then
  echo "Proje ${APP_ROOT} altında değil. Önce dosyaları kopyalayın."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip git

id -u webssl >/dev/null 2>&1 || useradd --system --home "${APP_ROOT}" --shell /usr/sbin/nologin webssl

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${APP_ROOT}/.env.example" "${ENV_FILE}"
  SECRET="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
  TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
)"
  sed -i "s|^SECRET_KEY=.*|SECRET_KEY=${SECRET}|" "${ENV_FILE}"
  sed -i "s|^AGENT_TOKEN=.*|AGENT_TOKEN=${TOKEN}|" "${ENV_FILE}"
  echo
  echo "Yeni .env yazıldı. Agent token:"
  grep '^AGENT_TOKEN=' "${ENV_FILE}"
  echo "Dashboard şifresini mutlaka değiştirin:"
  echo "  sudo nano ${ENV_FILE}"
  echo
fi

python3 -m venv "${CENTRAL}/.venv"
"${CENTRAL}/.venv/bin/pip" install --upgrade pip
"${CENTRAL}/.venv/bin/pip" install -r "${CENTRAL}/requirements.txt"

chown -R webssl:webssl "${APP_ROOT}"
chmod 640 "${ENV_FILE}"

cp "${CENTRAL}/webssl.service" /etc/systemd/system/webssl.service
systemctl daemon-reload
systemctl enable --now webssl

if command -v ufw >/dev/null 2>&1; then
  ufw allow 8080/tcp comment "WEBSSL dashboard" || true
fi

echo
echo "WEBSSL çalışıyor: http://192.168.254.90:8080"
systemctl --no-pager --full status webssl || true
