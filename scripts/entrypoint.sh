#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/config}"
RUNTIME_DIR="/run/awg-relay"
SERVER_IF="${SERVER_IF:-awg-relay}"
UPSTREAM_IF="${UPSTREAM_IF:-awg-up}"
SERVER_PORT="${SERVER_PORT:-51820}"
SERVER_ADDRESS="${SERVER_ADDRESS:-10.77.0.1/24}"
CLIENT_SUBNET="${CLIENT_SUBNET:-10.77.0.0/24}"
CLIENT_ADDRESS="${CLIENT_ADDRESS:-10.77.0.2/32}"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"
PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT:-CHANGE_ME_HOST_OR_IP:51820}"
RU_ZONE_URL="${RU_ZONE_URL:-https://www.ipdeny.com/ipblocks/data/countries/ru.zone}"

SERVER_JC="${SERVER_JC:-4}"
SERVER_JMIN="${SERVER_JMIN:-8}"
SERVER_JMAX="${SERVER_JMAX:-80}"
SERVER_S1="${SERVER_S1:-64}"
SERVER_S2="${SERVER_S2:-128}"
SERVER_S3="${SERVER_S3:-32}"
SERVER_S4="${SERVER_S4:-32}"
SERVER_H1="${SERVER_H1:-123456701}"
SERVER_H2="${SERVER_H2:-123456702}"
SERVER_H3="${SERVER_H3:-123456703}"
SERVER_H4="${SERVER_H4:-123456704}"

TABLE_ID="${TABLE_ID:-100}"
FW_MARK="${FW_MARK:-0x1}"

mkdir -p "$CONFIG_DIR" "$RUNTIME_DIR" "$CONFIG_DIR/server" "$CONFIG_DIR/clients/client1" "$CONFIG_DIR/geoip"

if [[ ! -f "$CONFIG_DIR/upstream.conf" ]]; then
  cp /defaults/upstream.conf "$CONFIG_DIR/upstream.conf"
  chmod 600 "$CONFIG_DIR/upstream.conf"
fi

get_conf_value() {
  local section="$1"
  local key="$2"
  local file="$3"
  awk -F '=' -v section="$section" -v key="$key" '
    $0 ~ "^\\[" {
      current=$0
      gsub(/^\[|\]$/, "", current)
      next
    }
    current == section {
      k=$1
      v=$0
      sub(/=.*/, "", k)
      sub(/^[^=]*=/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == key) {
        print v
        exit
      }
    }
  ' "$file"
}

ensure_keypair() {
  local private_path="$1"
  local public_path="$2"
  if [[ ! -s "$private_path" ]]; then
    umask 077
    awg genkey > "$private_path"
  fi
  awg pubkey < "$private_path" > "$public_path"
}

ensure_keypair "$CONFIG_DIR/server/privatekey" "$CONFIG_DIR/server/publickey"

SERVER_PRIVATE_KEY="$(< "$CONFIG_DIR/server/privatekey")"
SERVER_PUBLIC_KEY="$(< "$CONFIG_DIR/server/publickey")"

cat > "$RUNTIME_DIR/server.awg" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
ListenPort = ${SERVER_PORT}
Jc = ${SERVER_JC}
Jmin = ${SERVER_JMIN}
Jmax = ${SERVER_JMAX}
S1 = ${SERVER_S1}
S2 = ${SERVER_S2}
S3 = ${SERVER_S3}
S4 = ${SERVER_S4}
H1 = ${SERVER_H1}
H2 = ${SERVER_H2}
H3 = ${SERVER_H3}
H4 = ${SERVER_H4}
EOF

UPSTREAM_PRIVATE_KEY="$(get_conf_value Interface PrivateKey "$CONFIG_DIR/upstream.conf")"
UPSTREAM_ADDRESS="$(get_conf_value Interface Address "$CONFIG_DIR/upstream.conf")"
UPSTREAM_MTU="$(get_conf_value Interface MTU "$CONFIG_DIR/upstream.conf")"
UPSTREAM_JC="$(get_conf_value Interface Jc "$CONFIG_DIR/upstream.conf")"
UPSTREAM_JMIN="$(get_conf_value Interface Jmin "$CONFIG_DIR/upstream.conf")"
UPSTREAM_JMAX="$(get_conf_value Interface Jmax "$CONFIG_DIR/upstream.conf")"
UPSTREAM_S1="$(get_conf_value Interface S1 "$CONFIG_DIR/upstream.conf")"
UPSTREAM_S2="$(get_conf_value Interface S2 "$CONFIG_DIR/upstream.conf")"
UPSTREAM_S3="$(get_conf_value Interface S3 "$CONFIG_DIR/upstream.conf")"
UPSTREAM_S4="$(get_conf_value Interface S4 "$CONFIG_DIR/upstream.conf")"
UPSTREAM_H1="$(get_conf_value Interface H1 "$CONFIG_DIR/upstream.conf")"
UPSTREAM_H2="$(get_conf_value Interface H2 "$CONFIG_DIR/upstream.conf")"
UPSTREAM_H3="$(get_conf_value Interface H3 "$CONFIG_DIR/upstream.conf")"
UPSTREAM_H4="$(get_conf_value Interface H4 "$CONFIG_DIR/upstream.conf")"
UPSTREAM_PEER_PUBLIC_KEY="$(get_conf_value Peer PublicKey "$CONFIG_DIR/upstream.conf")"
UPSTREAM_ENDPOINT="$(get_conf_value Peer Endpoint "$CONFIG_DIR/upstream.conf")"
UPSTREAM_ALLOWED_IPS="$(get_conf_value Peer AllowedIPs "$CONFIG_DIR/upstream.conf")"
UPSTREAM_KEEPALIVE="$(get_conf_value Peer PersistentKeepalive "$CONFIG_DIR/upstream.conf")"

