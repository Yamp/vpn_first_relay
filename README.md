# AWG split relay

Docker relay with two AmneziaWG interfaces:

- `awg-relay` accepts client connections.
- `awg-up` connects to the upstream AWG server from `config/upstream.conf`.
- IPv4 traffic to Russian networks is NATed directly through this host.
- Other public IPv4 traffic is policy-routed through `awg-up`.

The image is built from the official Amnezia repositories:

- `amnezia-vpn/amneziawg-go`
- `amnezia-vpn/amneziawg-tools`

## Repository Layout

```text
Dockerfile
docker-compose.yml
awg-versions.env
config/upstream.conf
admin/app.py
scripts/entrypoint.sh
scripts/install.sh
scripts/update-awg.sh
systemd/awg-relay-update.service
systemd/awg-relay-update.timer
```

Generated runtime files are intentionally not stored in git:

```text
.env
config/server/
config/clients/
config/managed-clients/
config/geoip/
config/routing/
config/admin.db
```

## Reproducible AWG Versions

`awg-versions.env` pins exact upstream commits:

```text
AMNEZIAWG_GO_COMMIT=...
AMNEZIAWG_TOOLS_COMMIT=...
```

`Dockerfile` reads this file and checks out those exact commits during build. A normal rebuild is therefore reproducible and does not silently move to a newer upstream version.

## Install

Run:

```bash
./scripts/install.sh
```

The install script:

- creates `.env` if it does not exist;
- sets `PUBLIC_ENDPOINT` from the server public IPv4 when possible;
- generates `ADMIN_USERNAME` and `ADMIN_PASSWORD` if they are missing;
- builds and starts the container with `sudo docker compose up -d --build`;
- installs a systemd timer for automatic AWG update checks.

If automatic public IP detection is not correct, edit `.env`:

```text
PUBLIC_ENDPOINT=your.server.ip.or.name:51820
SERVER_PORT=51820
ADMIN_PORT=8080
ADMIN_USERNAME=admin
ADMIN_PASSWORD=change-this-password
WARNING_BEFORE_HOURS=48
```

Then recreate the container:

```bash
sudo docker compose up -d --force-recreate
```

## Admin Panel

By default, the admin panel is exposed on host localhost only:

```text
http://127.0.0.1:8080/
```

To expose it on a specific host address, set `ADMIN_HOST` in `.env`:

```text
ADMIN_HOST=192.168.32.112
ADMIN_PORT=8080
```

Then recreate the container:

```bash
sudo docker compose up -d --force-recreate
```

It uses HTTP Basic Auth from `.env`:

```text
ADMIN_USERNAME=admin
ADMIN_PASSWORD=...
```

If you administer the server remotely, use an SSH tunnel:

```bash
ssh -L 8080:127.0.0.1:8080 user@server
```

Then open:

```text
http://127.0.0.1:8080/
```

The panel supports:

- issuing user config files;
- setting an expiration period for each config;
- automatic revocation when the expiration time is reached;
- extending an expired or active config by a specified number of days;
- manual revocation;
- per-config traffic for today and all time;
- per-config daily and all-time traffic limits;
- automatic revocation when a traffic limit is exceeded;
- editing the expiration warning email text in a separate page.

Traffic counters are collected from:

```bash
awg show awg-relay transfer
```

The panel stores counter deltas in:

```text
config/admin.db
```

Daily counters reset by the `Europe/Moscow` date.

## Client Configs

Generated managed client configs are stored in:

```text
config/managed-clients/
```

Download configs from the admin panel. Files are written with restrictive permissions.

## Email Warnings

The email text is edited in the admin panel page:

```text
Текст письма
```

Supported placeholders:

```text
{name}
{email}
{address}
{public_key}
{expires_at}
```

SMTP delivery is configured with environment variables in `.env`:

```text
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=user
SMTP_PASSWORD=password
SMTP_FROM=awg@example.com
SMTP_TLS=1
WARNING_BEFORE_HOURS=48
```

If `SMTP_HOST` or `SMTP_FROM` is empty, the panel keeps working but does not send warning emails.

The warning is sent once when a config has less than `WARNING_BEFORE_HOURS` before expiration.

## Legacy Client Config

Older generated files may still exist in:

```text
config/clients/
```

New configs should be issued through the admin panel.

## Upstream

The upstream config is stored in:

```text
config/upstream.conf
```

If you edit it, restart the relay:

```bash
sudo docker compose restart awg-relay
```

## GeoIP Split

The container downloads Russian IPv4 CIDR blocks from:

```text
https://www.ipdeny.com/ipblocks/data/countries/ru.zone
```

The cached list is stored at:

```text
config/geoip/ru.zone
```

On startup the cached list is reused if downloading fails. If no list is available, all public IPv4 traffic goes through the upstream AWG.

## Domain and Blocklist Split

