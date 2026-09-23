#!/usr/bin/env bash
# WEBSSL nginx agent kurulumu — Linux sitelerin olduğu sunucuda çalıştırın.
# Kullanım: sudo bash install-agent.sh
set -euo pipefail

AGENT_DIR="/opt/webssl-agent"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ask() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  if [[ -n "${default}" ]]; then
    prompt="${prompt} [${default}]"
  fi
  read -r -p "${prompt}: " value </dev/tty
  if [[ -z "${value}" ]]; then
    value="${default}"
  fi
  printf '%s' "${value}"
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Bu script root olarak çalışmalı: sudo bash $0"
  exit 1
fi

echo "=== WEBSSL Linux (nginx) agent kurulumu ==="
DASHBOARD_IP="$(ask "Dashboard IP veya hostname")"
if [[ -z "${DASHBOARD_IP}" ]]; then
  echo "IP / hostname boş olamaz."
  exit 1
fi
DASHBOARD_PORT="$(ask "Dashboard port" "8080")"
AGENT_TOKEN="$(ask "Agent token (dashboard sunucusundaki /opt/webssl/.env içinde AGENT_TOKEN)")"
if [[ -z "${AGENT_TOKEN}" ]]; then
  echo "Token boş olamaz."
  exit 1
fi

CENTRAL_URL="http://${DASHBOARD_IP}:${DASHBOARD_PORT}"

mkdir -p "${AGENT_DIR}"
cp "${SCRIPT_DIR}/webssl_agent.py" "${AGENT_DIR}/webssl_agent.py"
chmod 755 "${AGENT_DIR}/webssl_agent.py"

apt-get update
apt-get install -y python3 python3-pip
python3 -m pip install --upgrade pip
python3 -m pip install cryptography || true

cat > "${AGENT_DIR}/agent.config.json" <<EOF
{
  "central_url": "${CENTRAL_URL}",
  "agent_token": "${AGENT_TOKEN}"
}
EOF
chmod 600 "${AGENT_DIR}/agent.config.json"

cat > /etc/cron.d/webssl-agent <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 6 * * * root /usr/bin/python3 ${AGENT_DIR}/webssl_agent.py --config ${AGENT_DIR}/agent.config.json >> /var/log/webssl-agent.log 2>&1
EOF
chmod 644 /etc/cron.d/webssl-agent

echo "İlk tarama gönderiliyor..."
/usr/bin/python3 "${AGENT_DIR}/webssl_agent.py" --config "${AGENT_DIR}/agent.config.json"

echo
echo "Linux agent kuruldu. Günlük çalışma: 06:00"
echo "Hedef: ${CENTRAL_URL}"
