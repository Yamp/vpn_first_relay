#!/usr/bin/env python3
import base64
import datetime as dt
import html
import ipaddress
import os
import re
import shlex
import smtplib
import sqlite3
import subprocess
import threading
import time
import urllib.parse
from email.message import EmailMessage
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo


CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/config"))
DB_PATH = CONFIG_DIR / "admin.db"
CLIENTS_DIR = CONFIG_DIR / "managed-clients"
SERVER_IF = os.environ.get("SERVER_IF", "awg-relay")
SERVER_PUBLIC_KEY = (CONFIG_DIR / "server" / "publickey").read_text().strip()
PUBLIC_ENDPOINT = os.environ.get("PUBLIC_ENDPOINT", "CHANGE_ME_HOST_OR_IP:51820")
SERVER_ADDRESS = os.environ.get("SERVER_ADDRESS", "10.77.0.1/24")
CLIENT_DNS = os.environ.get("CLIENT_DNS") or str(ipaddress.ip_interface(SERVER_ADDRESS).ip)
CLIENT_SUBNET = ipaddress.ip_network(os.environ.get("CLIENT_SUBNET", "10.77.0.0/24"), strict=False)
SERVER_JC = os.environ.get("SERVER_JC", "4")
SERVER_JMIN = os.environ.get("SERVER_JMIN", "8")
SERVER_JMAX = os.environ.get("SERVER_JMAX", "80")
SERVER_S1 = os.environ.get("SERVER_S1", "64")
SERVER_S2 = os.environ.get("SERVER_S2", "128")
SERVER_S3 = os.environ.get("SERVER_S3", "32")
SERVER_S4 = os.environ.get("SERVER_S4", "32")
SERVER_H1 = os.environ.get("SERVER_H1", "123456701")
SERVER_H2 = os.environ.get("SERVER_H2", "123456702")
SERVER_H3 = os.environ.get("SERVER_H3", "123456703")
SERVER_H4 = os.environ.get("SERVER_H4", "123456704")
ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
WARNING_BEFORE_HOURS = int(os.environ.get("WARNING_BEFORE_HOURS", "48"))
TZ = ZoneInfo("Europe/Moscow")
LOCK = threading.RLock()

DEFAULT_EMAIL_TEMPLATE = """Здравствуйте, {name}.

Ваш AWG-конфиг для адреса {address} истекает {expires_at}.
Если доступ нужен дольше, обратитесь к администратору.
"""


def now():
    return dt.datetime.now(TZ)


def today_key():
    return now().date().isoformat()


def iso(ts):
    if isinstance(ts, dt.datetime):
        return ts.astimezone(TZ).replace(microsecond=0).isoformat()
    return ts


def parse_iso(value):
    return dt.datetime.fromisoformat(value).astimezone(TZ)


