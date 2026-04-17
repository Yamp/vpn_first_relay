#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/routing-lists.sh
. "$ROOT_DIR/scripts/routing-lists.sh"

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
assert_eq "AS13238" "$(normalize_asn " as13238 # Yandex")" "normalize_asn canonicalizes ASN values"
assert_eq "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS13238&min_peers_seeing=1" "$(ripe_announced_prefixes_url "13238")" "ripe_announced_prefixes_url builds announced-prefixes API URL"
assert_eq "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS13238&min_peers_seeing=1" "$(RIPESTAT_BASE_URL="https://stat.ripe.net/" ripe_announced_prefixes_url "AS13238")" "ripe_announced_prefixes_url strips trailing slash"

domains_file="$tmp_dir/domains.lst"
cat > "$domains_file" <<'DOMAINS'
# ignored comment
Example.COM
*.Blocked.Example
.leading-dot.example
https://url.example/path
bad/domain
DOMAINS

config_file="$tmp_dir/dnsmasq.conf"
write_dnsmasq_config "$config_file" "10.77.0.1" "1.1.1.1,8.8.8.8" "$domains_file" "direct_domains4" "vpn_domains4"

assert_contains "listen-address=10.77.0.1" "$config_file"
assert_contains "user=root" "$config_file"
assert_contains "filter-AAAA" "$config_file"
assert_contains "server=1.1.1.1" "$config_file"
assert_contains "server=8.8.8.8" "$config_file"
assert_contains "ipset=/ru/direct_domains4" "$config_file"
assert_contains "ipset=/xn--p1ai/direct_domains4" "$config_file"
assert_contains "ipset=/gov/direct_domains4" "$config_file"
assert_contains "ipset=/su/direct_domains4" "$config_file"
for domain in \
  vk.com userapi.com vkuser.net vk-cdn.net \
  yandex.com yandex.net yastatic.net yandexcloud.net \
  my.com mail.com \
  tinkoff.com sberbank.com alfa-bank.com \
  wildberries.com ozon.com \
  avito.com cian.com 2gis.com; do
  assert_contains "ipset=/${domain}/direct_domains4" "$config_file"
done
assert_not_contains_text "ipset=/telegram.org/direct_domains4" "$config_file"
assert_not_contains_text "ipset=/t.me/direct_domains4" "$config_file"
assert_contains "ipset=/example.com/vpn_domains4" "$config_file"
assert_contains "ipset=/blocked.example/vpn_domains4" "$config_file"
assert_contains "ipset=/leading-dot.example/vpn_domains4" "$config_file"
assert_not_contains_text "url.example" "$config_file"
assert_not_contains_text "bad/domain" "$config_file"

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

echo "routing-lists tests passed"
