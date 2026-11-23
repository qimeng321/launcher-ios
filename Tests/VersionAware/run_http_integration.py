#!/usr/bin/env python3
"""Local-only integration test. No app data, external game or remote IP is touched."""
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="launcher-version-test-") as td:
    folder = Path(td)
    server_root = folder / "remote"
    base = folder / "base"
    (server_root / "dll").mkdir(parents=True)
    (server_root / "_overlay").mkdir(parents=True)
    base.mkdir()
    (base / ".sg_base_version").write_text("2026111703")
    (base / "Client.swf").write_bytes(b"FWS\x09")
    payload = b"FWS\x09\x00\x00\x00\x13\x00\x00\x00simulated-core-updated"
    (server_root / "dll/SGCore.swf").write_bytes(payload)
    manifest = {
        "version": "2026112401", "requireBase": True, "baseVersion": "2026111703",
        "overlayFiles": [
            {"path": "dll/SGCore.swf", "size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()},
            "resource/item/icon/55555.swf",
        ]
    }
    (server_root / "_overlay/manifest.json").write_text(json.dumps(manifest))

    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

    handler = functools.partial(QuietHandler, directory=str(server_root))
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    try:
        exe = folder / "integration"
        cmd = ["swiftc", "-DRESOURCE_UPDATE_TEST",
               *[str(root / "Sources" / f) for f in (
                   "RuntimeServerSettings.swift", "ResourceHotUpdater.swift",
                   "ResourceVersionManifest.swift", "ResourceVersionUpdater.swift")],
               str(root / "Tests/VersionAware/LocalHTTPIntegration.swift"),
               "-o", str(exe)]
        subprocess.run(cmd, check=True, timeout=90)
        env = dict(os.environ, RESOURCE_UPDATE_TEST_CACHE_ROOT=str(folder / "isolated-cache"))
        run = subprocess.run([str(exe), str(srv.server_port), str(base)],
                             env=env, capture_output=True, text=True, timeout=30)
        if run.returncode:
            raise RuntimeError(f"HTTP integration failed: {run.returncode}: {run.stderr[-1800:]}")
        print(run.stdout.strip())
    finally:
        srv.shutdown()
