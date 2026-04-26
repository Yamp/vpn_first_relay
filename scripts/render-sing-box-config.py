#!/usr/bin/env python3
import argparse
import ipaddress
import json
import re
from pathlib import Path


DEFAULT_DIRECT_DOMAIN_SUFFIXES = [
    "ru",
    "xn--p1ai",
    "gov",
    "su",
    "vk.com",
    "userapi.com",
    "vkuser.net",
    "vk-cdn.net",
    "yandex.com",
    "yandex.net",
    "yastatic.net",
    "yandexcloud.net",
    "my.com",
    "mail.com",
    "tinkoff.com",
    "sberbank.com",
    "alfa-bank.com",
    "wildberries.com",
    "wb.ru",
    "rwb.ru",
    "wb-basket.ru",
    "wbbasket.ru",
    "wbcontent.net",
    "wbstatic.net",
    "wibes.ru",
    "ozon.com",
    "ozone.ru",
    "ozonusercontent.com",
    "avito.com",
    "cian.com",
    "2gis.com",
]

DEFAULT_DIRECT_DOMAINS_FILE = Path(__file__).with_name("direct-domains-reestr.lst")

LOCAL_IPV4_CIDRS = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4",
]

VALID_ASCII_DOMAIN = re.compile(r"^[a-z0-9.-]+$")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-out", required=True)
    parser.add_argument("--priority-direct-domains-out", required=True)
    parser.add_argument("--direct-domains-out", required=True)
    parser.add_argument("--vpn-domains-out", required=True)
    parser.add_argument("--ru-ip-out", required=True)
    parser.add_argument("--vpn-ip-out", required=True)
    parser.add_argument("--direct-asn-ip-out", required=True)
    parser.add_argument("--local-ip-out", required=True)
    parser.add_argument("--server-if", required=True)
    parser.add_argument("--upstream-if", required=True)
    parser.add_argument("--direct-bind-interface", default="eth0")
    parser.add_argument("--tun-address", default="172.19.0.1/30")
    parser.add_argument("--dns-upstreams", required=True)
    parser.add_argument("--antifilter-domains", default="")
    parser.add_argument("--ru-zone", default="")
    parser.add_argument("--antifilter-ip", default="")
    parser.add_argument("--direct-asn-prefixes", default="")
    return parser.parse_args()


def parse_csv(value):
    items = []
    for item in value.split(","):
        item = item.strip()
        if item:
            items.append(item)
    return items


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

    if len(domain) > 253 or not VALID_ASCII_DOMAIN.fullmatch(domain):
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


