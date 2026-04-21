#!/usr/bin/env bash

ip_from_cidr() {
  local value="$1"
  printf '%s\n' "${value%%/*}"
}

first_csv_value() {
  local csv="$1"
  local old_ifs="$IFS"
  local item

  IFS=','
  for item in $csv; do
    IFS="$old_ifs"
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ -n "$item" ]]; then
      printf '%s\n' "$item"
      return 0
    fi
    IFS=','
  done
  IFS="$old_ifs"

  return 1
}

normalize_asn() {
  local asn="$1"
  asn="${asn%%#*}"
  asn="${asn%%$'\r'}"
  asn="${asn^^}"
  asn="${asn#"${asn%%[![:space:]]*}"}"
  asn="${asn%"${asn##*[![:space:]]}"}"
  asn="${asn#AS}"

  [[ "$asn" =~ ^[0-9]+$ ]] || return 1
  printf 'AS%s\n' "$asn"
}

ripe_announced_prefixes_url() {
  local asn
  local base_url
  asn="$(normalize_asn "$1")" || return 1
  base_url="${RIPESTAT_BASE_URL:-https://stat.ripe.net}"
  printf '%s/data/announced-prefixes/data.json?resource=%s&min_peers_seeing=1\n' "${base_url%/}" "$asn"
}

extract_ripe_ipv4_prefixes() {
  python3 -c '
import ipaddress
import json
import sys

payload = json.load(sys.stdin)
for item in payload.get("data", {}).get("prefixes", []):
    prefix = item.get("prefix", "")
    try:
        network = ipaddress.ip_network(prefix, strict=False)
    except ValueError:
        continue
    if network.version == 4:
        print(network.with_prefixlen)
'
}

normalize_dnsmasq_domain() {
  local domain="$1"
  domain="${domain%%#*}"
  domain="${domain%%$'\r'}"
  domain="${domain//$'\t'/ }"
  domain="${domain,,}"
  domain="${domain#"${domain%%[![:space:]]*}"}"
  domain="${domain%"${domain##*[![:space:]]}"}"
  domain="${domain#\*.}"
  domain="${domain#.}"
  domain="${domain%.}"

  [[ -n "$domain" ]] || return 1
  [[ "$domain" != *"://"* ]] || return 1
  [[ "$domain" != *"/"* ]] || return 1
  [[ "$domain" != *" "* ]] || return 1
  [[ "$domain" == *"."* ]] || return 1

  printf '%s\n' "$domain"
}

emit_dnsmasq_ipset_domains() {
  local domains_path="$1"
  local set_name="$2"

  python3 - "$domains_path" "$set_name" <<'PY'
import re
import sys

domains_path = sys.argv[1]
set_name = sys.argv[2]
valid_ascii_domain = re.compile(r"^[a-z0-9.-]+$")


def normalize_domain(line):
    domain = line.split("#", 1)[0].rstrip("\r\n")
    domain = domain.replace("\t", " ").strip().lower()
    if domain.startswith("*."):
        domain = domain[2:]
    domain = domain.strip(".")

    if (
        not domain
        or "://" in domain
        or "/" in domain
        or " " in domain
        or "." not in domain
    ):
        return None

    try:
        domain = domain.encode("idna").decode("ascii").lower()
    except UnicodeError:
        return None

    if len(domain) > 253 or not valid_ascii_domain.fullmatch(domain):
        return None

    labels = domain.split(".")
    if any(
        not label
        or len(label) > 63
        or label.startswith("-")
        or label.endswith("-")
        for label in labels
    ):
        return None

    return domain


with open(domains_path, encoding="utf-8", errors="ignore") as domains_file:
    for line in domains_file:
        domain = normalize_domain(line)
        if domain:
            print(f"ipset=/{domain}/{set_name}")
PY
}

write_dnsmasq_config() {
  local output_path="$1"
  local listen_address="$2"
  local upstreams_csv="$3"
  local blocked_domains_path="$4"
  local direct_domain_set="$5"
  local vpn_domain_set="$6"
  local direct_domains=(
    ru
    xn--p1ai
    gov
    su
    vk.com
    userapi.com
    vkuser.net
    vk-cdn.net
    yandex.com
    yandex.net
    yastatic.net
    yandexcloud.net
    my.com
    mail.com
    tinkoff.com
    sberbank.com
    alfa-bank.com
    wildberries.com
    ozon.com
    avito.com
    cian.com
    2gis.com
    relay-api.eu.2gis.com
  )

  {
    printf '%s\n' \
      "port=53" \
      "user=root" \
      "bind-interfaces" \
      "listen-address=127.0.0.1" \
      "listen-address=${listen_address}" \
      "no-resolv" \
      "no-hosts" \
      "filter-AAAA" \
      "cache-size=10000"

    local direct_domain
    for direct_domain in "${direct_domains[@]}"; do
      printf 'ipset=/%s/%s\n' "$direct_domain" "$direct_domain_set"
    done

    local upstream
    local old_ifs="$IFS"
    IFS=','
    for upstream in $upstreams_csv; do
      IFS="$old_ifs"
      upstream="${upstream#"${upstream%%[![:space:]]*}"}"
      upstream="${upstream%"${upstream##*[![:space:]]}"}"
      if [[ -n "$upstream" ]]; then
        printf 'server=%s\n' "$upstream"
      fi
      IFS=','
    done
    IFS="$old_ifs"

    if [[ -s "$blocked_domains_path" ]]; then
      emit_dnsmasq_ipset_domains "$blocked_domains_path" "$vpn_domain_set"
    fi
  } > "$output_path"
}

load_ipset_file() {
  local set_name="$1"
  local file_path="$2"

  [[ -s "$file_path" ]] || return 0

  local cidr
  while IFS= read -r cidr || [[ -n "$cidr" ]]; do
    cidr="${cidr%%#*}"
    cidr="${cidr%%$'\r'}"
    cidr="${cidr#"${cidr%%[![:space:]]*}"}"
    cidr="${cidr%"${cidr##*[![:space:]]}"}"
    [[ -n "$cidr" ]] || continue
    if ! ipset add "$set_name" "$cidr" -exist; then
      echo "WARNING: failed to add '${cidr}' to ipset ${set_name}" >&2
    fi
  done < "$file_path"
}

write_default_direct_asns_file() {
  local output_path="$1"
  local output_dir
  output_dir="$(dirname "$output_path")"
  mkdir -p "$output_dir"

  [[ -e "$output_path" ]] && return 0

  cat > "$output_path" <<'EOF'
# Russian-controlled content, banking, marketplace, and platform ASNs.
# Edit this file to tune ASN-based direct routing. One ASN per line.
AS13238  # Yandex
AS200350 # Yandex.Cloud
AS215013 # Yandex.Cloud CDN
AS210656 # Yandex.Cloud BMS
AS47541  # VKontakte
AS47542  # VKontakte
AS28709  # VK related
AS47764  # VK / Mail.ru
AS62243  # VK projects
AS207581 # VK projects
AS21051  # VK related
AS57973  # VK related
AS57073  # Wildberries
AS44386  # Ozon
AS201012 # Avito
AS197482 # 2GIS
AS35237  # Sberbank
AS60122  # Sberbank
AS47457  # Sberbank
AS33844  # Sberbank
AS43399  # T-Bank / Tinkoff
AS12686  # T-Bank / Tinkoff
AS28712  # T-Bank / Tinkoff
AS15632  # Alfa-Bank
AS208811 # Alfa-Bank
AS59840  # Alfa-Bank
EOF
}

prune_deprecated_direct_asns_file() {
  local asns_path="$1"
  local tmp_path="${asns_path}.tmp"
  local deprecated_asns=" AS62041 AS62014 AS59930 AS44907 AS211157 "

  [[ -f "$asns_path" ]] || return 0

  local line asn
  : > "$tmp_path"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if asn="$(normalize_asn "$line")" && [[ "$deprecated_asns" == *" ${asn} "* ]]; then
      continue
    fi
    printf '%s\n' "$line" >> "$tmp_path"
  done < "$asns_path"

  mv "$tmp_path" "$asns_path"
}

refresh_direct_asn_prefixes() {
  local asns_path="$1"
  local output_path="$2"
  local tmp_path="${output_path}.tmp"
  local json_path="${output_path}.json.tmp"
  local output_dir
  output_dir="$(dirname "$output_path")"
  mkdir -p "$output_dir"

  : > "$tmp_path"

  local line asn url
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ! asn="$(normalize_asn "$line")"; then
      continue
    fi
    url="$(ripe_announced_prefixes_url "$asn")" || continue
    if ! curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$json_path"; then
      echo "WARNING: failed to download announced prefixes for ${asn}" >&2
      rm -f "$json_path"
      continue
    fi
    if ! extract_ripe_ipv4_prefixes < "$json_path" >> "$tmp_path"; then
      echo "WARNING: failed to parse announced prefixes for ${asn}" >&2
    fi
    rm -f "$json_path"
  done < "$asns_path"

  if [[ -s "$tmp_path" ]]; then
    sort -u "$tmp_path" > "$output_path"
  else
    rm -f "$tmp_path"
    if [[ -s "$output_path" ]]; then
      echo "WARNING: direct ASN prefix refresh produced no data; reusing cached ${output_path}." >&2
    else
      echo "WARNING: direct ASN prefix refresh produced no data; no cached list is available." >&2
    fi
    return 0
  fi

  rm -f "$tmp_path" "$json_path"
}
