#!/usr/bin/env bash
# WEBSSL merkezi dashboard — Ubuntu Server kurulum script'i
# Kullanım (root): sudo bash /opt/webssl/scripts/install-ubuntu.sh
set -euo pipefail

APP_ROOT="/opt/webssl"
CENTRAL="${APP_ROOT}/central"
ENV_FILE="${APP_ROOT}/.env"

ask() {
  local prompt="$1"
  local default="${2:-}"
  local secret="${3:-0}"
  local value=""
  if [[ -n "${default}" ]]; then
    prompt="${prompt} [${default}]"
  fi
  if [[ "${secret}" == "1" ]]; then
    read -r -s -p "${prompt}: " value </dev/tty
    echo >/dev/tty
  else
    read -r -p "${prompt}: " value </dev/tty
  fi
  if [[ -z "${value}" ]]; then
    value="${default}"
  fi
  printf '%s' "${value}"
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Bu script root olarak çalışmalı: sudo bash $0"
  exit 1
fi

if [[ ! -f "${CENTRAL}/requirements.txt" ]]; then
  echo "Proje ${APP_ROOT} altında değil. Önce git clone yapın."
  exit 1
fi

echo "=== WEBSSL dashboard kurulumu ==="
DASHBOARD_IP="$(ask "Dashboard IP veya hostname (agent'lar bu adrese bağlanacak)")"
if [[ -z "${DASHBOARD_IP}" ]]; then
  echo "IP / hostname boş olamaz."
  exit 1
fi
DASHBOARD_PORT="$(ask "Port" "8080")"
DASHBOARD_USER="$(ask "Panel kullanıcı adı" "admin")"
DASHBOARD_PASSWORD="$(ask "Panel şifresi" "" 1)"
if [[ -z "${DASHBOARD_PASSWORD}" ]]; then
  echo "Şifre boş olamaz."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip git

id -u webssl >/dev/null 2>&1 || useradd --system --home "${APP_ROOT}" --shell /usr/sbin/nologin webssl

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

cat > "${ENV_FILE}" <<EOF
DASHBOARD_USER=${DASHBOARD_USER}
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
DASHBOARD_URL=http://${DASHBOARD_IP}:${DASHBOARD_PORT}
AGENT_TOKEN=${TOKEN}
SECRET_KEY=${SECRET}
HOST=0.0.0.0
PORT=${DASHBOARD_PORT}
STALE_AFTER_HOURS=24
EOF

python3 -m venv "${CENTRAL}/.venv"
"${CENTRAL}/.venv/bin/pip" install --upgrade pip
"${CENTRAL}/.venv/bin/pip" install -r "${CENTRAL}/requirements.txt"

chown -R webssl:webssl "${APP_ROOT}"
chmod 640 "${ENV_FILE}"

cp "${CENTRAL}/webssl.service" /etc/systemd/system/webssl.service
systemctl daemon-reload
systemctl enable --now webssl

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${DASHBOARD_PORT}/tcp" comment "WEBSSL dashboard" || true
fi

echo
echo "WEBSSL hazır: http://${DASHBOARD_IP}:${DASHBOARD_PORT}"
echo "Agent kurulurken bu IP'yi ve aşağıdaki token'ı kullanın:"
echo "AGENT_TOKEN=${TOKEN}"
echo
systemctl --no-pager --full status webssl || true