def load_domain_suffixes(paths, seed=None):
    domains = set(seed or [])
    for path in paths:
        if not path:
            continue
        file_path = Path(path)
        if not file_path.is_file():
            continue
        with file_path.open(encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                domain = normalize_domain(line)
                if domain:
                    domains.add(domain)
    return sorted(domains)


def load_ipv4_cidrs(paths, seed=None):
    cidrs = set(seed or [])
    for path in paths:
        if not path:
            continue
        file_path = Path(path)
        if not file_path.is_file():
            continue
        with file_path.open(encoding="utf-8", errors="ignore") as handle:
            for raw_line in handle:
                line = raw_line.split("#", 1)[0].strip()
                if not line:
                    continue
                try:
                    network = ipaddress.ip_network(line, strict=False)
                except ValueError:
                    continue
                if network.version == 4:
                    cidrs.add(network.with_prefixlen)
    return sorted(cidrs, key=lambda item: (ipaddress.ip_network(item).network_address, ipaddress.ip_network(item).prefixlen))


def write_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def domain_rule_set(domains):
    if not domains:
        return {"version": 3, "rules": []}
    return {"version": 3, "rules": [{"domain_suffix": domains}]}


def select_priority_direct_domains(domains):
    return [domain for domain in domains if "." in domain]


def ip_rule_set(cidrs):
    if not cidrs:
        return {"version": 3, "rules": []}
    return {"version": 3, "rules": [{"ip_cidr": cidrs}]}


def binary_path(source_path):
    source = Path(source_path)
    return str(source.with_suffix(".srs"))


def build_config(args, dns_upstreams):
    dns_servers = []
    for index, upstream in enumerate(dns_upstreams, start=1):
        dns_servers.append(
            {
                "type": "udp",
                "tag": f"dns-upstream-{index}",
                "server": upstream,
                "server_port": 53,
                "bind_interface": args.direct_bind_interface,
            }
        )

    return {
        "log": {"level": "info"},
        "dns": {
            "servers": dns_servers,
            "final": dns_servers[0]["tag"],
            "strategy": "ipv4_only",
            "cache_capacity": 8192,
            "reverse_mapping": True,
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "sb-tun",
                "address": [args.tun_address],
                "mtu": 1280,
                "auto_route": True,
                "auto_redirect": True,
                "strict_route": True,
                "stack": "system",
                "include_interface": [args.server_if],
            }
        ],
        "outbounds": [
            {"type": "direct", "tag": "local-out"},
            {
                "type": "direct",
                "tag": "direct-out",
                "bind_interface": args.direct_bind_interface,
            },
            {
                "type": "direct",
                "tag": "vpn-out",
                "bind_interface": args.upstream_if,
            },
            {"type": "block", "tag": "block-out"},
        ],
        "route": {
            "default_domain_resolver": {
                "server": dns_servers[0]["tag"],
            },
            "rule_set": [
                {
                    "type": "local",
                    "tag": "local-ip",
                    "format": "binary",
                    "path": binary_path(args.local_ip_out),
                },
                {
                    "type": "local",
                    "tag": "ru-ip",
                    "format": "binary",
                    "path": binary_path(args.ru_ip_out),
                },
                {
                    "type": "local",
                    "tag": "vpn-ip",
                    "format": "binary",
                    "path": binary_path(args.vpn_ip_out),
                },
                {
                    "type": "local",
                    "tag": "direct-asn-ip",
                    "format": "binary",
                    "path": binary_path(args.direct_asn_ip_out),
                },
                {
                    "type": "local",
                    "tag": "priority-direct-domains",
                    "format": "binary",
                    "path": binary_path(args.priority_direct_domains_out),
                },
                {
                    "type": "local",
                    "tag": "direct-domains",
                    "format": "binary",
                    "path": binary_path(args.direct_domains_out),
                },
                {
                    "type": "local",
                    "tag": "vpn-domains",
                    "format": "binary",
                    "path": binary_path(args.vpn_domains_out),
                },
            ],
            "rules": [
                {"port": 53, "action": "hijack-dns"},
                {"action": "sniff", "timeout": "300ms"},
                {"rule_set": ["local-ip"], "action": "route", "outbound": "local-out"},
                {
                    "rule_set": ["priority-direct-domains"],
                    "action": "route",
                    "outbound": "direct-out",
                },
                {
                    "rule_set": ["vpn-ip", "vpn-domains"],
                    "action": "route",
                    "outbound": "vpn-out",
                },
                {
                    "rule_set": ["direct-asn-ip", "direct-domains", "ru-ip"],
                    "action": "route",
                    "outbound": "direct-out",
                },
            ],
            "final": "vpn-out",
        },
    }


def main():
    args = parse_args()
    dns_upstreams = parse_csv(args.dns_upstreams)
    if not dns_upstreams:
        raise SystemExit("at least one DNS upstream is required")

    direct_domains = load_domain_suffixes([DEFAULT_DIRECT_DOMAINS_FILE], DEFAULT_DIRECT_DOMAIN_SUFFIXES)
    priority_direct_domains = select_priority_direct_domains(direct_domains)
    vpn_domains = load_domain_suffixes([args.antifilter_domains])
    ru_cidrs = load_ipv4_cidrs([args.ru_zone])
    vpn_cidrs = load_ipv4_cidrs([args.antifilter_ip])
    direct_asn_cidrs = load_ipv4_cidrs([args.direct_asn_prefixes])
    local_cidrs = load_ipv4_cidrs([], LOCAL_IPV4_CIDRS)

    write_json(args.priority_direct_domains_out, domain_rule_set(priority_direct_domains))
    write_json(args.direct_domains_out, domain_rule_set(direct_domains))
    write_json(args.vpn_domains_out, domain_rule_set(vpn_domains))
    write_json(args.ru_ip_out, ip_rule_set(ru_cidrs))
    write_json(args.vpn_ip_out, ip_rule_set(vpn_cidrs))
    write_json(args.direct_asn_ip_out, ip_rule_set(direct_asn_cidrs))
    write_json(args.local_ip_out, ip_rule_set(local_cidrs))
    write_json(args.config_out, build_config(args, dns_upstreams))


if __name__ == "__main__":
    main()
