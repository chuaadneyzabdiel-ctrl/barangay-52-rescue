#!/usr/bin/env python3
"""Local barangay + LGU account admin. Binds to 127.0.0.1:8788. Writes Firebase RTDB only."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

HOST = "127.0.0.1"
PORT = 8788
HERE = Path(__file__).resolve().parent
STATIC = HERE / "static"

RTDB = os.environ.get(
    "BARANGAY_ADMIN_RTDB",
    "https://rescue-app-c79cf-default-rtdb.asia-southeast1.firebasedatabase.app",
).rstrip("/")

DEFAULT_BARANGAYS = [
    {
        "id": "52",
        "name": "Barangay 52",
        "isActive": True,
        "neighbors": ["53", "54", "55"],
        "mapCenter": {"lat": 14.6470319, "lng": 120.9768745},
    },
    {
        "id": "53",
        "name": "Barangay 53",
        "isActive": False,
        "neighbors": ["52", "54"],
        "mapCenter": {"lat": 14.6482, "lng": 120.9781},
    },
    {
        "id": "54",
        "name": "Barangay 54",
        "isActive": False,
        "neighbors": ["52", "53", "55"],
        "mapCenter": {"lat": 14.6459, "lng": 120.9756},
    },
    {
        "id": "55",
        "name": "Barangay 55",
        "isActive": False,
        "neighbors": ["52", "54"],
        "mapCenter": {"lat": 14.6491, "lng": 120.9762},
    },
]

DEMO_LGU_USER = "brgy52"
DEMO_LGU_PASSWORD = "Brgy52Admin1"


def _json(data) -> bytes:
    return json.dumps(data).encode("utf-8")


def rtdb(path: str, method: str = "GET", body=None):
    url = f"{RTDB}/{path.lstrip('/')}.json"
    payload = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=payload, method=method)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw and raw != "null" else None
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Firebase {method} {path} failed: {exc.code} {detail}") from exc


def hash_password(password: str, salt: str) -> str:
    return hashlib.sha256(f"{salt}::{password}".encode("utf-8")).hexdigest()


def new_salt() -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(16)).decode("ascii")


def parse_neighbors(raw) -> list[str]:
    if isinstance(raw, str):
        parts = [p.strip() for p in raw.replace(";", ",").split(",")]
        return [p for p in parts if p]
    if isinstance(raw, list):
        out = []
        for item in raw:
            text = str(item).strip()
            if text and text not in out:
                out.append(text)
        return out
    return []


def normalize_barangay(body: dict, fallback_id: str = "") -> dict:
    barangay_id = str(body.get("id") or fallback_id).strip()
    if not barangay_id:
        raise ValueError("Barangay id is required.")
    name = str(body.get("name") or f"Barangay {barangay_id}").strip()
    center = body.get("mapCenter") if isinstance(body.get("mapCenter"), dict) else {}
    lat = center.get("lat", body.get("lat", 14.6470319))
    lng = center.get("lng", body.get("lng", 120.9768745))
    return {
        "id": barangay_id,
        "name": name or f"Barangay {barangay_id}",
        "isActive": body.get("isActive") is True or body.get("isActive") == "true",
        "neighbors": parse_neighbors(body.get("neighbors")),
        "mapCenter": {"lat": float(lat), "lng": float(lng)},
    }


def public_account(username: str, row: dict) -> dict:
    return {
        "username": username,
        "barangayId": str(row.get("barangayId") or "52"),
        "isActive": row.get("isActive") is True,
        "updatedAt": row.get("updatedAt"),
        "createdAt": row.get("createdAt"),
    }


def seed_defaults() -> dict:
    created = {"barangays": [], "accounts": []}
    existing_barangays = rtdb("barangays") or {}
    if not isinstance(existing_barangays, dict):
        existing_barangays = {}
    for barangay in DEFAULT_BARANGAYS:
        if barangay["id"] in existing_barangays:
            continue
        rtdb(f"barangays/{barangay['id']}", "PUT", barangay)
        created["barangays"].append(barangay["id"])

    existing_accounts = rtdb("lgu_accounts") or {}
    if not isinstance(existing_accounts, dict):
        existing_accounts = {}
    if DEMO_LGU_USER not in existing_accounts:
        now = int(__import__("time").time() * 1000)
        salt = new_salt()
        rtdb(
            f"lgu_accounts/{DEMO_LGU_USER}",
            "PUT",
            {
                "username": DEMO_LGU_USER,
                "barangayId": "52",
                "isActive": True,
                "passwordHash": hash_password(DEMO_LGU_PASSWORD, salt),
                "passwordSalt": salt,
                "createdAt": now,
                "updatedAt": now,
            },
        )
        created["accounts"].append(DEMO_LGU_USER)
    return created


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[barangay-admin] {self.address_string()} {fmt % args}")

    def _send(self, code: int, body: bytes, content_type: str = "application/json"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        data = json.loads(raw.decode("utf-8") or "{}")
        if not isinstance(data, dict):
            raise ValueError("JSON object required.")
        return data

    def do_GET(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        try:
            if path in ("/", "/index.html"):
                html = (STATIC / "index.html").read_bytes()
                self._send(200, html, "text/html; charset=utf-8")
                return
            if path == "/api/health":
                self._send(200, _json({"ok": True, "rtdb": RTDB}))
                return
            if path == "/api/barangays":
                rows = rtdb("barangays") or {}
                if not isinstance(rows, dict):
                    rows = {}
                items = []
                for key, value in rows.items():
                    if isinstance(value, dict):
                        items.append(normalize_barangay(value, key))
                items.sort(key=lambda b: b["id"])
                self._send(200, _json({"barangays": items}))
                return
            if path == "/api/accounts":
                rows = rtdb("lgu_accounts") or {}
                if not isinstance(rows, dict):
                    rows = {}
                items = [
                    public_account(str(key), value)
                    for key, value in rows.items()
                    if isinstance(value, dict)
                ]
                items.sort(key=lambda a: a["username"])
                self._send(200, _json({"accounts": items}))
                return
            self._send(404, _json({"error": "Not found"}))
        except Exception as exc:
            self._send(500, _json({"error": str(exc)}))

    def do_POST(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        try:
            if path == "/api/seed":
                created = seed_defaults()
                self._send(200, _json({"ok": True, "created": created}))
                return
            self._send(404, _json({"error": "Not found"}))
        except Exception as exc:
            self._send(500, _json({"error": str(exc)}))

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        try:
            body = self._read_json()
            if path.startswith("/api/barangays/"):
                barangay_id = path.split("/api/barangays/", 1)[1].strip()
                row = normalize_barangay(body, barangay_id)
                rtdb(f"barangays/{row['id']}", "PUT", row)
                self._send(200, _json({"ok": True, "barangay": row}))
                return
            if path.startswith("/api/accounts/"):
                username = path.split("/api/accounts/", 1)[1].strip().lower()
                if not username:
                    raise ValueError("Username is required.")
                barangay_id = str(body.get("barangayId") or "").strip()
                if not barangay_id:
                    raise ValueError("barangayId is required.")
                password = str(body.get("password") or "")
                existing = rtdb(f"lgu_accounts/{username}") or {}
                if not isinstance(existing, dict):
                    existing = {}
                now = int(__import__("time").time() * 1000)
                row = {
                    "username": username,
                    "barangayId": barangay_id,
                    "isActive": body.get("isActive") is True or body.get("isActive") == "true",
                    "createdAt": existing.get("createdAt") or now,
                    "updatedAt": now,
                }
                if password:
                    if len(password) < 8:
                        raise ValueError("Password must be at least 8 characters.")
                    salt = new_salt()
                    row["passwordSalt"] = salt
                    row["passwordHash"] = hash_password(password, salt)
                elif existing.get("passwordHash") and existing.get("passwordSalt"):
                    row["passwordHash"] = existing["passwordHash"]
                    row["passwordSalt"] = existing["passwordSalt"]
                else:
                    raise ValueError("Password is required for a new LGU account.")
                rtdb(f"lgu_accounts/{username}", "PUT", row)
                self._send(200, _json({"ok": True, "account": public_account(username, row)}))
                return
            self._send(404, _json({"error": "Not found"}))
        except ValueError as exc:
            self._send(400, _json({"error": str(exc)}))
        except Exception as exc:
            self._send(500, _json({"error": str(exc)}))

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        try:
            if path.startswith("/api/barangays/"):
                barangay_id = path.split("/api/barangays/", 1)[1].strip()
                if barangay_id == "52":
                    raise ValueError("Barangay 52 is the demo home barangay and cannot be deleted.")
                rtdb(f"barangays/{barangay_id}", "DELETE")
                self._send(200, _json({"ok": True}))
                return
            if path.startswith("/api/accounts/"):
                username = path.split("/api/accounts/", 1)[1].strip().lower()
                if username == DEMO_LGU_USER:
                    raise ValueError("The demo brgy52 account cannot be deleted.")
                rtdb(f"lgu_accounts/{username}", "DELETE")
                self._send(200, _json({"ok": True}))
                return
            self._send(404, _json({"error": "Not found"}))
        except ValueError as exc:
            self._send(400, _json({"error": str(exc)}))
        except Exception as exc:
            self._send(500, _json({"error": str(exc)}))


def main() -> None:
    STATIC.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Barangay admin on http://{HOST}:{PORT}")
    print(f"Firebase RTDB: {RTDB}")
    print("Writes barangays + lgu_accounts only. Does not wipe SOS or users.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping barangay admin.")
        server.server_close()


if __name__ == "__main__":
    main()
