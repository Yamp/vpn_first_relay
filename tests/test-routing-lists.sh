#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/routing-lists.sh
. "$ROOT_DIR/scripts/routing-lists.sh"
SINGBOX_RENDERER="$ROOT_DIR/scripts/render-sing-box-config.py"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fqx "$needle" "$file" || fail "missing line '$needle' in $file"
}

assert_not_contains_text() {
  local needle="$1"
  local file="$2"
  ! grep -Fq "$needle" "$file" || fail "unexpected text '$needle' in $file"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_eq "10.77.0.1" "$(ip_from_cidr "10.77.0.1/24")" "ip_from_cidr strips a CIDR suffix"
assert_eq "1.1.1.1" "$(first_csv_value " 1.1.1.1 , 8.8.8.8 ")" "first_csv_value returns the first non-empty CSV item"
assert_eq "AS13238" "$(normalize_asn " as13238 # Yandex")" "normalize_asn canonicalizes ASN values"
assert_eq "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS13238&min_peers_seeing=1" "$(ripe_announced_prefixes_url "13238")" "ripe_announced_prefixes_url builds announced-prefixes API URL"
assert_eq "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS13238&min_peers_seeing=1" "$(RIPESTAT_BASE_URL="https://stat.ripe.net/" ripe_announced_prefixes_url "AS13238")" "ripe_announced_prefixes_url strips trailing slash"

domains_file="$tmp_dir/domains.lst"
cat > "$domains_file" <<'DOMAINS'
# ignored comment
Example.COM
*.Blocked.Example
.leading-dot.example
0f5b5df3-526c-4fb8-a421-e0647e59e4d4.саженцыроссии.рф
https://url.example/path
bad/domain
DOMAINS

assert_contains 'ANTIFILTER_DOMAINS_URL="${ANTIFILTER_DOMAINS_URL:-}"' "$ROOT_DIR/scripts/entrypoint.sh"
assert_contains '      ANTIFILTER_DOMAINS_URL: "${ANTIFILTER_DOMAINS_URL:-}"' "$ROOT_DIR/docker-compose.yml"
assert_contains 'SING_BOX_TUN_ADDRESS="${SING_BOX_TUN_ADDRESS:-172.19.0.1/30}"' "$ROOT_DIR/scripts/entrypoint.sh"
assert_contains '      SING_BOX_TUN_ADDRESS: "${SING_BOX_TUN_ADDRESS:-172.19.0.1/30}"' "$ROOT_DIR/docker-compose.yml"

ripe_json="$tmp_dir/ripe.json"
cat > "$ripe_json" <<'JSON'
{
  "data": {
    "prefixes": [
      {"prefix": "5.255.255.0/24"},
      {"prefix": "2a02:6b8::/32"},
      {"prefix": "87.250.250.0/24"}
    ]
  }
}
JSON
extract_ripe_ipv4_prefixes < "$ripe_json" > "$tmp_dir/prefixes.txt"
assert_contains "5.255.255.0/24" "$tmp_dir/prefixes.txt"
assert_contains "87.250.250.0/24" "$tmp_dir/prefixes.txt"
assert_not_contains_text "2a02:6b8::/32" "$tmp_dir/prefixes.txt"

asns_file="$tmp_dir/asns.lst"
echo "AS13238" > "$asns_file"
curl() {
  return 6
}
refresh_direct_asn_prefixes "$asns_file" "$tmp_dir/direct-asn-prefixes.zone" 2> "$tmp_dir/refresh.err"
assert_contains "WARNING: failed to download announced prefixes for AS13238" "$tmp_dir/refresh.err"
assert_not_contains_text "Traceback" "$tmp_dir/refresh.err"

direct_asns="$tmp_dir/direct-asns.lst"
write_default_direct_asns_file "$direct_asns"
for asn in AS62041 AS62014 AS59930 AS44907 AS211157; do
  assert_not_contains_text "$asn" "$direct_asns"
done

cat > "$direct_asns" <<'ASNS'
AS13238 # Yandex
AS62041 # Telegram
AS59930 # Telegram
AS57073 # Wildberries
ASNS
prune_deprecated_direct_asns_file "$direct_asns"
assert_contains "AS13238 # Yandex" "$direct_asns"
assert_contains "AS57073 # Wildberries" "$direct_asns"
for asn in AS62041 AS62014 AS59930 AS44907 AS211157; do
  assert_not_contains_text "$asn" "$direct_asns"
done

ru_zone="$tmp_dir/ru.zone"
cat > "$ru_zone" <<'ZONE'
5.255.255.0/24
bad-prefix
ZONE

vpn_ip_list="$tmp_dir/allyouneed.lst"
cat > "$vpn_ip_list" <<'IPS'
1.1.1.0/24
8.8.8.0/24
IPS

direct_asn_prefixes="$tmp_dir/direct-asn-prefixes.zone"
cat > "$direct_asn_prefixes" <<'PREFIXES'
87.250.250.0/24
bad-prefix
PREFIXES

python3 "$SINGBOX_RENDERER" \
  --config-out "$tmp_dir/sing-box.json" \
  --direct-domains-out "$tmp_dir/direct-domains.json" \
  --vpn-domains-out "$tmp_dir/vpn-domains.json" \
  --ru-ip-out "$tmp_dir/ru-ip.json" \
  --vpn-ip-out "$tmp_dir/vpn-ip.json" \
  --direct-asn-ip-out "$tmp_dir/direct-asn-ip.json" \
  --local-ip-out "$tmp_dir/local-ip.json" \
  --server-if awg-relay \
  --upstream-if awg-up \
  --dns-upstreams "1.1.1.1,8.8.8.8" \
  --antifilter-domains "$domains_file" \
  --ru-zone "$ru_zone" \
  --antifilter-ip "$vpn_ip_list" \
  --direct-asn-prefixes "$direct_asn_prefixes"

python3 - "$tmp_dir" <<'PY'
import json
import pathlib
import sys

tmp_dir = pathlib.Path(sys.argv[1])

direct_domains = json.loads((tmp_dir / "direct-domains.json").read_text())
vpn_domains = json.loads((tmp_dir / "vpn-domains.json").read_text())
ru_ip = json.loads((tmp_dir / "ru-ip.json").read_text())
vpn_ip = json.loads((tmp_dir / "vpn-ip.json").read_text())
direct_asn_ip = json.loads((tmp_dir / "direct-asn-ip.json").read_text())
local_ip = json.loads((tmp_dir / "local-ip.json").read_text())
config = json.loads((tmp_dir / "sing-box.json").read_text())

assert direct_domains["rules"][0]["domain_suffix"][:4] == ["2gis.com", "alfa-bank.com", "avito.com", "cian.com"]
assert "ru" in direct_domains["rules"][0]["domain_suffix"]
assert "xn--p1ai" in direct_domains["rules"][0]["domain_suffix"]
assert "example.com" in vpn_domains["rules"][0]["domain_suffix"]
assert "blocked.example" in vpn_domains["rules"][0]["domain_suffix"]
assert "leading-dot.example" in vpn_domains["rules"][0]["domain_suffix"]
assert "0f5b5df3-526c-4fb8-a421-e0647e59e4d4.xn--80akcja2ahpega0d9c.xn--p1ai" in vpn_domains["rules"][0]["domain_suffix"]
assert "url.example" not in vpn_domains["rules"][0]["domain_suffix"]
assert "bad/domain" not in json.dumps(vpn_domains)

assert ru_ip["rules"][0]["ip_cidr"] == ["5.255.255.0/24"]
assert vpn_ip["rules"][0]["ip_cidr"] == ["1.1.1.0/24", "8.8.8.0/24"]
assert direct_asn_ip["rules"][0]["ip_cidr"] == ["87.250.250.0/24"]
assert "10.0.0.0/8" in local_ip["rules"][0]["ip_cidr"]
assert "224.0.0.0/4" in local_ip["rules"][0]["ip_cidr"]

assert config["dns"]["final"] == "dns-upstream-1"
assert config["dns"]["servers"][0]["server"] == "1.1.1.1"
assert config["inbounds"][0]["include_interface"] == ["awg-relay"]
assert config["outbounds"][1]["bind_interface"] == "eth0"
assert config["outbounds"][2]["bind_interface"] == "awg-up"
assert config["route"]["final"] == "vpn-out"
assert config["route"]["rules"][0]["action"] == "hijack-dns"
assert config["route"]["rules"][1]["action"] == "sniff"
PY

echo "routing-lists tests passed"
