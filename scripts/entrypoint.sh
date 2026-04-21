#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROUTING_LIB="${ROUTING_LIB:-${SCRIPT_DIR}/routing-lists.sh}"
SINGBOX_RENDERER="${SINGBOX_RENDERER:-/usr/local/bin/render-sing-box-config.py}"
# shellcheck source=scripts/routing-lists.sh
. "$ROUTING_LIB"

CONFIG_DIR="${CONFIG_DIR:-/config}"
RUNTIME_DIR="/run/awg-relay"
SERVER_IF="${SERVER_IF:-awg-relay}"
UPSTREAM_IF="${UPSTREAM_IF:-awg-up}"
SERVER_PORT="${SERVER_PORT:-51820}"
SERVER_ADDRESS="${SERVER_ADDRESS:-10.77.0.1/24}"
CLIENT_SUBNET="${CLIENT_SUBNET:-10.77.0.0/24}"
CLIENT_ADDRESS="${CLIENT_ADDRESS:-10.77.0.2/32}"
PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT:-CHANGE_ME_HOST_OR_IP:51820}"
RU_ZONE_URL="${RU_ZONE_URL:-https://www.ipdeny.com/ipblocks/data/countries/ru.zone}"
ANTIFILTER_IP_URL="${ANTIFILTER_IP_URL:-https://antifilter.download/list/allyouneed.lst}"
ANTIFILTER_DOMAINS_URL="${ANTIFILTER_DOMAINS_URL:-}"
SPLIT_DNS_UPSTREAMS="${SPLIT_DNS_UPSTREAMS:-1.1.1.1,8.8.8.8}"
DIRECT_ASNS_FILE="${DIRECT_ASNS_FILE:-$CONFIG_DIR/routing/direct-asns.lst}"
DIRECT_ASN_PREFIXES_FILE="${DIRECT_ASN_PREFIXES_FILE:-$CONFIG_DIR/routing/direct-asn-prefixes.zone}"
SING_BOX_TUN_ADDRESS="${SING_BOX_TUN_ADDRESS:-172.19.0.1/30}"

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

DEFAULT_CLIENT_DNS="$(first_csv_value "$SPLIT_DNS_UPSTREAMS" || true)"
CLIENT_DNS="${CLIENT_DNS:-${DEFAULT_CLIENT_DNS:-$(ip_from_cidr "$SERVER_ADDRESS")}}"
export CLIENT_DNS

mkdir -p "$CONFIG_DIR" "$RUNTIME_DIR" "$CONFIG_DIR/server" "$CONFIG_DIR/clients/client1" "$CONFIG_DIR/geoip" "$CONFIG_DIR/antifilter" "$CONFIG_DIR/routing"

download_cached_list() {
  local url="$1"
  local output_path="$2"
  local label="$3"
  local tmp_path="${output_path}.tmp"

  if curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$tmp_path"; then
    mv "$tmp_path" "$output_path"
  else
    rm -f "$tmp_path"
    if [[ -s "$output_path" ]]; then
      echo "WARNING: failed to download ${label}; reusing cached ${output_path}." >&2
    else
      echo "WARNING: failed to download ${label}; no cached list is available." >&2
    fi
  fi
}

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
  if [[ -n "${SING_BOX_PID:-}" ]]; then
    kill "$SING_BOX_PID" >/dev/null 2>&1 || true
  fi
  ip link del sb-tun >/dev/null 2>&1 || true
  ip link del "$SERVER_IF" >/dev/null 2>&1 || true
  ip link del "$UPSTREAM_IF" >/dev/null 2>&1 || true
}
trap cleanup EXIT TERM INT

cleanup
start_awg "$UPSTREAM_IF" "$RUNTIME_DIR/upstream.awg" "$UPSTREAM_ADDRESS" "${UPSTREAM_MTU:-1280}"
start_awg "$SERVER_IF" "$RUNTIME_DIR/server.awg" "$SERVER_ADDRESS" "1280"

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

