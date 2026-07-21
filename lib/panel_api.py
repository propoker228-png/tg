#!/usr/bin/env python3
"""telemt-deploy panel API — stdlib only."""
from __future__ import annotations

import base64
import json
import os
import socket
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

METRICS_DIR = Path(os.environ.get("PANEL_METRICS_DIR", "/var/lib/telemt-deploy/metrics"))
CLUSTER_FILE = Path(os.environ.get("PANEL_CLUSTER_FILE", "/etc/telemt-deploy.cluster"))
NODES_FILE = Path(os.environ.get("PANEL_NODES_FILE", "/etc/telemt-deploy.cluster.nodes"))
TOKENS_FILE = Path(os.environ.get("PANEL_TOKENS_FILE", "/etc/telemt-deploy.cluster.tokens"))
CREDENTIALS_FILE = Path(os.environ.get("PANEL_CREDENTIALS_FILE", "/etc/telemt-deploy.panel"))
SECRET_FILE = Path(os.environ.get("PANEL_SECRET_FILE", "/etc/telemt-deploy.secret"))
DEPLOY_ROOT = os.environ.get("PANEL_DEPLOY_ROOT", "/opt/telemt-deploy")
API_HOST = os.environ.get("PANEL_API_HOST", "127.0.0.1")
API_PORT = int(os.environ.get("PANEL_API_PORT", "19091"))


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_iso(ts: str) -> datetime | None:
    if not ts:
        return None
    try:
        if ts.endswith("Z"):
            ts = ts[:-1] + "+00:00"
        return datetime.fromisoformat(ts).astimezone(timezone.utc)
    except ValueError:
        return None


def load_panel_credentials() -> tuple[str, str]:
    user = os.environ.get("PANEL_USER", "")
    password = os.environ.get("PANEL_PASS", "")
    if CREDENTIALS_FILE.is_file():
        for line in CREDENTIALS_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("PANEL_USER="):
                user = line.split("=", 1)[1]
            elif line.startswith("PANEL_PASS="):
                password = line.split("=", 1)[1]
    return user, password


def load_cluster_domain() -> str:
    if not CLUSTER_FILE.is_file():
        return ""
    for line in CLUSTER_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("CLUSTER_DOMAIN="):
            return line.split("=", 1)[1]
    return ""


def load_secret() -> str:
    if SECRET_FILE.is_file():
        return SECRET_FILE.read_text(encoding="utf-8").strip()
    return os.environ.get("SECRET", "")


def load_tokens() -> dict[str, str]:
    tokens: dict[str, str] = {}
    if not TOKENS_FILE.is_file():
        return tokens
    for line in TOKENS_FILE.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split()
        if len(parts) >= 2:
            tokens[parts[0]] = parts[1]
    return tokens


def token_for_node(node: str) -> str | None:
    return load_tokens().get(node)


def load_nodes() -> list[dict[str, object]]:
    nodes: list[dict[str, object]] = []
    if not NODES_FILE.is_file():
        return nodes
    for line in NODES_FILE.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split()
        if len(parts) >= 2:
            port = int(parts[2]) if len(parts) >= 3 else 443
            nodes.append({"name": parts[0], "ip": parts[1], "port": port})
    return nodes


def load_metrics(node: str) -> dict:
    path = METRICS_DIR / f"{node}.json"
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def node_status(last_seen_sec: int | None) -> str:
    if last_seen_sec is None:
        return "offline"
    if last_seen_sec < 30:
        return "online"
    if last_seen_sec < 120:
        return "stale"
    return "offline"


def tcp_check(ip: str, port: int, timeout: float = 3.0) -> bool:
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def build_proxy_link(domain: str, secret: str) -> str:
    if not domain or not secret:
        return ""
    if secret.startswith("ee") or secret.startswith("dd"):
        ee = secret
    else:
        ee = "ee" + domain.encode().hex() + secret
    query = urllib.parse.urlencode({"server": domain, "port": "443", "secret": ee})
    return f"tg://proxy?{query}"


