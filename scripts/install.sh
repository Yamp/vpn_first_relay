#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="${SERVICE_NAME:-awg-relay-update}"
TIMER_NAME="${TIMER_NAME:-awg-relay-update}"
DOCKER_COMPOSE="${DOCKER_COMPOSE:-sudo docker compose}"

cd "$PROJECT_DIR"

if [[ ! -f .env ]]; then
  public_ip="$(curl -4 -fsSL --connect-timeout 10 https://api.ipify.org || true)"
  if [[ -z "$public_ip" ]]; then
    public_ip="CHANGE_ME_HOST_OR_IP"
  fi
  cat > .env <<EOF
PUBLIC_ENDPOINT=${public_ip}:51820
SERVER_PORT=51820
EOF
  chmod 600 .env
fi

if ! grep -q '^ADMIN_PASSWORD=' .env; then
  admin_password="$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')"
  {
    echo "ADMIN_USERNAME=admin"
    echo "ADMIN_PASSWORD=${admin_password}"
    echo "ADMIN_PORT=8080"
    echo "WARNING_BEFORE_HOURS=48"
  } >> .env
  chmod 600 .env
  echo "Generated admin credentials:"
  echo "  username: admin"
  echo "  password: ${admin_password}"
fi

$DOCKER_COMPOSE up -d --build

service_path="/etc/systemd/system/${SERVICE_NAME}.service"
timer_path="/etc/systemd/system/${TIMER_NAME}.timer"

sudo tee "$service_path" >/dev/null <<EOF
[Unit]
Description=Update AWG relay image when AmneziaWG upstream changes
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
WorkingDirectory=${PROJECT_DIR}
ExecStart=${PROJECT_DIR}/scripts/update-awg.sh
EOF

sudo tee "$timer_path" >/dev/null <<EOF
[Unit]
Description=Run AWG relay update check every day at 03:00 Moscow time

[Timer]
OnCalendar=*-*-* 03:00:00 Europe/Moscow
Persistent=true
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${TIMER_NAME}.timer"
sudo systemctl list-timers --all "${TIMER_NAME}.timer"
