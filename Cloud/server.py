#!/usr/bin/env python3
"""Independent Still Cloud server. Python standard library, SQLite, streaming uploads."""
from __future__ import annotations
import argparse
import math
import base64
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlencode, urlsplit
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
MAX_JSON = 1_048_576
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{20,100}$")
ID_RE = re.compile(r"^[a-f0-9]{32}$")

class HTTPError(Exception):
    def __init__(self, status, message, **details):
        self.status, self.message, self.details = status, message, details

def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()

def b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")

def password_hash(password: str, salt: str) -> str:
    return hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 310_000).hex()

class Store:
    def __init__(self, directory: Path, public_url: str, admin_token: str | None = None):
        self.open_connections = threading.local()
        self.directory = directory.resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.directory.chmod(0o700)
        self.files = self.directory / "files"
        self.files.mkdir(mode=0o700, exist_ok=True)
        self.public_url = public_url.rstrip("/")
        self.secure = self.public_url.startswith("https://")
        self.brand = os.environ.get("STILL_BRAND", "Still Cloud")[:80]
        self.accent = os.environ.get("STILL_ACCENT", "#087cff")
        if not re.fullmatch(r"#[0-9a-fA-F]{6}", self.accent):
            self.accent = "#087cff"
        self.secret = self._secret("session-secret")
        self.scim_token = os.environ.get("STILL_SCIM_TOKEN", "")
        self.rate_lock = threading.Lock()
        self.rates: dict[str, list[float]] = {}
        with self.db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL,
                  name TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'member', active INTEGER NOT NULL DEFAULT 1,
                  token_hash TEXT UNIQUE, oidc_subject TEXT UNIQUE);
                CREATE TABLE IF NOT EXISTS uploads (id TEXT PRIMARY KEY, token TEXT UNIQUE NOT NULL,
                  owner TEXT NOT NULL REFERENCES users(id), title TEXT NOT NULL, mime TEXT NOT NULL,
                  size INTEGER NOT NULL, created REAL NOT NULL, expires REAL, max_views INTEGER NOT NULL DEFAULT 0,
                  views INTEGER NOT NULL DEFAULT 0, visibility TEXT NOT NULL DEFAULT 'link',
                  password_salt TEXT, password_hash TEXT, tags TEXT NOT NULL DEFAULT '[]',
                  ocr TEXT NOT NULL DEFAULT '', transcript TEXT NOT NULL DEFAULT '', captions TEXT NOT NULL DEFAULT '',
                  status TEXT NOT NULL DEFAULT 'pending', deleted REAL, sha256 TEXT);
                CREATE TABLE IF NOT EXISTS comments (id TEXT PRIMARY KEY, upload_id TEXT NOT NULL REFERENCES uploads(id),
                  parent_id TEXT, author TEXT NOT NULL, viewer TEXT NOT NULL, text TEXT NOT NULL, created REAL NOT NULL,
                  seconds REAL, x REAL, y REAL, resolved INTEGER NOT NULL DEFAULT 0, deleted REAL);
                CREATE TABLE IF NOT EXISTS visits (upload_id TEXT NOT NULL, viewer TEXT NOT NULL, created REAL NOT NULL,
                  PRIMARY KEY(upload_id, viewer));
                CREATE TABLE IF NOT EXISTS groups (id TEXT PRIMARY KEY, name TEXT NOT NULL, external_id TEXT);
                CREATE TABLE IF NOT EXISTS group_members (group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, PRIMARY KEY(group_id,user_id));
                CREATE TABLE IF NOT EXISTS audit (id INTEGER PRIMARY KEY AUTOINCREMENT, time REAL NOT NULL,
                  actor TEXT NOT NULL, action TEXT NOT NULL, object_id TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS uploads_owner_created ON uploads(owner, created DESC);
                CREATE INDEX IF NOT EXISTS comments_upload_created ON comments(upload_id, created);
            """)
            token = admin_token or os.environ.get("STILL_ADMIN_TOKEN")
            if not token:
                path = self.directory / "admin-token"
                if path.exists():
                    token = path.read_text().strip()
                else:
                    token = secrets.token_urlsafe(32)
                    path.write_text(token + "\n")
                    path.chmod(0o600)
            db.execute("INSERT INTO users(id,username,name,role,token_hash) VALUES('admin','admin','Owner','admin',?) "
                       "ON CONFLICT(id) DO NOTHING", (digest(token),))

    def _secret(self, name):
        path = self.directory / name
        if not path.exists():
            path.write_bytes(secrets.token_bytes(48))
            path.chmod(0o600)
        return path.read_bytes()

    def commit_open(self):
        for db in getattr(self.open_connections, "connections", []):
            if db.in_transaction: db.commit()

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.directory / "still.sqlite3", timeout=30)
        self.open_connections.connections = getattr(self.open_connections, "connections", []) + [db]
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA journal_mode=WAL")
        try:
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            self.open_connections.connections.remove(db)
            db.close()

    def sign(self, data: dict) -> str:
        payload = b64(json.dumps(data, separators=(",", ":")).encode())
        return payload + "." + b64(hmac.new(self.secret, payload.encode(), hashlib.sha256).digest())

    def unsign(self, value: str) -> dict | None:
        try:
            payload, signature = value.split(".", 1)
            expected = b64(hmac.new(self.secret, payload.encode(), hashlib.sha256).digest())
            if not hmac.compare_digest(expected, signature):
                return None
            data = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
            if float(data.get("exp", 0)) <= time.time():
                return None
            return data
        except (ValueError, TypeError, json.JSONDecodeError):
            return None

    def rate(self, key: str, limit=25, window=60):
        now = time.time()
        with self.rate_lock:
            values = [x for x in self.rates.get(key, []) if now-x < window]
            if len(values) >= limit:
                raise HTTPError(429, "Too many attempts. Try again in a minute.")
            values.append(now)
            self.rates[key] = values
            if len(self.rates) > 10000:
                self.rates = {k: v for k, v in self.rates.items() if v and now-v[-1] < window}

    @staticmethod
    def audit(db, actor, action, object_id):
        db.execute("INSERT INTO audit(time,actor,action,object_id) VALUES(?,?,?,?)", (time.time(), actor, action, object_id))

class CloudHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, address, store):
        self.store = store
        super().__init__(address, Handler)

class Handler(BaseHTTPRequestHandler):
    server_version = "StillCloud/1.0"
    protocol_version = "HTTP/1.1"
    def setup(self):
        super().setup()
        self.connection.settimeout(90)
    @property
    def store(self):
        return self.server.store
    def log_message(self, format, *args):
        # Avoid logging capability URLs, passwords or authorization headers.
        pass
    def do_GET(self): self.dispatch()
    def do_HEAD(self): self.dispatch()
    def do_POST(self): self.dispatch()
    def do_PUT(self): self.dispatch()
    def do_PATCH(self): self.dispatch()
    def do_DELETE(self): self.dispatch()

    def headers_base(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.send_header("Cache-Control", "no-store")
        if self.store.secure:
            self.send_header("Strict-Transport-Security", "max-age=31536000")
    def respond(self, status, body=b"", content_type="application/json; charset=utf-8", cookies=(), extra=None):
        # Handlers often respond inside `with store.db()`; commit first so the next request sees the change.
        if status < 400: self.store.commit_open()
        if isinstance(body, dict) or isinstance(body, list):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.headers_base()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for value in cookies:
            self.send_header("Set-Cookie", value)
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def cookie(self, name, value, max_age=86400):
        return f"{name}={value}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Lax" + ("; Secure" if self.store.secure else "")
    def cookies(self):
        result = SimpleCookie()
        try: result.load(self.headers.get("Cookie", ""))
        except Exception: pass
        return result
    def signed_cookie(self, name):
        cookie = self.cookies().get(name)
        return self.store.unsign(cookie.value) if cookie else None
    def body(self, limit=MAX_JSON):
        try: length = int(self.headers.get("Content-Length", "0"))
        except ValueError: raise HTTPError(400, "Invalid content length.")
        if not 0 <= length <= limit: raise HTTPError(413, "Request is too large.")
        data = self.rfile.read(length)
        if len(data) != length: raise HTTPError(400, "The request was interrupted.")
        return data
    def json(self):
        try:
            value = json.loads(self.body() or b"{}", parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Non-finite number")))
            if not isinstance(value, dict): raise ValueError()
            return value
        except (ValueError, UnicodeDecodeError): raise HTTPError(400, "Expected a JSON object.")
    def same_origin(self):
        origin = self.headers.get("Origin")
        if origin and origin.rstrip("/") != self.store.public_url:
            raise HTTPError(403, "Cross-origin request rejected.")
    def user(self, required=True):
        auth = self.headers.get("Authorization", "")
        with self.store.db() as db:
            if auth.startswith("Bearer "):
                result = db.execute("SELECT * FROM users WHERE token_hash=? AND active=1", (digest(auth[7:]),)).fetchone()
            else:
                session = self.signed_cookie("still_session")
                result = db.execute("SELECT * FROM users WHERE id=? AND active=1", ((session or {}).get("uid", ""),)).fetchone()
                if result and self.command not in ("GET", "HEAD"):
                    self.same_origin()
                    if not session or not hmac.compare_digest(self.headers.get("X-CSRF-Token", ""), session.get("csrf", "")):
                        raise HTTPError(403, "Refresh the page and try again.")
        if not result and required: raise HTTPError(401, "Sign in to continue.")
        return dict(result) if result else None
    @staticmethod
    def public_user(user):
        return {"id": user["id"], "username": user["username"], "name": user["name"], "role": user["role"]}
    def upload(self, upload_id, user):
        if not ID_RE.fullmatch(upload_id): raise HTTPError(404, "Capture not found.")
        with self.store.db() as db:
            row = db.execute("SELECT * FROM uploads WHERE id=?", (upload_id,)).fetchone()
        if not row or (user["role"] != "admin" and row["owner"] != user["id"]):
            raise HTTPError(404, "Capture not found.")
        return dict(row)
    def public_upload(self, row):
        return {"id": row["id"], "token": row["token"], "title": row["title"], "mime": row["mime"], "size": row["size"],
                "created": row["created"], "expires": row["expires"], "maxViews": row["max_views"], "views": row["views"],
                "visibility": row["visibility"], "hasPassword": bool(row["password_hash"]), "tags": json.loads(row["tags"]),
                "ocr": row["ocr"], "transcript": row["transcript"], "captions": row["captions"], "deleted": row["deleted"],
                "url": self.store.public_url + "/v/" + row["token"], "media": "/media/" + row["token"], "download": "/api/uploads/" + row["id"] + "/content"}
    def share(self, token, check_views=True):
        if not TOKEN_RE.fullmatch(token): raise HTTPError(404, "Capture not found.")
        with self.store.db() as db:
            row = db.execute("SELECT * FROM uploads WHERE token=? AND status='ready'", (token,)).fetchone()
        if not row: raise HTTPError(404, "Capture not found.")
        row = dict(row)
        if row["deleted"] or (row["expires"] and row["expires"] <= time.time()): raise HTTPError(410, "This link has expired or was removed.")
        user = self.user(required=False)
        owner = bool(user and (user["id"] == row["owner"] or user["role"] == "admin"))
        if row["visibility"] == "private" and not owner: raise HTTPError(401, "Sign in as the owner to view this capture.", loginRequired=True)
        if row["visibility"] == "team" and not user: raise HTTPError(401, "Sign in to your team to view this capture.", loginRequired=True)
        if row["password_hash"] and not owner:
            grant = self.signed_cookie("still_grant_" + row["id"])
            if not grant or grant.get("id") != row["id"] or grant.get("version") != row["password_hash"][:16]:
                raise HTTPError(401, "Enter the link password.", passwordRequired=True)
        viewer = self.signed_cookie("still_viewer")
        viewer_id = (viewer or {}).get("id", "")
        if check_views and row["max_views"] > 0 and row["views"] >= row["max_views"] and not owner:
            with self.store.db() as db:
                visited = db.execute("SELECT 1 FROM visits WHERE upload_id=? AND viewer=? AND created>?", (row["id"], viewer_id, time.time()-1800)).fetchone()
            if not visited: raise HTTPError(410, "This link reached its view limit.")
        return row, user, owner
    def dispatch(self):
        try:
            if self.headers.get("Transfer-Encoding") or len(self.headers.get_all("Content-Length", [])) > 1:
                raise HTTPError(400, "Use a single Content-Length header.")
            url = urlsplit(self.path)
            path, query = url.path, parse_qs(url.query)
            if path.startswith("/static/") and self.command in ("GET", "HEAD"):
                name = path.removeprefix("/static/")
                if name not in ("app.js", "style.css"): raise HTTPError(404, "Not found.")
                content = (HERE/"static"/name).read_bytes()
                if name == "style.css": content = content.replace(b"{{ACCENT}}", self.store.accent.encode())
                return self.respond(200, content, "text/javascript; charset=utf-8" if name.endswith("js") else "text/css; charset=utf-8")
            if path == "/api/health": return self.respond(200, {"status": "ok", "name": self.store.brand, "oidc": bool(os.environ.get("STILL_OIDC_ISSUER"))})
            if path == "/api/login" and self.command == "POST": return self.login()
            if path == "/api/logout" and self.command == "POST": self.user(); return self.respond(200, {"ok": True}, cookies=[self.cookie("still_session", "", 0)])
            if path == "/api/me":
                user = self.user(); session = self.signed_cookie("still_session")
                return self.respond(200, {"user": self.public_user(user), "csrf": (session or {}).get("csrf", ""), "brand": self.store.brand, "accent": self.store.accent, "oidc": bool(os.environ.get("STILL_OIDC_ISSUER"))})
            if path.startswith("/auth/"): return self.oidc(path, query)
            if path.startswith("/scim/v2/"): return self.scim(path, query)
            if path == "/api/token" and self.command == "POST":
                user = self.user(); token = secrets.token_urlsafe(32)
                with self.store.db() as db: db.execute("UPDATE users SET token_hash=? WHERE id=?", (digest(token), user["id"])); self.store.audit(db, user["id"], "token.rotate", user["id"])
                if user["id"] == "admin":
                    token_path = self.store.directory / "admin-token"
                    token_path.write_text(token + "\n"); token_path.chmod(0o600)
                return self.respond(200, {"token": token})
            if path == "/api/uploads": return self.uploads(query)
            match = re.fullmatch(r"/api/uploads/([a-f0-9]{32})(?:/(content|restore))?", path)
            if match: return self.upload_action(*match.groups())
            if path == "/api/users": return self.users()
            if path == "/api/audit":
                user = self.user()
                if user["role"] != "admin": raise HTTPError(403, "Owner access required.")
                with self.store.db() as db: rows = [dict(row) for row in db.execute("SELECT * FROM audit ORDER BY id DESC LIMIT 200")]
                return self.respond(200, {"events": rows})
            match = re.fullmatch(r"/api/share/([A-Za-z0-9_-]+)(?:/(unlock|comments|captions))?", path)
            if match: return self.share_api(*match.groups())
            match = re.fullmatch(r"/api/comments/([a-f0-9]{32})", path)
            if match: return self.comment_action(match.group(1))
            match = re.fullmatch(r"/media/([A-Za-z0-9_-]+)", path)
            if match and self.command in ("GET", "HEAD"): return self.media(match.group(1))
            match = re.fullmatch(r"/v/([A-Za-z0-9_-]+)", path)
            if match and self.command in ("GET", "HEAD"): return self.page("share", token=match.group(1))
            if path == "/" and self.command in ("GET", "HEAD"): return self.page("dashboard" if self.user(required=False) else "login")
            raise HTTPError(404, "Not found.")
        except HTTPError as error:
            self.close_connection = True
            self.respond(error.status, {"error": error.message, **error.details})
        except (ValueError, TypeError, OverflowError):
            self.close_connection = True
            self.respond(400, {"error": "One of the supplied values is invalid."})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True
        except Exception:
            self.respond(500, {"error": "The request could not be completed. Check the server logs or try again."})

    def page(self, page, token=""):
        html = (HERE/"static"/"index.html").read_text().replace("{{PAGE}}", page).replace("{{TOKEN}}", token)
        self.respond(200, html, "text/html; charset=utf-8")
    def login(self):
        self.same_origin(); self.store.rate("login:" + self.client_address[0], 12)
        token = str(self.json().get("token", ""))
        with self.store.db() as db: user = db.execute("SELECT * FROM users WHERE token_hash=? AND active=1", (digest(token),)).fetchone()
        if not user: raise HTTPError(401, "That token is not valid.")
        csrf = secrets.token_urlsafe(24)
        session = self.store.sign({"uid": user["id"], "csrf": csrf, "exp": time.time()+86400})
        self.respond(200, {"ok": True}, cookies=[self.cookie("still_session", session)])
    def uploads(self, query):
        user = self.user()
        if self.command == "GET":
            term = "%"+query.get("q", [""])[0][:200]+"%"
            deleted = query.get("trash", ["0"])[0] == "1"
            offset = max(0, int(query.get("offset", [0])[0])); count = max(1, min(200, int(query.get("count", [100])[0])))
            kind = query.get("type", ["All"])[0]
            condition = "status='ready' AND (owner=? OR ?='admin') AND (deleted IS NOT NULL)=? AND (title LIKE ? OR tags LIKE ? OR ocr LIKE ? OR transcript LIKE ?)"
            if kind == "Images": condition += " AND mime LIKE 'image/%' AND mime!='image/gif'"
            elif kind == "Videos": condition += " AND (mime LIKE 'video/%' OR mime='image/gif')"
            parameters = (user["id"], user["role"], deleted, term, term, term, term)
            with self.store.db() as db:
                total = db.execute("SELECT COUNT(*) FROM uploads WHERE "+condition, parameters).fetchone()[0]
                rows = db.execute("SELECT * FROM uploads WHERE "+condition+" ORDER BY created DESC LIMIT ? OFFSET ?", parameters+(count, offset)).fetchall()
            return self.respond(200, {"items": [self.public_upload(row) for row in rows], "total": total, "nextOffset": offset+count if offset+count < total else None})
        if self.command != "POST": raise HTTPError(405, "Method not allowed.")
        data = self.json()
        title = str(data.get("title", "Capture"))[:250].strip() or "Capture"
        mime = str(data.get("mime", "image/png"))
        allowed = {"image/png", "image/jpeg", "image/gif", "image/tiff", "image/heic", "video/mp4", "video/quicktime"}
        if mime not in allowed: raise HTTPError(400, "This file type is not supported.")
        size = int(data.get("size", 0))
        if not 0 < size <= int(os.environ.get("STILL_MAX_UPLOAD_BYTES", str(4*1024**3))): raise HTTPError(413, "File is too large or empty.")
        visibility = data.get("visibility", "link")
        if visibility not in ("link", "team", "private"): raise HTTPError(400, "Invalid access setting.")
        days = max(0, min(3650, int(data.get("expiryDays", 7))))
        password = str(data.get("password", ""))[:500]
        salt = secrets.token_hex(16) if password else None
        tags = [str(value)[:60] for value in data.get("tags", [])[:30]] if isinstance(data.get("tags", []), list) else []
        upload_id, token = secrets.token_hex(16), secrets.token_urlsafe(24)
        with self.store.db() as db:
            db.execute("INSERT INTO uploads(id,token,owner,title,mime,size,created,expires,max_views,visibility,password_salt,password_hash,tags,ocr,transcript,captions) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (upload_id, token, user["id"], title, mime, size, time.time(), time.time()+days*86400 if days else None, max(0, int(data.get("maxViews", 0))), visibility, salt, password_hash(password, salt) if password else None, json.dumps(tags), str(data.get("ocr", ""))[:500000], str(data.get("transcript", ""))[:500000], str(data.get("captions", ""))[:500000]))
            self.store.audit(db, user["id"], "upload.create", upload_id)
        self.respond(201, {"id": upload_id, "uploadURL": self.store.public_url+"/api/uploads/"+upload_id+"/content", "url": self.store.public_url+"/v/"+token})
    def upload_action(self, upload_id, action):
        user = self.user(); row = self.upload(upload_id, user)
        if action == "content" and self.command in ("GET", "HEAD"):
            return self.send_file(row)
        if action == "content" and self.command == "PUT":
            if row["status"] != "pending": raise HTTPError(409, "This upload is already complete.")
            if int(self.headers.get("Content-Length", "0")) != row["size"]: raise HTTPError(400, "File size does not match.")
            partial = self.store.files/(upload_id+".part")
            hasher = hashlib.sha256(); first = b""
            try:
                with partial.open("xb") as file:
                    remaining = row["size"]
                    while remaining:
                        chunk = self.rfile.read(min(1024*1024, remaining))
                        if not chunk: raise HTTPError(400, "Upload interrupted. Create a new upload and try again.")
                        if not first: first = chunk[:128]
                        file.write(chunk); hasher.update(chunk); remaining -= len(chunk)
                    file.flush(); os.fsync(file.fileno())
                if not self.valid_magic(first, row["mime"]): raise HTTPError(400, "File content does not match its type.")
                os.replace(partial, self.store.files/(upload_id+".blob"))
            except Exception:
                partial.unlink(missing_ok=True)
                raise
            with self.store.db() as db:
                db.execute("UPDATE uploads SET status='ready',sha256=? WHERE id=?", (hasher.hexdigest(), upload_id)); self.store.audit(db, user["id"], "upload.complete", upload_id)
                updated = db.execute("SELECT * FROM uploads WHERE id=?", (upload_id,)).fetchone()
            return self.respond(200, self.public_upload(updated))
        if action == "restore" and self.command == "POST":
            with self.store.db() as db: db.execute("UPDATE uploads SET deleted=NULL WHERE id=?", (upload_id,)); self.store.audit(db, user["id"], "upload.restore", upload_id)
            return self.respond(200, {"ok": True})
        if self.command == "DELETE":
            with self.store.db() as db: db.execute("UPDATE uploads SET deleted=? WHERE id=?", (time.time(), upload_id)); self.store.audit(db, user["id"], "upload.trash", upload_id)
            return self.respond(200, {"ok": True})
        if self.command == "PATCH":
            data = self.json(); fields, values = [], []
            for name in ("title", "transcript", "captions"):
                if name in data: fields.append(name+"=?"); values.append(str(data[name])[:500000 if name != "title" else 250])
            if "tags" in data and isinstance(data["tags"], list): fields.append("tags=?"); values.append(json.dumps([str(x)[:60] for x in data["tags"][:30]]))
            if "visibility" in data:
                if data["visibility"] not in ("link", "team", "private"): raise HTTPError(400, "Invalid access setting.")
                fields.append("visibility=?"); values.append(data["visibility"])
            if "expiryDays" in data: fields.append("expires=?"); values.append(time.time()+max(0, int(data["expiryDays"]))*86400 if data["expiryDays"] else None)
            if "maxViews" in data: fields.append("max_views=?"); values.append(max(0, int(data["maxViews"])))
            if "password" in data:
                password = str(data["password"])[:500]; salt = secrets.token_hex(16) if password else None
                fields += ["password_salt=?", "password_hash=?"]; values += [salt, password_hash(password, salt) if password else None]
            with self.store.db() as db:
                if fields: db.execute("UPDATE uploads SET "+",".join(fields)+" WHERE id=?", values+[upload_id])
                self.store.audit(db, user["id"], "upload.update", upload_id)
            return self.respond(200, {"ok": True})
        if self.command in ("GET", "HEAD"): return self.respond(200, self.public_upload(row))
        raise HTTPError(405, "Method not allowed.")
    @staticmethod
    def valid_magic(data, mime):
        if mime == "image/png": return data.startswith(b"\x89PNG\r\n\x1a\n")
        if mime == "image/jpeg": return data.startswith(b"\xff\xd8\xff")
        if mime == "image/gif": return data.startswith((b"GIF87a", b"GIF89a"))
        if mime == "image/tiff": return data.startswith((b"II*\x00", b"MM\x00*"))
        if mime in ("video/mp4", "video/quicktime", "image/heic"): return b"ftyp" in data[:32] or (mime == "video/quicktime" and data[4:8] in (b"moov", b"mdat", b"wide"))
        return False
    def share_api(self, token, action):
        if action == "unlock" and self.command == "POST":
            self.same_origin(); self.store.rate("unlock:"+self.client_address[0]+":"+token, 10)
            with self.store.db() as db: row = db.execute("SELECT * FROM uploads WHERE token=? AND status='ready' AND deleted IS NULL", (token,)).fetchone()
            if not row or not row["password_hash"]: raise HTTPError(404, "Capture not found.")
            password = str(self.json().get("password", ""))[:500]
            if not hmac.compare_digest(password_hash(password, row["password_salt"]), row["password_hash"]): raise HTTPError(401, "Incorrect password.", passwordRequired=True)
            value = self.store.sign({"id": row["id"], "version": row["password_hash"][:16], "exp": time.time()+86400})
            return self.respond(200, {"ok": True}, cookies=[self.cookie("still_grant_"+row["id"], value)])
        row, user, owner = self.share(token)
        if action == "captions": return self.respond(200, row["captions"], "text/vtt; charset=utf-8")
        if action == "comments":
            if self.command == "GET":
                with self.store.db() as db: comments = [dict(x) for x in db.execute("SELECT id,parent_id,author,text,created,seconds,x,y,resolved FROM comments WHERE upload_id=? AND deleted IS NULL ORDER BY created", (row["id"],))]
                return self.respond(200, {"comments": comments})
            if self.command != "POST": raise HTTPError(405, "Method not allowed.")
            self.same_origin(); self.store.rate("comment:"+self.client_address[0], 20)
            viewer = self.signed_cookie("still_viewer")
            if not viewer or self.headers.get("X-Share-CSRF", "") != viewer.get("csrf"): raise HTTPError(403, "Refresh this page before commenting.")
            data = self.json(); text = str(data.get("text", "")).strip()[:4000]
            if not text: raise HTTPError(400, "Write a comment first.")
            author = user["name"] if user else str(data.get("author", "Guest"))[:80].strip() or "Guest"
            parent = data.get("parentId")
            with self.store.db() as db:
                if parent and not db.execute("SELECT 1 FROM comments WHERE id=? AND upload_id=? AND deleted IS NULL", (parent, row["id"])).fetchone(): raise HTTPError(400, "Reply target not found.")
                for key in ("seconds", "x", "y"):
                    if data.get(key) is not None and not math.isfinite(float(data[key])): raise HTTPError(400, "Comment coordinates and time must be finite numbers.")
                seconds = max(0, float(data["seconds"])) if data.get("seconds") is not None else None
                x = max(0, min(1, float(data["x"]))) if data.get("x") is not None else None
                y = max(0, min(1, float(data["y"]))) if data.get("y") is not None else None
                comment_id = secrets.token_hex(16)
                db.execute("INSERT INTO comments(id,upload_id,parent_id,author,viewer,text,created,seconds,x,y) VALUES(?,?,?,?,?,?,?,?,?,?)", (comment_id, row["id"], parent, author, viewer["id"], text, time.time(), seconds, x, y))
                self.store.audit(db, user["id"] if user else "guest", "comment.create", comment_id)
            return self.respond(201, {"id": comment_id})
        if self.command not in ("GET", "HEAD"): raise HTTPError(405, "Method not allowed.")
        viewer = self.signed_cookie("still_viewer") or {"id": secrets.token_urlsafe(24), "csrf": secrets.token_urlsafe(24), "exp": time.time()+30*86400}
        with self.store.db() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT views,max_views FROM uploads WHERE id=?", (row["id"],)).fetchone()
            exists = db.execute("SELECT 1 FROM visits WHERE upload_id=? AND viewer=?", (row["id"], viewer["id"])).fetchone()
            if not exists:
                if current["max_views"] and current["views"] >= current["max_views"] and not owner: raise HTTPError(410, "This link reached its view limit.")
                db.execute("INSERT INTO visits VALUES(?,?,?)", (row["id"], viewer["id"], time.time()))
                db.execute("UPDATE uploads SET views=views+1 WHERE id=?", (row["id"],))
        self.respond(200, {"item": self.public_upload(row), "owner": owner, "csrf": viewer["csrf"], "brand": self.store.brand, "accent": self.store.accent}, cookies=[self.cookie("still_viewer", self.store.sign(viewer), 30*86400)])
    def comment_action(self, comment_id):
        user = self.user()
        with self.store.db() as db:
            comment = db.execute("SELECT * FROM comments WHERE id=? AND deleted IS NULL", (comment_id,)).fetchone()
            if not comment: raise HTTPError(404, "Comment not found.")
            self.upload(comment["upload_id"], user)
            if self.command == "DELETE": db.execute("UPDATE comments SET deleted=? WHERE id=?", (time.time(), comment_id))
            elif self.command == "PATCH": db.execute("UPDATE comments SET resolved=? WHERE id=?", (bool(self.json().get("resolved")), comment_id))
            else: raise HTTPError(405, "Method not allowed.")
            self.store.audit(db, user["id"], "comment.update", comment_id)
        self.respond(200, {"ok": True})
    def media(self, token):
        row, _, owner = self.share(token)
        if row["max_views"] > 0 and not owner:
            viewer = self.signed_cookie("still_viewer") or {}
            with self.store.db() as db:
                visit = db.execute("SELECT 1 FROM visits WHERE upload_id=? AND viewer=? AND created>?", (row["id"], viewer.get("id", ""), time.time()-1800)).fetchone()
            if not visit: raise HTTPError(403, "Open the share page to view this capture.")
        return self.send_file(row)
    def send_file(self, row):
        path = self.store.files/(row["id"]+".blob")
        if not path.is_file(): raise HTTPError(404, "File not found.")
        size = path.stat().st_size; start, end, status = 0, size-1, 200
        value = self.headers.get("Range")
        if value:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
            if not match or not any(match.groups()): raise HTTPError(416, "Invalid range.")
            if match.group(1): start = int(match.group(1)); end = min(end, int(match.group(2))) if match.group(2) else end
            else: start = max(0, size-int(match.group(2)))
            if start > end or start >= size: return self.respond(416, {}, extra={"Content-Range": f"bytes */{size}"})
            status = 206
        self.send_response(status); self.headers_base(); self.send_header("Content-Type", row["mime"])
        self.send_header("Accept-Ranges", "bytes"); self.send_header("Content-Length", str(end-start+1))
        if status == 206: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        filename = re.sub(r"[\r\n/\\]", "-", row["title"]) + (mimetypes.guess_extension(row["mime"]) or "")
        self.send_header("Content-Disposition", "inline; filename*=UTF-8''"+quote(filename))
        self.end_headers()
        if self.command == "HEAD": return
        with path.open("rb") as file:
            file.seek(start); remaining = end-start+1
            while remaining:
                chunk = file.read(min(1024*1024, remaining))
                if not chunk: break
                self.wfile.write(chunk); remaining -= len(chunk)
    def users(self):
        owner = self.user()
        if owner["role"] != "admin": raise HTTPError(403, "Owner access required.")
        if self.command == "GET":
            with self.store.db() as db: rows = [self.public_user(dict(x)) | {"active": bool(x["active"])} for x in db.execute("SELECT * FROM users ORDER BY name")]
            return self.respond(200, {"users": rows})
        if self.command != "POST": raise HTTPError(405, "Method not allowed.")
        data = self.json(); username = str(data.get("username", "")).strip().lower()[:200]
        if not username: raise HTTPError(400, "Enter a username or email.")
        user_id = secrets.token_hex(16); token = secrets.token_urlsafe(32)
        role = "admin" if data.get("role") == "admin" else "member"
        with self.store.db() as db:
            if db.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone(): raise HTTPError(409, "That user already exists.")
            db.execute("INSERT INTO users(id,username,name,role,token_hash) VALUES(?,?,?,?,?)", (user_id, username, str(data.get("name", username))[:100], role, digest(token)))
            self.store.audit(db, owner["id"], "user.create", user_id)
        self.respond(201, {"id": user_id, "token": token})
    def oidc(self, path, query):
        issuer = os.environ.get("STILL_OIDC_ISSUER", "").rstrip("/")
        client_id = os.environ.get("STILL_OIDC_CLIENT_ID", "")
        if not issuer.startswith("https://") or not client_id: raise HTTPError(503, "SSO is not configured.")
        with urlopen(issuer+"/.well-known/openid-configuration", timeout=10) as response: discovery = json.load(response)
        if discovery.get("issuer", "").rstrip("/") != issuer: raise HTTPError(502, "SSO issuer mismatch.")
        for key in ("authorization_endpoint", "token_endpoint", "userinfo_endpoint"):
            if not str(discovery.get(key, "")).startswith("https://"): raise HTTPError(502, "SSO requires HTTPS endpoints.")
        redirect_uri = self.store.public_url+"/auth/callback"
        if path == "/auth/oidc":
            verifier, state = secrets.token_urlsafe(48), secrets.token_urlsafe(32)
            payload = self.store.sign({"state": state, "verifier": verifier, "exp": time.time()+600})
            url = discovery["authorization_endpoint"]+"?"+urlencode({"client_id": client_id, "redirect_uri": redirect_uri, "response_type": "code", "scope": "openid email profile", "state": state, "code_challenge": b64(hashlib.sha256(verifier.encode()).digest()), "code_challenge_method": "S256"})
            return self.respond(302, b"", cookies=[self.cookie("still_oidc", payload, 600)], extra={"Location": url})
        saved = self.signed_cookie("still_oidc")
        if not saved or not hmac.compare_digest(query.get("state", [""])[0], saved["state"]): raise HTTPError(403, "SSO state expired. Sign in again.")
        values = {"grant_type": "authorization_code", "code": query.get("code", [""])[0], "client_id": client_id, "client_secret": os.environ.get("STILL_OIDC_CLIENT_SECRET", ""), "redirect_uri": redirect_uri, "code_verifier": saved["verifier"]}
        with urlopen(Request(discovery["token_endpoint"], data=urlencode(values).encode(), headers={"Content-Type": "application/x-www-form-urlencoded"}), timeout=15) as response: tokens = json.load(response)
        # Identity is fetched from the issuer over TLS using the server-exchanged access token.
        with urlopen(Request(discovery["userinfo_endpoint"], headers={"Authorization": "Bearer "+tokens["access_token"]}), timeout=15) as response: identity = json.load(response)
        subject = issuer+"|"+str(identity.get("sub", "")); email = str(identity.get("email", "")).lower()
        if not identity.get("sub") or not email or identity.get("email_verified") is not True: raise HTTPError(403, "SSO requires a verified email.")
        with self.store.db() as db:
            user = db.execute("SELECT * FROM users WHERE oidc_subject=?", (subject,)).fetchone()
            if not user:
                user = db.execute("SELECT * FROM users WHERE username=?", (email,)).fetchone()
                if user and user["oidc_subject"] and user["oidc_subject"] != subject: raise HTTPError(403, "This email is bound to another SSO identity. Contact your administrator.")
            if not user:
                domains = [x.strip().lower() for x in os.environ.get("STILL_OIDC_ALLOWED_DOMAINS", "").split(",") if x.strip()]
                if email.rsplit("@", 1)[-1] not in domains: raise HTTPError(403, "Ask your administrator to provision your account.")
                user_id = secrets.token_hex(16)
                db.execute("INSERT INTO users(id,username,name,oidc_subject) VALUES(?,?,?,?)", (user_id, email, str(identity.get("name", email))[:100], subject))
                user = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
            if not user["active"]: raise HTTPError(403, "Your account is inactive.")
            db.execute("UPDATE users SET oidc_subject=? WHERE id=?", (subject, user["id"]))
        session = self.store.sign({"uid": user["id"], "csrf": secrets.token_urlsafe(24), "exp": time.time()+86400})
        self.respond(302, b"", cookies=[self.cookie("still_session", session), self.cookie("still_oidc", "", 0)], extra={"Location": "/"})
    def scim(self, path, query):
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        if not self.store.scim_token or not hmac.compare_digest(token, self.store.scim_token): raise HTTPError(401, "SCIM token required.")
        if path.startswith("/scim/v2/Groups"): return self.scim_groups(path, query)
        if path == "/scim/v2/ResourceTypes": return self.respond(200, {"schemas": ["urn:ietf:params:scim:api:messages:2.0:ListResponse"], "totalResults": 2, "Resources": [{"id": "User", "name": "User", "endpoint": "/Users", "schema": "urn:ietf:params:scim:schemas:core:2.0:User"}, {"id": "Group", "name": "Group", "endpoint": "/Groups", "schema": "urn:ietf:params:scim:schemas:core:2.0:Group"}]}, "application/scim+json")
        schema = "urn:ietf:params:scim:schemas:core:2.0:User"
        def user_json(row): return {"schemas": [schema], "id": row["id"], "userName": row["username"], "displayName": row["name"], "active": bool(row["active"]), "emails": [{"value": row["username"], "primary": True}]}
        if path == "/scim/v2/ServiceProviderConfig": return self.respond(200, {"schemas": ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"], "patch": {"supported": True}, "filter": {"supported": True, "maxResults": 200}, "bulk": {"supported": False}, "sort": {"supported": False}, "changePassword": {"supported": False}, "etag": {"supported": False}, "authenticationSchemes": [{"type": "oauthbearertoken", "name": "Bearer Token"}]})
        match = re.fullmatch(r"/scim/v2/Users(?:/([a-f0-9]{32}|admin))?", path)
        if not match: raise HTTPError(404, "SCIM resource not found.")
        user_id = match.group(1)
        with self.store.db() as db:
            if self.command == "GET":
                if user_id:
                    row = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                    if not row: raise HTTPError(404, "User not found.")
                    return self.respond(200, user_json(row), "application/scim+json")
                rows = db.execute("SELECT * FROM users ORDER BY username").fetchall()
                if "filter" in query:
                    value = re.fullmatch(r'userName eq "([^"\n]+)"', query["filter"][0])
                    if not value: raise HTTPError(400, "Only userName equality filters are supported.")
                    rows = [row for row in rows if row["username"] == value.group(1).lower()]
                start = max(1, int(query.get("startIndex", [1])[0])); count = max(1, min(200, int(query.get("count", [100])[0])))
                return self.respond(200, {"schemas": ["urn:ietf:params:scim:api:messages:2.0:ListResponse"], "totalResults": len(rows), "startIndex": start, "itemsPerPage": min(count, len(rows)), "Resources": [user_json(row) for row in rows[start-1:start-1+count]]}, "application/scim+json")
            if self.command == "POST" and not user_id:
                data = self.json(); username = str(data.get("userName", "")).lower().strip()[:200]
                if not username: raise HTTPError(400, "userName is required.")
                if db.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone(): raise HTTPError(409, "User already exists.")
                user_id = secrets.token_hex(16)
                db.execute("INSERT INTO users(id,username,name,active) VALUES(?,?,?,?)", (user_id, username, str(data.get("displayName", username))[:100], bool(data.get("active", True))))
            elif user_id:
                row = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                if not row: raise HTTPError(404, "User not found.")
                if user_id == "admin": raise HTTPError(403, "The owner account cannot be deprovisioned through SCIM.")
                if self.command == "DELETE": db.execute("UPDATE users SET active=0,token_hash=NULL WHERE id=?", (user_id,)); return self.respond(204, b"", "application/scim+json")
                data = self.json()
                if self.command == "PATCH":
                    normalized = {}
                    for operation in data.get("Operations", []):
                        if str(operation.get("op", "")).lower() not in ("replace", "add"): raise HTTPError(400, "Unsupported patch operation.")
                        if operation.get("path"): normalized[operation["path"]] = operation.get("value")
                        elif isinstance(operation.get("value"), dict): normalized.update(operation["value"])
                    data = normalized
                elif self.command != "PUT": raise HTTPError(405, "Method not allowed.")
                db.execute("UPDATE users SET username=?,name=?,active=? WHERE id=?", (str(data.get("userName", row["username"])).lower()[:200], str(data.get("displayName", row["name"]))[:100], bool(data.get("active", row["active"])), user_id))
            else: raise HTTPError(405, "Method not allowed.")
            self.store.audit(db, "scim", "user.provision", user_id)
            row = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
            self.respond(201 if self.command == "POST" else 200, user_json(row), "application/scim+json")

    def scim_groups(self, path, query):
        match = re.fullmatch(r"/scim/v2/Groups(?:/([a-f0-9]{32}))?", path)
        if not match: raise HTTPError(404, "Group not found.")
        group_id = match.group(1)
        def representation(db, row):
            members = db.execute("SELECT u.id,u.name FROM users u JOIN group_members m ON m.user_id=u.id WHERE m.group_id=? ORDER BY u.username", (row["id"],)).fetchall()
            return {"schemas": ["urn:ietf:params:scim:schemas:core:2.0:Group"], "id": row["id"], "displayName": row["name"], "externalId": row["external_id"], "members": [{"value": m["id"], "display": m["name"], "$ref": self.store.public_url+"/scim/v2/Users/"+m["id"]} for m in members], "meta": {"resourceType": "Group", "location": self.store.public_url+"/scim/v2/Groups/"+row["id"]}}
        with self.store.db() as db:
            row = db.execute("SELECT * FROM groups WHERE id=?", (group_id,)).fetchone() if group_id else None
            if group_id and not row: raise HTTPError(404, "Group not found.")
            if self.command == "GET":
                if row: return self.respond(200, representation(db, row), "application/scim+json")
                rows = db.execute("SELECT * FROM groups ORDER BY name").fetchall()
                if "filter" in query:
                    value = re.fullmatch(r'(displayName|externalId) eq "([^"\n]+)"', query["filter"][0])
                    if not value: raise HTTPError(400, "Use displayName or externalId equality filters.")
                    rows = [r for r in rows if r["name" if value[1] == "displayName" else "external_id"] == value[2]]
                start = max(1, int(query.get("startIndex", [1])[0])); count = max(0, min(200, int(query.get("count", [100])[0])))
                page = rows[start-1:start-1+count]
                return self.respond(200, {"schemas": ["urn:ietf:params:scim:api:messages:2.0:ListResponse"], "totalResults": len(rows), "startIndex": start, "itemsPerPage": len(page), "Resources": [representation(db, r) for r in page]}, "application/scim+json")
            if self.command == "DELETE" and row:
                db.execute("DELETE FROM group_members WHERE group_id=?", (group_id,)); db.execute("DELETE FROM groups WHERE id=?", (group_id,)); self.store.audit(db, "scim", "group.delete", group_id)
                return self.respond(204, b"", "application/scim+json")
            data = self.json()
            if self.command == "POST" and not group_id:
                group_id = secrets.token_hex(16); name = str(data.get("displayName", "")).strip()[:200]
                if not name: raise HTTPError(400, "displayName is required.")
                db.execute("INSERT INTO groups VALUES(?,?,?)", (group_id, name, str(data.get("externalId", ""))[:200] or None))
                operations = [{"op": "replace", "path": "members", "value": data.get("members", [])}]
            elif self.command == "PUT" and row:
                name = str(data.get("displayName", "")).strip()[:200]
                if not name: raise HTTPError(400, "displayName is required.")
                db.execute("UPDATE groups SET name=?,external_id=? WHERE id=?", (name, str(data.get("externalId", ""))[:200] or None, group_id))
                operations = [{"op": "replace", "path": "members", "value": data.get("members", [])}]
            elif self.command == "PATCH" and row:
                operations = data.get("Operations", [])
                if not isinstance(operations, list) or len(operations) > 100: raise HTTPError(400, "Invalid patch operations.")
            else: raise HTTPError(405, "Method not allowed.")
            for operation in operations:
                op = str(operation.get("op", "")).lower(); target = operation.get("path", ""); value = operation.get("value")
                if op not in ("add", "replace", "remove"): raise HTTPError(400, "Unsupported patch operation.")
                if not target and isinstance(value, dict):
                    if "displayName" in value: db.execute("UPDATE groups SET name=? WHERE id=?", (str(value["displayName"])[:200], group_id))
                    if "externalId" in value: db.execute("UPDATE groups SET external_id=? WHERE id=?", (str(value["externalId"])[:200], group_id))
                    if "members" not in value: continue
                    target = "members"; value = value["members"]
                if target in ("displayName", "externalId"):
                    column = "name" if target == "displayName" else "external_id"
                    if target == "displayName" and (op == "remove" or not str(value or "").strip()): raise HTTPError(400, "displayName is required.")
                    db.execute("UPDATE groups SET "+column+"=? WHERE id=?", (None if op == "remove" else str(value)[:200], group_id)); continue
                filtered = re.fullmatch(r'members\[value eq "([^"\n]+)"\]', target)
                if filtered and op == "remove": db.execute("DELETE FROM group_members WHERE group_id=? AND user_id=?", (group_id, filtered[1])); continue
                if target != "members": raise HTTPError(400, "Unsupported group attribute.")
                if op in ("replace", "remove") and value is None: db.execute("DELETE FROM group_members WHERE group_id=?", (group_id,)); continue
                if not isinstance(value, list) or len(value) > 10000: raise HTTPError(400, "members must be an array.")
                if op == "replace": db.execute("DELETE FROM group_members WHERE group_id=?", (group_id,))
                for member in value:
                    user_id = str(member.get("value", ""))
                    if not db.execute("SELECT 1 FROM users WHERE id=?", (user_id,)).fetchone(): raise HTTPError(400, "Group member does not exist.")
                    if op == "remove": db.execute("DELETE FROM group_members WHERE group_id=? AND user_id=?", (group_id, user_id))
                    else: db.execute("INSERT OR IGNORE INTO group_members VALUES(?,?)", (group_id, user_id))
            self.store.audit(db, "scim", "group.provision", group_id)
            row = db.execute("SELECT * FROM groups WHERE id=?", (group_id,)).fetchone()
            self.respond(201 if self.command == "POST" else 200, representation(db, row), "application/scim+json")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=7843, type=int)
    parser.add_argument("--data", default=str(HERE/"data"), type=Path)
    parser.add_argument("--ready-file", type=Path)
    args = parser.parse_args()
    public = os.environ.get("STILL_PUBLIC_URL", f"http://127.0.0.1:{args.port}")
    store = Store(args.data, public)
    server = CloudHTTPServer((args.host, args.port), store)
    if not os.environ.get("STILL_PUBLIC_URL"): store.public_url = f"http://127.0.0.1:{server.server_port}"
    if args.ready_file:
        args.ready_file.write_text(json.dumps({"pid": os.getpid(), "port": server.server_port}))
        args.ready_file.chmod(0o600)
    print(f"Still Cloud listening on {args.host}:{server.server_port}", flush=True)
    print("Owner token is stored in the private data/admin-token file. No capture uploads automatically.", flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()

if __name__ == "__main__": main()