def build_cluster_payload() -> dict:
    domain = load_cluster_domain()
    secret = load_secret()
    now = _utc_now()
    nodes_out = []
    total_people = 0
    total_tcp = 0

    for node in load_nodes():
        name = str(node["name"])
        ip = str(node["ip"])
        port = int(node["port"])
        metrics = load_metrics(name)

        people = int(metrics.get("people", 0) or 0)
        tcp = int(metrics.get("tcp", 0) or 0)
        telemt_active = bool(metrics.get("telemt_active", False))

        received_at = metrics.get("received_at")
        last_seen_sec = None
        if received_at:
            dt = _parse_iso(str(received_at))
            if dt:
                last_seen_sec = max(0, int((now - dt).total_seconds()))

        nodes_out.append(
            {
                "name": name,
                "ip": ip,
                "port": port,
                "haproxy_up": tcp_check(ip, port),
                "people": people,
                "tcp": tcp,
                "telemt_active": telemt_active,
                "last_seen_sec": last_seen_sec,
                "status": node_status(last_seen_sec),
            }
        )
        total_people += people
        total_tcp += tcp

    return {
        "cluster_domain": domain,
        "proxy_link": build_proxy_link(domain, secret),
        "nodes": nodes_out,
        "totals": {"people": total_people, "tcp": total_tcp},
    }


def run_migrate(domain: str) -> tuple[int, str]:
    stub = os.environ.get("PANEL_MIGRATE_STUB")
    if stub:
        Path(stub).write_text(domain, encoding="utf-8")
        return 0, json.dumps({"ok": True, "domain": domain})

    migrate_sh = Path(DEPLOY_ROOT) / "lib" / "cluster_migrate.sh"
    if not migrate_sh.is_file():
        return 1, "cluster_migrate.sh not installed"

    cmd = [
        "bash",
        "-c",
        f'source "{DEPLOY_ROOT}/lib/common.sh" && '
        f'source "{migrate_sh}" && cluster_migrate_domain_cli "$1"',
        "_",
        domain,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return proc.returncode, proc.stderr.strip() or proc.stdout.strip() or "migrate failed"
    return 0, proc.stdout.strip() or json.dumps({"ok": True, "domain": domain})


class PanelHandler(BaseHTTPRequestHandler):
    server_version = "telemt-panel/1.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _send_json(self, code: int, payload: dict | list) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, code: int, message: str) -> None:
        body = message.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _check_basic_auth(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="telemt-panel"')
            self.end_headers()
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8")
            user, _, password = decoded.partition(":")
        except (ValueError, UnicodeDecodeError):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="telemt-panel"')
            self.end_headers()
            return False
        expected_user, expected_pass = load_panel_credentials()
        if user != expected_user or password != expected_pass:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="telemt-panel"')
            self.end_headers()
            return False
        return True

    def _check_bearer(self, node: str) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return False
        token = header[7:].strip()
        expected = token_for_node(node)
        return bool(expected and token == expected)

    def handle_metrics(self) -> None:
        try:
            payload = json.loads(self._read_body().decode("utf-8") or "{}")
        except json.JSONDecodeError:
            self._send_text(400, "invalid json")
            return

        node = str(payload.get("node", "")).strip()
        if not node:
            self._send_text(400, "node required")
            return
        if not self._check_bearer(node):
            self._send_text(401, "unauthorized")
            return

        METRICS_DIR.mkdir(parents=True, exist_ok=True)
        record = {
            "node": node,
            "people": int(payload.get("people", 0) or 0),
            "tcp": int(payload.get("tcp", 0) or 0),
            "telemt_active": bool(payload.get("telemt_active", False)),
            "ts": payload.get("ts") or _utc_now().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "received_at": _utc_now().strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        out = METRICS_DIR / f"{node}.json"
        out.write_text(json.dumps(record), encoding="utf-8")
        self._send_json(200, {"ok": True})

    def handle_cluster(self) -> None:
        if not self._check_basic_auth():
            return
        self._send_json(200, build_cluster_payload())

    def handle_migrate(self) -> None:
        if not self._check_basic_auth():
            return
        try:
            payload = json.loads(self._read_body().decode("utf-8") or "{}")
        except json.JSONDecodeError:
            self._send_text(400, "invalid json")
            return
        domain = str(payload.get("domain", "")).strip()
        if not domain:
            self._send_text(400, "domain required")
            return
        code, message = run_migrate(domain)
        if code != 0:
            self._send_text(500, message)
            return
        try:
            body = json.loads(message)
        except json.JSONDecodeError:
            body = {"ok": True, "message": message}
        self._send_json(200, body)

    def do_GET(self) -> None:
        if self.path == "/api/v1/cluster":
            return self.handle_cluster()
        self.send_error(404)

    def do_POST(self) -> None:
        if self.path == "/api/v1/metrics":
            return self.handle_metrics()
        if self.path == "/api/v1/domain/migrate":
            return self.handle_migrate()
        self.send_error(404)


def main() -> None:
    METRICS_DIR.mkdir(parents=True, exist_ok=True)
    server = HTTPServer((API_HOST, API_PORT), PanelHandler)
    print(f"panel API listening on {API_HOST}:{API_PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
