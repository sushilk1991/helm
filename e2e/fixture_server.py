#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import os
import signal
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, Optional
from urllib.parse import parse_qs, urlparse

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def _load_fixture(filename: str) -> str:
    return (FIXTURES_DIR / filename).read_text(encoding="utf-8")


def _build_large_dom_html() -> str:
    template = _load_fixture("large_dom.html")
    nodes = [
        f'<button class="item-btn" id="item-{i:03d}" type="button">ITEM_{i:03d}</button>'
        for i in range(1, 501)
    ]
    return template.replace("{{ITEMS}}", "\n    ".join(nodes))


class _FixtureHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 128

    def __init__(self, server_address: tuple[str, int], stop_event: threading.Event):
        self.stop_event = stop_event
        self.verbose = os.environ.get("HELM_FIXTURE_VERBOSE") == "1"
        self._large_dom_html = _build_large_dom_html()
        self._static_pages: Dict[str, str] = {
            "/": _load_fixture("index.html"),
            "/form": _load_fixture("form.html"),
            "/ocr-target": _load_fixture("ocr_target.html"),
            "/prompt-injection": _load_fixture("prompt_injection.html"),
            "/blank": _load_fixture("blank.html"),
            "/404": _load_fixture("404.html"),
            "/slow": _load_fixture("slow.html"),
            "/passkey": _load_fixture("passkey.html"),
            "/offscale": _load_fixture("offscale.html"),
            "/large-dom": self._large_dom_html,
        }
        self._result_template = _load_fixture("result.html")
        super().__init__(server_address, _FixtureRequestHandler)

    def handle_error(self, request, client_address) -> None:
        exc_type, exc_val, _ = sys.exc_info()
        if exc_type is not None and issubclass(
            exc_type, (BrokenPipeError, ConnectionResetError, TimeoutError, OSError)
        ):
            return
        super().handle_error(request, client_address)


class _FixtureRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args) -> None:
        if getattr(self.server, "verbose", False):
            super().log_message(format, *args)

    def _send_bytes(
        self, status: int, content_type: str, payload: bytes
    ) -> None:
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
            pass

    def _send_html(self, status: int, body: str) -> None:
        self._send_bytes(status, "text/html; charset=utf-8", body.encode("utf-8"))

    def _send_json(self, status: int, obj: object) -> None:
        payload = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        self._send_bytes(status, "application/json; charset=utf-8", payload)

    def _render_result(self, params: Dict[str, list[str]]) -> None:
        code_val = html.escape(params.get("code", [""])[0])
        note_val = html.escape(params.get("note", [""])[0])
        body = self.server._result_template.replace("{{CODE}}", code_val).replace(
            "{{NOTE}}", note_val
        )
        self._send_html(HTTPStatus.OK, body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        route = parsed.path
        query = parse_qs(parsed.query, keep_blank_values=True)

        if route == "/health":
            self._send_json(
                HTTPStatus.OK,
                {"status": "ok", "server": "HelmE2EFixtureServer"},
            )
            return

        if route == "/result":
            self._render_result(query)
            return

        if route == "/404":
            self._send_html(HTTPStatus.NOT_FOUND, self.server._static_pages["/404"])
            return

        if route == "/slow":
            delay_sec = 70.0
            raw_delay = query.get("delay", [None])[0]
            if raw_delay is not None:
                try:
                    delay_sec = max(0.0, float(raw_delay))
                except ValueError:
                    delay_sec = 70.0

            deadline = time.monotonic() + delay_sec
            while time.monotonic() < deadline:
                if self.server.stop_event.is_set():
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.server.stop_event.wait(min(0.1, remaining))

            if self.server.stop_event.is_set():
                return
            self._send_html(HTTPStatus.OK, self.server._static_pages["/slow"])
            return

        if route in self.server._static_pages:
            self._send_html(HTTPStatus.OK, self.server._static_pages[route])
            return

        self._send_html(HTTPStatus.NOT_FOUND, self.server._static_pages["/404"])

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        route = parsed.path
        if route == "/result":
            content_length = 0
            raw_len = self.headers.get("Content-Length")
            if raw_len:
                try:
                    content_length = max(0, min(int(raw_len), 1_048_576))
                except ValueError:
                    content_length = 0
            raw_body = self.rfile.read(content_length).decode("utf-8", errors="replace")
            params = parse_qs(parsed.query, keep_blank_values=True)
            body_params = parse_qs(raw_body, keep_blank_values=True)
            params.update(body_params)
            self._render_result(params)
            return

        self._send_html(HTTPStatus.NOT_FOUND, self.server._static_pages["/404"])


class FixtureServer:
    """Ephemeral stdlib ThreadingHTTPServer bound to 127.0.0.1:0."""

    def __init__(self, host: str = "127.0.0.1", port: int = 0) -> None:
        if port == 9222:
            raise ValueError("Refusing to bind fixture server to port 9222")
        self.host = host
        self._requested_port = port
        self._stop_event = threading.Event()
        self._httpd: Optional[_FixtureHTTPServer] = None
        self._thread: Optional[threading.Thread] = None
        self.port: int = 0

    @property
    def base_url(self) -> str:
        if self.port <= 0:
            raise RuntimeError("FixtureServer is not started")
        return f"http://{self.host}:{self.port}"

    def url(self, path: str) -> str:
        if not path.startswith("/"):
            path = "/" + path
        return f"{self.base_url}{path}"

    def start(self) -> "FixtureServer":
        if self._httpd is not None:
            return self
        self._stop_event.clear()
        self._httpd = _FixtureHTTPServer(
            (self.host, self._requested_port), self._stop_event
        )
        self.port = int(self._httpd.server_address[1])
        if self.port == 9222:
            self._httpd.server_close()
            self._httpd = None
            raise RuntimeError("Ephemeral port unexpectedly resolved to 9222")
        self._thread = threading.Thread(
            target=self._httpd.serve_forever,
            kwargs={"poll_interval": 0.1},
            name="HelmE2EFixtureServer",
            daemon=True,
        )
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop_event.set()
        if self._httpd is not None:
            try:
                self._httpd.shutdown()
            except Exception:
                pass
            try:
                self._httpd.server_close()
            except Exception:
                pass
            self._httpd = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        self.port = 0

    def __enter__(self) -> "FixtureServer":
        return self.start()

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.stop()


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Helm E2E local HTTP fixture server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args(argv)

    stop_flag = threading.Event()

    def _handle_sig(_signum, _frame) -> None:
        stop_flag.set()

    signal.signal(signal.SIGINT, _handle_sig)
    signal.signal(signal.SIGTERM, _handle_sig)

    with FixtureServer(host=args.host, port=args.port) as srv:
        print(
            json.dumps(
                {
                    "status": "listening",
                    "base_url": srv.base_url,
                    "host": srv.host,
                    "port": srv.port,
                }
            ),
            flush=True,
        )
        while not stop_flag.is_set():
            stop_flag.wait(0.2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
