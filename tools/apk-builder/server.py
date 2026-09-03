#!/usr/bin/env python3
"""Local APK builder UI. Binds to 127.0.0.1:8787. Does not modify release app trees."""

from __future__ import annotations

import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

HOST = "127.0.0.1"
PORT = 8787
HERE = Path(__file__).resolve().parent
STATIC = HERE / "static"
WORKSPACE = HERE.parents[1]

SKIP_COPY_NAMES = {
    "build",
    ".dart_tool",
    ".idea",
    ".gradle",
    ".cxx",
    ".git",
    "__pycache__",
    "ephemeral",
}

APP_ID_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*){2,}$")
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

KNOWN_APPS = [
    {
        "id": "citizen",
        "label": "Citizen",
        "path": str(WORKSPACE / "CITIZEN" / "citizen27"),
    },
    {
        "id": "responder",
        "label": "Responder",
        "path": str(WORKSPACE / "RESPONDER" / "responderv3"),
    },
]

JOBS: dict[str, dict] = {}
JOBS_LOCK = threading.Lock()


def _json(data) -> bytes:
    return json.dumps(data).encode("utf-8")


def find_flutter() -> str | None:
    for name in ("flutter.bat", "flutter"):
        found = shutil.which(name)
        if found:
            return found
    extra = [
        Path(r"D:\school\CAPSTONE\src\flutter\bin\flutter.bat"),
        Path.home() / "flutter" / "bin" / "flutter.bat",
        Path.home() / "develop" / "flutter" / "bin" / "flutter.bat",
    ]
    env_root = os.environ.get("FLUTTER_ROOT")
    if env_root:
        extra.insert(0, Path(env_root) / "bin" / ("flutter.bat" if os.name == "nt" else "flutter"))
    for candidate in extra:
        if candidate.is_file():
            return str(candidate)
    return None


def is_flutter_android_app(path: Path) -> bool:
    return (
        path.is_dir()
        and (path / "pubspec.yaml").is_file()
        and (path / "android" / "app").is_dir()
    )


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def inspect_app(path: Path) -> dict:
    if not is_flutter_android_app(path):
        return {"valid": False, "error": "Not a Flutter Android app (need pubspec.yaml and android/app)."}
    gradle = path / "android" / "app" / "build.gradle.kts"
    if not gradle.is_file():
        gradle = path / "android" / "app" / "build.gradle"
    app_id = "com.caloocan.rescue.rescue_app"
    if gradle.is_file():
        text = read_text(gradle)
        match = re.search(r'applicationId\s*=\s*"([^"]+)"', text)
        if not match:
            match = re.search(r'applicationId\s+"([^"]+)"', text)
        if match:
            app_id = match.group(1)
    label = ""
    manifest = path / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    if manifest.is_file():
        text = read_text(manifest)
        match = re.search(r'android:label="([^"]*)"', text)
        if match:
            label = match.group(1)
    return {
        "valid": True,
        "path": str(path.resolve()),
        "applicationId": app_id,
        "appName": label,
        "name": path.name,
    }