def run(*args, input_text=None):
    result = subprocess.run(
        args,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return result.stdout.strip()


def awg(*args, input_text=None):
    return run("awg", *args, input_text=input_text)


def db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CLIENTS_DIR.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.executescript(
            """
            create table if not exists clients (
              id integer primary key autoincrement,
              name text not null,
              email text not null default '',
              private_key text not null,
              public_key text not null unique,
              address text not null unique,
              created_at text not null,
              expires_at text not null,
              revoked_at text,
              revoked_reason text,
              warning_sent_at text,
              daily_limit_bytes integer,
              total_limit_bytes integer,
              rx_today integer not null default 0,
              tx_today integer not null default 0,
              rx_total integer not null default 0,
              tx_total integer not null default 0,
              last_rx integer not null default 0,
              last_tx integer not null default 0,
              today_date text not null
            );
            create table if not exists settings (
              key text primary key,
              value text not null
            );
            """
        )
        conn.execute(
            "insert or ignore into settings(key, value) values (?, ?)",
            ("email_template", DEFAULT_EMAIL_TEMPLATE),
        )


def get_setting(key, default=""):
    with db() as conn:
        row = conn.execute("select value from settings where key = ?", (key,)).fetchone()
        return row["value"] if row else default


def set_setting(key, value):
    with db() as conn:
        conn.execute(
            "insert into settings(key, value) values (?, ?) on conflict(key) do update set value = excluded.value",
            (key, value),
        )


def format_bytes(value):
    value = int(value or 0)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{value} B"
        size /= 1024


def parse_bytes(value):
    value = (value or "").strip()
    if not value:
        return None
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([kmgt]?i?b?|[kmgt])?", value, re.I)
    if not m:
        raise ValueError("Traffic limit must look like 500M, 2G, or bytes")
    amount = float(m.group(1))
    unit = (m.group(2) or "b").lower()
    mult = {
        "b": 1,
        "": 1,
        "k": 1024,
        "kb": 1024,
        "kib": 1024,
        "m": 1024**2,
        "mb": 1024**2,
        "mib": 1024**2,
        "g": 1024**3,
        "gb": 1024**3,
        "gib": 1024**3,
        "t": 1024**4,
        "tb": 1024**4,
        "tib": 1024**4,
    }[unit]
    return int(amount * mult)


def make_keypair():
    private_key = awg("genkey")
    public_key = awg("pubkey", input_text=private_key + "\n")
    return private_key, public_key


def next_address(conn):
    used = {
        ipaddress.ip_interface(row["address"]).ip
        for row in conn.execute("select address from clients")
    }
    hosts = list(CLIENT_SUBNET.hosts())
    for ip in hosts[1:]:
        if ip not in used:
            return f"{ip}/32"
    raise RuntimeError("No free client addresses in CLIENT_SUBNET")


def client_config(private_key, address):
    return f"""[Interface]
PrivateKey = {private_key}
Address = {address}
DNS = {CLIENT_DNS}
MTU = 1280
Jc = {SERVER_JC}
Jmin = {SERVER_JMIN}
Jmax = {SERVER_JMAX}
S1 = {SERVER_S1}
S2 = {SERVER_S2}
S3 = {SERVER_S3}
S4 = {SERVER_S4}
H1 = {SERVER_H1}
H2 = {SERVER_H2}
H3 = {SERVER_H3}
H4 = {SERVER_H4}

[Peer]
PublicKey = {SERVER_PUBLIC_KEY}
Endpoint = {PUBLIC_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"""


def config_path(client_id):
    return CLIENTS_DIR / f"{client_id}.conf"


def write_client_config_file(client_id, private_key, address):
    path = config_path(client_id)
    path.write_text(client_config(private_key, address))
    os.chmod(path, 0o600)


def refresh_client_config_files():
    with db() as conn:
        rows = conn.execute("select id, private_key, address from clients").fetchall()
    for row in rows:
        write_client_config_file(row["id"], row["private_key"], row["address"])


def add_peer(public_key, address):
    awg("set", SERVER_IF, "peer", public_key, "allowed-ips", address)


def remove_peer(public_key):
    try:
        awg("set", SERVER_IF, "peer", public_key, "remove")
    except subprocess.CalledProcessError:
        pass


def revoke_client(client_id, reason):
    with LOCK, db() as conn:
        row = conn.execute("select * from clients where id = ?", (client_id,)).fetchone()
        if not row or row["revoked_at"]:
            return
        remove_peer(row["public_key"])
        conn.execute(
            "update clients set revoked_at = ?, revoked_reason = ? where id = ?",
            (iso(now()), reason, client_id),
        )


def restore_active_peers():
    with db() as conn:
        rows = conn.execute("select * from clients where revoked_at is null").fetchall()
    for row in rows:
        if parse_iso(row["expires_at"]) <= now():
            revoke_client(row["id"], "expired")
        else:
            add_peer(row["public_key"], row["address"])


def read_transfers():
    try:
        output = awg("show", SERVER_IF, "transfer")
    except subprocess.CalledProcessError:
        return {}
    transfers = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) == 3:
            transfers[parts[0]] = (int(parts[1]), int(parts[2]))
    return transfers


def collect_traffic_once():
    transfers = read_transfers()
    if not transfers:
        return
    current_day = today_key()
    with LOCK, db() as conn:
        rows = conn.execute("select * from clients where revoked_at is null").fetchall()
        for row in rows:
            if row["public_key"] not in transfers:
                continue
            rx, tx = transfers[row["public_key"]]
            last_rx, last_tx = row["last_rx"], row["last_tx"]
            delta_rx = rx - last_rx if rx >= last_rx else rx
            delta_tx = tx - last_tx if tx >= last_tx else tx
            rx_today = row["rx_today"]
            tx_today = row["tx_today"]
            if row["today_date"] != current_day:
                rx_today = 0
                tx_today = 0
            rx_today += max(delta_rx, 0)
            tx_today += max(delta_tx, 0)
            rx_total = row["rx_total"] + max(delta_rx, 0)
            tx_total = row["tx_total"] + max(delta_tx, 0)
            conn.execute(
                """
                update clients
                set rx_today = ?, tx_today = ?, rx_total = ?, tx_total = ?,
                    last_rx = ?, last_tx = ?, today_date = ?
                where id = ?
                """,
                (rx_today, tx_today, rx_total, tx_total, rx, tx, current_day, row["id"]),
            )
            daily_limit = row["daily_limit_bytes"]
            total_limit = row["total_limit_bytes"]
            if daily_limit is not None and rx_today + tx_today >= daily_limit:
                conn.commit()
                revoke_client(row["id"], "daily traffic limit exceeded")
            elif total_limit is not None and rx_total + tx_total >= total_limit:
                conn.commit()
                revoke_client(row["id"], "total traffic limit exceeded")


