#!/usr/bin/env bash

ip_from_cidr() {
  local value="$1"
  printf '%s\n' "${value%%/*}"
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
    telegram.org
    t.me
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
      local line domain
      while IFS= read -r line || [[ -n "$line" ]]; do
        if domain="$(normalize_dnsmasq_domain "$line")"; then
          printf 'ipset=/%s/%s\n' "$domain" "$vpn_domain_set"
        fi
      done < "$blocked_domains_path"
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