download_cached_list "$RU_ZONE_URL" "$CONFIG_DIR/geoip/ru.zone" "RU geoip list"
if [[ ! -s "$CONFIG_DIR/geoip/ru.zone" ]]; then
  echo "WARNING: RU geoip list is empty; all public IPv4 destinations will go through upstream AWG." >&2
fi

download_cached_list "$ANTIFILTER_IP_URL" "$CONFIG_DIR/antifilter/allyouneed.lst" "antifilter IP list"
if [[ ! -s "$CONFIG_DIR/antifilter/allyouneed.lst" ]]; then
  echo "WARNING: antifilter IP list is empty; only GeoIP, TLD, and domain DNS rules will be used." >&2
fi

write_default_direct_asns_file "$DIRECT_ASNS_FILE"
prune_deprecated_direct_asns_file "$DIRECT_ASNS_FILE"
refresh_direct_asn_prefixes "$DIRECT_ASNS_FILE" "$DIRECT_ASN_PREFIXES_FILE"
if [[ ! -s "$DIRECT_ASN_PREFIXES_FILE" ]]; then
  echo "WARNING: direct ASN prefix list is empty; ASN-based direct routing is disabled." >&2
fi

ANTIFILTER_DOMAINS_FILE=""
if [[ -n "$ANTIFILTER_DOMAINS_URL" ]]; then
  ANTIFILTER_DOMAINS_FILE="$CONFIG_DIR/antifilter/domains.lst"
  download_cached_list "$ANTIFILTER_DOMAINS_URL" "$ANTIFILTER_DOMAINS_FILE" "antifilter domains list"
else
  echo "Antifilter domain list is disabled; only IP, GeoIP, ASN, and curated direct domain rules will be used." >&2
fi

RULES_DIR="$RUNTIME_DIR/sing-box"
mkdir -p "$RULES_DIR"

python3 "$SINGBOX_RENDERER" \
  --config-out "$RUNTIME_DIR/sing-box.json" \
  --direct-domains-out "$RULES_DIR/direct-domains.json" \
  --vpn-domains-out "$RULES_DIR/vpn-domains.json" \
  --ru-ip-out "$RULES_DIR/ru-ip.json" \
  --vpn-ip-out "$RULES_DIR/vpn-ip.json" \
  --direct-asn-ip-out "$RULES_DIR/direct-asn-ip.json" \
  --local-ip-out "$RULES_DIR/local-ip.json" \
  --server-if "$SERVER_IF" \
  --upstream-if "$UPSTREAM_IF" \
  --tun-address "$SING_BOX_TUN_ADDRESS" \
  --dns-upstreams "$SPLIT_DNS_UPSTREAMS" \
  --antifilter-domains "$ANTIFILTER_DOMAINS_FILE" \
  --ru-zone "$CONFIG_DIR/geoip/ru.zone" \
  --antifilter-ip "$CONFIG_DIR/antifilter/allyouneed.lst" \
  --direct-asn-prefixes "$DIRECT_ASN_PREFIXES_FILE"

for source_rule_set in \
  "$RULES_DIR/direct-domains.json" \
  "$RULES_DIR/vpn-domains.json" \
  "$RULES_DIR/ru-ip.json" \
  "$RULES_DIR/vpn-ip.json" \
  "$RULES_DIR/direct-asn-ip.json" \
  "$RULES_DIR/local-ip.json"; do
  sing-box rule-set compile --output "${source_rule_set%.json}.srs" "$source_rule_set"
done

sing-box check -c "$RUNTIME_DIR/sing-box.json"
sing-box run -c "$RUNTIME_DIR/sing-box.json" &
SING_BOX_PID="$!"

echo "AWG relay is running."
python3 /opt/awg-admin/app.py &
ADMIN_PID="$!"
echo "AWG admin panel is running on port ${ADMIN_LISTEN_PORT:-8080}."

sleep infinity