def send_expiry_email(row):
    if not row["email"]:
        return False
    smtp_host = os.environ.get("SMTP_HOST", "")
    smtp_from = os.environ.get("SMTP_FROM", "")
    if not smtp_host or not smtp_from:
        return False
    template = get_setting("email_template", DEFAULT_EMAIL_TEMPLATE)
    context = {
        "name": row["name"],
        "email": row["email"],
        "address": row["address"],
        "public_key": row["public_key"],
        "expires_at": row["expires_at"],
    }
    body = template.format(**context)
    msg = EmailMessage()
    msg["From"] = smtp_from
    msg["To"] = row["email"]
    msg["Subject"] = "Срок действия AWG-конфига скоро истекает"
    msg.set_content(body)
    port = int(os.environ.get("SMTP_PORT", "587"))
    username = os.environ.get("SMTP_USERNAME", "")
    password = os.environ.get("SMTP_PASSWORD", "")
    use_tls = os.environ.get("SMTP_TLS", "1") == "1"
    with smtplib.SMTP(smtp_host, port, timeout=20) as smtp:
        if use_tls:
            smtp.starttls()
        if username:
            smtp.login(username, password)
        smtp.send_message(msg)
    return True


def enforce_once():
    threshold = now() + dt.timedelta(hours=WARNING_BEFORE_HOURS)
    with LOCK, db() as conn:
        rows = conn.execute("select * from clients where revoked_at is null").fetchall()
    for row in rows:
        expires_at = parse_iso(row["expires_at"])
        if expires_at <= now():
            revoke_client(row["id"], "expired")
            continue
        if expires_at <= threshold and not row["warning_sent_at"]:
            sent = False
            try:
                sent = send_expiry_email(row)
            except Exception as exc:
                print(f"Failed to send expiry email to {row['email']}: {exc}", flush=True)
            if sent:
                with db() as conn:
                    conn.execute(
                        "update clients set warning_sent_at = ? where id = ?",
                        (iso(now()), row["id"]),
                    )


def background_loop():
    while True:
        try:
            collect_traffic_once()
            enforce_once()
        except Exception as exc:
            print(f"admin background error: {exc}", flush=True)
        time.sleep(30)


def h(value):
    return html.escape(str(value or ""), quote=True)


def redirect(handler, path):
    handler.send_response(HTTPStatus.SEE_OTHER)
    handler.send_header("Location", path)
    handler.end_headers()


def parse_form(handler):
    length = int(handler.headers.get("Content-Length", "0"))
    data = handler.rfile.read(length).decode()
    return {k: v[-1] for k, v in urllib.parse.parse_qs(data).items()}


def require_auth(handler):
    if not ADMIN_PASSWORD:
        return True
    header = handler.headers.get("Authorization", "")
    expected = base64.b64encode(f"{ADMIN_USERNAME}:{ADMIN_PASSWORD}".encode()).decode()
    if header == f"Basic {expected}":
        return True
    handler.send_response(HTTPStatus.UNAUTHORIZED)
    handler.send_header("WWW-Authenticate", 'Basic realm="AWG admin"')
    handler.end_headers()
    return False