In addition to GeoIP, the container starts an internal `dnsmasq` resolver. Managed client configs use the relay address as DNS by default, for example `10.77.0.1`. Existing managed config files are regenerated when the admin panel starts, so download them again after restarting the container.

DNS answers for these TLDs are added to `direct_domains4` and go directly through this host without the upstream AWG:

```text
.ru
.рф / .xn--p1ai
.gov
.su
```

These domains are also resolved directly:

```text
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
```

The container also creates an editable ASN allowlist at:

```text
config/routing/direct-asns.lst
```

On startup it downloads announced IPv4 prefixes for those ASNs from RIPEstat Announced Prefixes and caches the combined list at:

```text
config/routing/direct-asn-prefixes.zone
```

Those prefixes are loaded into `direct_asn4` and routed directly. This catches Russian-controlled platforms that use non-`.ru` domains or non-RU GeoIP ranges but announce traffic from their own ASNs. The default list is intentionally limited to platform, marketplace, banking, and content ASNs, not broad access-provider ASNs.

The container downloads the antifilter IP list on startup:

```text
https://antifilter.download/list/allyouneed.lst
```

`allyouneed.lst` is loaded into `vpn4`.

The antifilter domain list is disabled by default because it is very large and makes relay-local DNS heavier. To opt in, set:

```text
ANTIFILTER_DOMAINS_URL=https://antifilter.download/list/domains.lst
```

When enabled, domains from `domains.lst` are configured in `dnsmasq` so their resolved IPv4 addresses are added to `vpn_domains4`.

The route priority is:

```text
antifilter IP match -> upstream AWG
antifilter domain match, if enabled -> upstream AWG
curated ASN prefix match -> direct
private/special networks -> direct
.ru/.рф/.gov/.su DNS match -> direct
RU GeoIP match -> direct
everything else -> upstream AWG
```

You can override the list URLs and DNS forwarders in `.env`:

```text
ANTIFILTER_IP_URL=https://antifilter.download/list/allyouneed.lst
ANTIFILTER_DOMAINS_URL=
SPLIT_DNS_UPSTREAMS=1.1.1.1,8.8.8.8
DIRECT_ASNS_FILE=/config/routing/direct-asns.lst
DIRECT_ASN_PREFIXES_FILE=/config/routing/direct-asn-prefixes.zone
```

If you set `CLIENT_DNS` to an external resolver, domain-based split routing cannot see client DNS lookups. Leave `CLIENT_DNS` unset for the default relay-local DNS behavior.

## Automatic Updates

Updates are handled by:

```text
scripts/update-awg.sh
```

The script checks the refs in `awg-versions.env`:

```text
AMNEZIAWG_GO_REF=refs/heads/master
AMNEZIAWG_TOOLS_REF=refs/heads/master
```

If both resolved commit SHA values are unchanged, it exits without rebuilding and without restarting the container.

If either upstream commit changed, it:

- updates `awg-versions.env`;
- rebuilds the image;
- recreates only `awg-relay`.

Manual update check:

```bash
./scripts/update-awg.sh
```

## 03:00 Moscow Timer

`scripts/install.sh` installs this timer:

```text
systemd/awg-relay-update.timer
```

It runs every day at 03:00 Moscow time:

```text
OnCalendar=*-*-* 03:00:00 Europe/Moscow
```

Check timer status:

```bash
sudo systemctl status awg-relay-update.timer
sudo systemctl list-timers --all awg-relay-update.timer
```

Run the update job immediately:

```bash
sudo systemctl start awg-relay-update.service
```

View logs:

```bash
journalctl -u awg-relay-update.service -n 100 --no-pager
```

## Verification

Container status:

```bash
sudo docker compose ps
```

AWG state:

```bash
sudo docker compose exec -T awg-relay awg show
```

Split routing:

```bash
sudo docker compose exec -T awg-relay ip rule show
sudo docker compose exec -T awg-relay ip route show table 100
sudo docker compose exec -T awg-relay iptables -t mangle -S AWG_SPLIT
sudo docker compose exec -T awg-relay ipset list ru4 | sed -n '1,8p'
sudo docker compose exec -T awg-relay ipset list direct_asn4 | sed -n '1,8p'
sudo docker compose exec -T awg-relay ipset list vpn4 | sed -n '1,8p'
sudo docker compose exec -T awg-relay ipset list direct_domains4 | sed -n '1,8p'
sudo docker compose exec -T awg-relay ipset list vpn_domains4 | sed -n '1,8p'
```

## Notes

This setup handles IPv4 split routing. IPv6 is disabled in `docker-compose.yml` because the supplied upstream config has only an IPv4 interface address.

The container needs `/dev/net/tun`, `NET_ADMIN`, and `NET_RAW` to create TUN devices, manage routing, and install iptables/ipset rules.