def list_dir(path: Path) -> dict:
    path = path.resolve()
    if not path.exists():
        return {"error": f"Path does not exist: {path}"}
    if path.is_file():
        path = path.parent
    entries = []
    try:
        for child in sorted(path.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
            if child.name.startswith(".") and child.name not in {".", ".."}:
                continue
            entries.append(
                {
                    "name": child.name,
                    "path": str(child),
                    "isDir": child.is_dir(),
                }
            )
    except PermissionError:
        return {"error": f"Permission denied: {path}", "path": str(path), "entries": []}
    parent = str(path.parent) if path.parent != path else None
    return {
        "path": str(path),
        "parent": parent,
        "entries": entries,
        "isFlutterApp": is_flutter_android_app(path),
    }


def windows_drives() -> list[str]:
    drives = []
    if os.name == "nt":
        for letter in "CDEFGHIJKLMNOPQRSTUVWXYZ":
            root = Path(f"{letter}:/")
            if root.exists():
                drives.append(str(root))
    else:
        drives.append("/")
    return drives


def patch_application_id(project: Path, app_id: str) -> None:
    gradle_kts = project / "android" / "app" / "build.gradle.kts"
    gradle = project / "android" / "app" / "build.gradle"
    target = gradle_kts if gradle_kts.is_file() else gradle
    if not target.is_file():
        raise RuntimeError("android/app/build.gradle(.kts) not found in copy")
    text = read_text(target)
    if re.search(r'applicationId\s*=\s*"[^"]+"', text):
        text = re.sub(r'applicationId\s*=\s*"[^"]+"', f'applicationId = "{app_id}"', text, count=1)
    elif re.search(r'applicationId\s+"[^"]+"', text):
        text = re.sub(r'applicationId\s+"[^"]+"', f'applicationId "{app_id}"', text, count=1)
    else:
        raise RuntimeError("Could not find applicationId in Gradle file")
    target.write_text(text, encoding="utf-8")

    gservices = project / "android" / "app" / "google-services.json"
    if gservices.is_file():
        try:
            data = json.loads(gservices.read_text(encoding="utf-8"))
            for client in data.get("client", []):
                info = client.get("client_info", {}).get("android_client_info", {})
                if "package_name" in info:
                    info["package_name"] = app_id
            gservices.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        except json.JSONDecodeError:
            pass


def patch_label(project: Path, label: str) -> None:
    manifest = project / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    if not manifest.is_file():
        raise RuntimeError("AndroidManifest.xml not found in copy")
    text = read_text(manifest)
    if 'android:label="' not in text:
        raise RuntimeError("android:label not found in AndroidManifest.xml")
    text = re.sub(r'android:label="[^"]*"', f'android:label="{_xml_escape(label)}"', text, count=1)
    manifest.write_text(text, encoding="utf-8")


def _xml_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace('"', "&quot;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def apply_icon(project: Path, png_bytes: bytes) -> None:
    if not png_bytes.startswith(PNG_MAGIC):
        raise RuntimeError("Icon must be a PNG file")
    res = project / "android" / "app" / "src" / "main" / "res"
    drawable = res / "drawable"
    drawable.mkdir(parents=True, exist_ok=True)
    (drawable / "ic_launcher.png").write_bytes(png_bytes)
    for density in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"):
        folder = res / f"mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "ic_launcher.png").write_bytes(png_bytes)
    anydpi = res / "mipmap-anydpi-v26"
    if anydpi.exists():
        shutil.rmtree(anydpi, ignore_errors=True)
    manifest = project / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    if manifest.is_file():
        text = read_text(manifest)
        text = text.replace('android:icon="@mipmap/ic_launcher"', 'android:icon="@drawable/ic_launcher"')
        manifest.write_text(text, encoding="utf-8")


def copy_project(source: Path, dest: Path, log) -> None:
    def ignore(dirpath, names):
        skipped = []
        for name in names:
            if name in SKIP_COPY_NAMES:
                skipped.append(name)
        return skipped

    log(f"Copying project to temp: {dest}")
    shutil.copytree(source, dest, ignore=ignore, dirs_exist_ok=False)


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    stem, suffix = path.stem, path.suffix
    parent = path.parent
    n = 2
    while True:
        candidate = parent / f"{stem}-{n}{suffix}"
        if not candidate.exists():
            return candidate
        n += 1


def find_built_apk(project: Path) -> Path | None:
    candidates = [
        project / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk",
        project / "build" / "app" / "outputs" / "apk" / "release" / "app-release.apk",
    ]
    for item in candidates:
        if item.is_file():
            return item
    outputs = project / "build" / "app" / "outputs"
    if outputs.is_dir():
        found = list(outputs.rglob("app-release.apk"))
        if found:
            return found[0]
    return None


def emit(job: dict, event: str, **payload) -> None:
    job["events"].put({"event": event, **payload})


def run_build(job_id: str, payload: dict) -> None:
    with JOBS_LOCK:
        job = JOBS[job_id]
    log_q: queue.Queue = job["events"]

    def log(line: str) -> None:
        emit(job, "log", line=line)

    temp_root = None
    proc = None
    try:
        source = Path(payload["sourcePath"]).resolve()
        output_dir = Path(payload["outputDir"]).resolve()
        filename = (payload.get("filename") or "").strip() or f"{source.name}-release.apk"
        if not filename.lower().endswith(".apk"):
            filename += ".apk"
        overwrite = payload.get("conflict") == "overwrite"
        app_id = payload["applicationId"].strip()
        app_name = (payload.get("appName") or "").strip()
        icon_b64 = payload.get("iconPngBase64")

        if not is_flutter_android_app(source):
            raise RuntimeError("Selected source is not a Flutter Android app.")
        if not APP_ID_RE.match(app_id):
            raise RuntimeError("Android ID must look like com.example.app (at least two dots).")
        if not output_dir.exists():
            output_dir.mkdir(parents=True, exist_ok=True)
        if not output_dir.is_dir():
            raise RuntimeError("Output location must be a folder.")

        dest_apk = output_dir / filename
        if dest_apk.exists() and not overwrite:
            if payload.get("conflict") == "rename":
                dest_apk = unique_path(dest_apk)
                log(f"Output exists; writing instead to {dest_apk}")
            else:
                emit(job, "exists", path=str(dest_apk))
                return

        flutter = find_flutter()
        if not flutter:
            raise RuntimeError("Flutter was not found on PATH. Set FLUTTER_ROOT or add Flutter to PATH.")

        temp_root = Path(tempfile.mkdtemp(prefix="apk-builder-"))
        project = temp_root / "app"
        job["temp"] = str(temp_root)
        copy_project(source, project, log)

        log(f"Setting applicationId to {app_id}")
        patch_application_id(project, app_id)
        if app_name:
            log(f"Setting launcher name to {app_name}")
            patch_label(project, app_name)
        if icon_b64:
            import base64

            raw = icon_b64.split(",", 1)[-1]
            png = base64.b64decode(raw)
            log("Applying custom launcher icon")
            apply_icon(project, png)

        env = os.environ.copy()
        creation = 0
        if os.name == "nt":
            creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)

        for title, args in (
            ("flutter pub get", [flutter, "pub", "get"]),
            ("flutter build apk --release", [flutter, "build", "apk", "--release"]),
        ):
            if job.get("cancel"):
                raise RuntimeError("Cancelled")
            log(f"$ {' '.join(args)}")
            proc = subprocess.Popen(
                args,
                cwd=str(project),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=env,
                creationflags=creation,
            )
            job["proc"] = proc
            assert proc.stdout is not None
            for line in proc.stdout:
                if job.get("cancel"):
                    proc.terminate()
                    raise RuntimeError("Cancelled")
                log(line.rstrip("\n"))
            code = proc.wait()
            job["proc"] = None
            if code != 0:
                raise RuntimeError(f"{title} failed with exit code {code}")

        built = find_built_apk(project)
        if not built:
            raise RuntimeError("Build finished but app-release.apk was not found.")
        shutil.copy2(built, dest_apk)
        log(f"APK saved to {dest_apk}")
        job["apk"] = str(dest_apk)
        emit(job, "success", path=str(dest_apk), download=f"/api/apk/{job_id}")
    except Exception as exc:
        emit(job, "error", message=str(exc))
        log(f"ERROR: {exc}")
    finally:
        job["proc"] = None
        if temp_root and temp_root.exists():
            log("Removing temp copy")
            shutil.rmtree(temp_root, ignore_errors=True)
        emit(job, "done")
        job["finished"] = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[apk-builder] " + (fmt % args) + "\n")

    def _send(self, code: int, body: bytes, content_type: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = parse_qs(parsed.query)

        if path in ("/", "/index.html"):
            html = (STATIC / "index.html").read_bytes()
            self._send(200, html, "text/html; charset=utf-8")
            return
        if path == "/api/meta":
            self._send(
                200,
                _json(
                    {
                        "workspace": str(WORKSPACE),
                        "knownApps": KNOWN_APPS,
                        "drives": windows_drives(),
                        "desktop": str(Path.home() / "Desktop"),
                        "flutter": find_flutter(),
                    }
                ),
            )
            return
        if path == "/api/list":
            target = query.get("path", [str(WORKSPACE)])[0]
            self._send(200, _json(list_dir(Path(target))))
            return
        if path == "/api/inspect":
            target = query.get("path", [""])[0]
            if not target:
                self._send(400, _json({"valid": False, "error": "Missing path"}))
                return
            self._send(200, _json(inspect_app(Path(target))))
            return
        if path == "/api/exists":
            target = query.get("path", [""])[0]
            p = Path(target)
            self._send(200, _json({"path": str(p), "exists": p.exists()}))
            return
        if path.startswith("/api/build/") and path.endswith("/log"):
            job_id = path.split("/")[3]
            self._stream_log(job_id)
            return
        if path.startswith("/api/apk/"):
            job_id = path.rsplit("/", 1)[-1]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            apk = Path(job["apk"]) if job and job.get("apk") else None
            if not apk or not apk.is_file():
                self._send(404, _json({"error": "APK not available"}))
                return
            data = apk.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.android.package-archive")
            self.send_header("Content-Disposition", f'attachment; filename="{apk.name}"')
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self._send(404, _json({"error": "Not found"}))

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/build":
            payload = self._read_json()
            source = payload.get("sourcePath") or ""
            output_dir = payload.get("outputDir") or ""
            if not source or not output_dir:
                self._send(400, _json({"error": "Source folder and output folder are required."}))
                return
            job_id = uuid.uuid4().hex
            with JOBS_LOCK:
                JOBS[job_id] = {
                    "events": queue.Queue(),
                    "finished": False,
                    "cancel": False,
                    "apk": None,
                    "proc": None,
                    "created": time.time(),
                }
            threading.Thread(target=run_build, args=(job_id, payload), daemon=True).start()
            self._send(200, _json({"jobId": job_id}))
            return
        if path == "/api/cancel":
            payload = self._read_json()
            job_id = payload.get("jobId")
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if job:
                job["cancel"] = True
                proc = job.get("proc")
                if proc and proc.poll() is None:
                    proc.terminate()
            self._send(200, _json({"ok": True}))
            return
        self._send(404, _json({"error": "Not found"}))

    def _stream_log(self, job_id: str) -> None:
        with JOBS_LOCK:
            job = JOBS.get(job_id)
        if not job:
            self._send(404, _json({"error": "Unknown job"}))
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        q: queue.Queue = job["events"]
        try:
            while True:
                try:
                    item = q.get(timeout=0.5)
                except queue.Empty:
                    if job.get("finished") and q.empty():
                        break
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                self.wfile.write(f"data: {json.dumps(item)}\n\n".encode("utf-8"))
                self.wfile.flush()
                if item.get("event") == "done":
                    break
        except BrokenPipeError:
            job["cancel"] = True


def main() -> None:
    if not (STATIC / "index.html").is_file():
        raise SystemExit(f"Missing UI file: {STATIC / 'index.html'}")
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"APK builder running at http://{HOST}:{PORT}", flush=True)
    print("This tool copies apps to a temp folder; CITIZEN / RESPONDER / lguver are not edited.", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