PAGE_HEAD = """<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AWG admin</title>
<style>
body{font-family:Arial,sans-serif;margin:0;background:#f6f7f8;color:#182026}
header{background:#17324d;color:white;padding:16px 24px}
main{padding:24px;max-width:1280px;margin:0 auto}
nav a{color:white;margin-right:16px}
section{background:white;border:1px solid #d9dee3;border-radius:8px;padding:18px;margin-bottom:18px}
table{width:100%;border-collapse:collapse;background:white}
th,td{border-bottom:1px solid #e3e7eb;padding:8px;text-align:left;vertical-align:top}
input,textarea,button{font:inherit;padding:8px;border:1px solid #bcc5cf;border-radius:6px}
textarea{width:100%;min-height:220px}
button{background:#1f6feb;color:white;border-color:#1f6feb;cursor:pointer}
.danger{background:#b42318;border-color:#b42318}
.muted{color:#64748b}
.inline{display:inline}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
.ok{color:#067647}.bad{color:#b42318}
</style>
</head>
<body><header><h1>AWG admin</h1><nav><a href="/">Конфиги</a><a href="/new">Выдать конфиг</a><a href="/email-template">Текст письма</a></nav></header><main>
"""
PAGE_FOOT = "</main></body></html>"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    def send_html(self, body, status=HTTPStatus.OK):
        data = (PAGE_HEAD + body + PAGE_FOOT).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not require_auth(self):
            return
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            self.index()
        elif path == "/new":
            self.new_form()
        elif path == "/email-template":
            self.email_template_form()
        elif path.startswith("/download/"):
            self.download(path.rsplit("/", 1)[-1])
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if not require_auth(self):
            return
        path = urllib.parse.urlparse(self.path).path
        try:
            if path == "/create":
                self.create()
            elif path.startswith("/revoke/"):
                self.revoke(path.rsplit("/", 1)[-1])
            elif path.startswith("/extend/"):
                self.extend(path.rsplit("/", 1)[-1])
            elif path.startswith("/limits/"):
                self.update_limits(path.rsplit("/", 1)[-1])
            elif path == "/email-template":
                form = parse_form(self)
                set_setting("email_template", form.get("template", ""))
                redirect(self, "/email-template")
            else:
                self.send_error(HTTPStatus.NOT_FOUND)
        except Exception as exc:
            self.send_html(f"<section><h2>Ошибка</h2><p class='bad'>{h(exc)}</p></section>", HTTPStatus.BAD_REQUEST)

    def index(self):
        collect_traffic_once()
        with db() as conn:
            rows = conn.execute("select * from clients order by id desc").fetchall()
        body = "<section><h2>Выданные конфиги</h2><table><tr><th>ID</th><th>Пользователь</th><th>Срок</th><th>Трафик сегодня</th><th>Трафик всего</th><th>Лимиты</th><th>Действия</th></tr>"
        for row in rows:
            status = "<span class='ok'>активен</span>" if not row["revoked_at"] else f"<span class='bad'>отозван: {h(row['revoked_reason'])}</span>"
            daily_total = row["rx_today"] + row["tx_today"]
            all_total = row["rx_total"] + row["tx_total"]
            daily_limit = "без лимита" if row["daily_limit_bytes"] is None else format_bytes(row["daily_limit_bytes"])
            total_limit = "без лимита" if row["total_limit_bytes"] is None else format_bytes(row["total_limit_bytes"])
            body += f"""
            <tr>
              <td>{row['id']}<br>{status}</td>
              <td><b>{h(row['name'])}</b><br>{h(row['email'])}<br><span class="muted">{h(row['address'])}</span></td>
              <td>{h(row['expires_at'])}<br><span class="muted">warning: {h(row['warning_sent_at'] or '-')}</span></td>
              <td>in {format_bytes(row['rx_today'])}<br>out {format_bytes(row['tx_today'])}<br><b>{format_bytes(daily_total)}</b></td>
              <td>in {format_bytes(row['rx_total'])}<br>out {format_bytes(row['tx_total'])}<br><b>{format_bytes(all_total)}</b></td>
              <td>
                <form method="post" action="/limits/{row['id']}">
                  <input name="daily_limit" placeholder="сутки" value="{'' if row['daily_limit_bytes'] is None else h(row['daily_limit_bytes'])}">
                  <input name="total_limit" placeholder="все время" value="{'' if row['total_limit_bytes'] is None else h(row['total_limit_bytes'])}">
                  <button>Сохранить</button>
                </form>
                <span class="muted">сутки: {daily_limit}; всего: {total_limit}</span>
              </td>
              <td>
                <a href="/download/{row['id']}">Скачать</a>
                <form class="inline" method="post" action="/extend/{row['id']}">
                  <input name="days" value="30" size="4"> дней
                  <button>Продлить</button>
                </form>
                <form class="inline" method="post" action="/revoke/{row['id']}">
                  <button class="danger">Отозвать</button>
                </form>
              </td>
            </tr>
            """
        body += "</table></section>"
        self.send_html(body)

    def new_form(self):
        body = """
        <section><h2>Выдать конфиг</h2>
        <form method="post" action="/create">
          <div class="grid">
            <label>Имя<br><input name="name" required></label>
            <label>Email<br><input name="email" type="email"></label>
            <label>Срок, дней<br><input name="days" type="number" min="1" value="30" required></label>
            <label>Лимит за сутки<br><input name="daily_limit" placeholder="например 10G"></label>
            <label>Лимит за все время<br><input name="total_limit" placeholder="например 100G"></label>
          </div>
          <p><button>Создать</button></p>
        </form></section>
        """
        self.send_html(body)

    def create(self):
        form = parse_form(self)
        name = form.get("name", "").strip()
        email = form.get("email", "").strip()
        days = int(form.get("days", "0"))
        if not name or days <= 0:
            raise ValueError("Name and positive period are required")
        daily_limit = parse_bytes(form.get("daily_limit", ""))
        total_limit = parse_bytes(form.get("total_limit", ""))
        private_key, public_key = make_keypair()
        created = now()
        expires = created + dt.timedelta(days=days)
        with LOCK, db() as conn:
            address = next_address(conn)
            cur = conn.execute(
                """
                insert into clients(
                  name, email, private_key, public_key, address, created_at, expires_at,
                  daily_limit_bytes, total_limit_bytes, today_date
                ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (name, email, private_key, public_key, address, iso(created), iso(expires), daily_limit, total_limit, today_key()),
            )
            client_id = cur.lastrowid
            write_client_config_file(client_id, private_key, address)
            add_peer(public_key, address)
        redirect(self, f"/download/{client_id}")

    def revoke(self, raw_id):
        revoke_client(int(raw_id), "manual revoke")
        redirect(self, "/")

    def extend(self, raw_id):
        form = parse_form(self)
        days = int(form.get("days", "0"))
        if days <= 0:
            raise ValueError("Extension period must be positive")
        with LOCK, db() as conn:
            row = conn.execute("select * from clients where id = ?", (int(raw_id),)).fetchone()
            if not row:
                raise ValueError("Client not found")
            base = max(now(), parse_iso(row["expires_at"]))
            expires = base + dt.timedelta(days=days)
            conn.execute(
                "update clients set expires_at = ?, warning_sent_at = null where id = ?",
                (iso(expires), int(raw_id)),
            )
            if row["revoked_at"] and row["revoked_reason"] == "expired":
                add_peer(row["public_key"], row["address"])
                conn.execute("update clients set revoked_at = null, revoked_reason = null where id = ?", (int(raw_id),))
        redirect(self, "/")

    def update_limits(self, raw_id):
        form = parse_form(self)
        daily_limit = parse_bytes(form.get("daily_limit", ""))
        total_limit = parse_bytes(form.get("total_limit", ""))
        with db() as conn:
            conn.execute(
                "update clients set daily_limit_bytes = ?, total_limit_bytes = ? where id = ?",
                (daily_limit, total_limit, int(raw_id)),
            )
        redirect(self, "/")

    def download(self, raw_id):
        path = config_path(int(raw_id))
        if not path.exists():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="awg-client-{int(raw_id)}.conf"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def email_template_form(self):
        template = get_setting("email_template", DEFAULT_EMAIL_TEMPLATE)
        smtp_ready = "настроен" if os.environ.get("SMTP_HOST") and os.environ.get("SMTP_FROM") else "не настроен"
        body = f"""
        <section><h2>Текст письма</h2>
        <p class="muted">SMTP: {smtp_ready}. Доступные переменные: {{name}}, {{email}}, {{address}}, {{public_key}}, {{expires_at}}.</p>
        <form method="post" action="/email-template">
          <textarea name="template">{h(template)}</textarea>
          <p><button>Сохранить текст</button></p>
        </form></section>
        """
        self.send_html(body)


def main():
    if not ADMIN_PASSWORD:
        print("WARNING: ADMIN_PASSWORD is empty; admin panel is not protected", flush=True)
    init_db()
    refresh_client_config_files()
    restore_active_peers()
    threading.Thread(target=background_loop, daemon=True).start()
    host = os.environ.get("ADMIN_LISTEN_HOST", "0.0.0.0")
    port = int(os.environ.get("ADMIN_LISTEN_PORT", "8080"))
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"AWG admin listening on {host}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