cat > "$RUNTIME_DIR/upstream.awg" <<EOF
[Interface]
PrivateKey = ${UPSTREAM_PRIVATE_KEY}
Jc = ${UPSTREAM_JC}
Jmin = ${UPSTREAM_JMIN}
Jmax = ${UPSTREAM_JMAX}
S1 = ${UPSTREAM_S1}
S2 = ${UPSTREAM_S2}
S3 = ${UPSTREAM_S3}
S4 = ${UPSTREAM_S4}
H1 = ${UPSTREAM_H1}
H2 = ${UPSTREAM_H2}
H3 = ${UPSTREAM_H3}
H4 = ${UPSTREAM_H4}

[Peer]
PublicKey = ${UPSTREAM_PEER_PUBLIC_KEY}
Endpoint = ${UPSTREAM_ENDPOINT}
AllowedIPs = ${UPSTREAM_ALLOWED_IPS}
PersistentKeepalive = ${UPSTREAM_KEEPALIVE}
EOF

start_awg() {
  local iface="$1"
  local conf="$2"
  local address="$3"
  local mtu="$4"

  amneziawg-go -f "$iface" &
  local pid="$!"
  echo "$pid" > "$RUNTIME_DIR/${iface}.pid"

  for _ in $(seq 1 50); do
    if ip link show "$iface" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  ip addr add "$address" dev "$iface"
  ip link set mtu "$mtu" up dev "$iface"
  awg setconf "$iface" "$conf"
}

cleanup() {
  if [[ -n "${ADMIN_PID:-}" ]]; then
    kill "$ADMIN_PID" >/dev/null 2>&1 || true
  fi
  ip link del "$SERVER_IF" >/dev/null 2>&1 || true
  ip link del "$UPSTREAM_IF" >/dev/null 2>&1 || true
}
trap cleanup EXIT TERM INT

cleanup
start_awg "$UPSTREAM_IF" "$RUNTIME_DIR/upstream.awg" "$UPSTREAM_ADDRESS" "${UPSTREAM_MTU:-1280}"
start_awg "$SERVER_IF" "$RUNTIME_DIR/server.awg" "$SERVER_ADDRESS" "1280"

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

ipset create ru4 hash:net family inet -exist
ipset flush ru4
if curl -fsSL --retry 3 --connect-timeout 10 "$RU_ZONE_URL" -o "$CONFIG_DIR/geoip/ru.zone.tmp"; then
  mv "$CONFIG_DIR/geoip/ru.zone.tmp" "$CONFIG_DIR/geoip/ru.zone"
fi
if [[ -s "$CONFIG_DIR/geoip/ru.zone" ]]; then
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] && ipset add ru4 "$cidr" -exist
  done < "$CONFIG_DIR/geoip/ru.zone"
else
  echo "WARNING: RU geoip list is empty; all public IPv4 destinations will go through upstream AWG." >&2
fi

ipset create direct4 hash:net family inet -exist
ipset flush direct4
for cidr in \
  0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
  172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 \
  198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4; do
  ipset add direct4 "$cidr" -exist
done

ip rule del fwmark "$FW_MARK" table "$TABLE_ID" >/dev/null 2>&1 || true
ip rule add fwmark "$FW_MARK" table "$TABLE_ID" priority 100
ip route replace default dev "$UPSTREAM_IF" table "$TABLE_ID"

iptables -t mangle -N AWG_SPLIT >/dev/null 2>&1 || true
iptables -t mangle -F AWG_SPLIT
iptables -t mangle -D PREROUTING -i "$SERVER_IF" -s "$CLIENT_SUBNET" -j AWG_SPLIT >/dev/null 2>&1 || true
iptables -t mangle -A PREROUTING -i "$SERVER_IF" -s "$CLIENT_SUBNET" -j AWG_SPLIT
iptables -t mangle -A AWG_SPLIT -m set --match-set direct4 dst -j RETURN
iptables -t mangle -A AWG_SPLIT -m set --match-set ru4 dst -j RETURN
iptables -t mangle -A AWG_SPLIT -j MARK --set-mark "$FW_MARK"

iptables -t nat -D POSTROUTING -s "$CLIENT_SUBNET" -m mark --mark "$FW_MARK" -o "$UPSTREAM_IF" -j MASQUERADE >/dev/null 2>&1 || true
iptables -t nat -D POSTROUTING -s "$CLIENT_SUBNET" -o eth0 -j MASQUERADE >/dev/null 2>&1 || true
iptables -t nat -A POSTROUTING -s "$CLIENT_SUBNET" -m mark --mark "$FW_MARK" -o "$UPSTREAM_IF" -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$CLIENT_SUBNET" -o eth0 -j MASQUERADE

echo "AWG relay is running."
python3 /opt/awg-admin/app.py &
ADMIN_PID="$!"
echo "AWG admin panel is running on port ${ADMIN_LISTEN_PORT:-8080}."

sleep infinity
