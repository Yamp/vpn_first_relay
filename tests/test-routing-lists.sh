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
  telegram.org t.me \
  my.com mail.com \
  tinkoff.com sberbank.com alfa-bank.com \
  wildberries.com ozon.com \
  avito.com cian.com 2gis.com; do
  assert_contains "ipset=/${domain}/direct_domains4" "$config_file"
done
assert_contains "ipset=/example.com/vpn_domains4" "$config_file"
assert_contains "ipset=/blocked.example/vpn_domains4" "$config_file"
assert_contains "ipset=/leading-dot.example/vpn_domains4" "$config_file"
assert_not_contains_text "url.example" "$config_file"
assert_not_contains_text "bad/domain" "$config_file"

echo "routing-lists tests passed"
