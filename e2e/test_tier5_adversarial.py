#!/usr/bin/env python3
from __future__ import annotations

import json
import socket
import sqlite3
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Set, Tuple
from urllib.parse import unquote, urlparse

from e2e_common import (
    E2ETestCase,
    FocusGuard,
    TempWorkspace,
    require_helmctl,
    require_vm_assets,
    run_helmctl,
    run_tier_module_cli,
    validate_browser_observation,
    validate_execution_result,
)
from fixture_server import FixtureServer


def _helm_chrome_pids() -> Set[int]:
    proc = subprocess.run(
        ["pgrep", "-f", "remote-debugging-port=0"],
        capture_output=True,
        text=True,
        timeout=5.0,
    )
    pids: Set[int] = set()
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.isdigit():
            pids.add(int(line))
    return pids


class _IPv6ThreadingHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6


class _LocalLLMServer:
    """Ephemeral OpenAI-compatible HTTP server on 127.0.0.1 or ::1."""

    def __init__(
        self,
        responder: Callable[[Dict[str, Any]], str],
        *,
        ipv6: bool = False,
    ) -> None:
        self.responder = responder
        self.ipv6 = ipv6
        self._server: Optional[ThreadingHTTPServer] = None
        self._thread: Optional[threading.Thread] = None
        self.base_url: str = ""

    def __enter__(self) -> "_LocalLLMServer":
        parent = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(length) if length > 0 else b"{}"
                try:
                    req_json = json.loads(raw_body.decode("utf-8"))
                except json.JSONDecodeError:
                    req_json = {}

                content = parent.responder(req_json)
                payload = json.dumps(
                    {
                        "id": "chatcmpl-t5",
                        "object": "chat.completion",
                        "choices": [
                            {
                                "index": 0,
                                "message": {"role": "assistant", "content": content},
                                "finish_reason": "stop",
                            }
                        ],
                        "usage": {"prompt_tokens": 10, "completion_tokens": 10},
                    }
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, fmt: str, *args: Any) -> None:
                pass

        if self.ipv6:
            self._server = _IPv6ThreadingHTTPServer(("::1", 0), Handler)
            port = self._server.server_address[1]
            self.base_url = f"http://[::1]:{port}"
        else:
            self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            port = self._server.server_address[1]
            self.base_url = f"http://127.0.0.1:{port}"

        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=2.0)


class Tier5AdversarialTests(E2ETestCase):
    """Tier 5 adversarial orchestration, concurrency, OCR latency, and recovery tests."""

    def test_T5_ADV_01_helmctl_run_http_llm_executes_sandbox_and_browser_act(self) -> None:
        """T5-ADV-01: helmctl run with HTTP LLM executes run_command and browser_act end-to-end."""
        require_helmctl()
        pre_chrome = _helm_chrome_pids()

        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "T5OrchestratedRun",
                    "--goal",
                    "Execute sandbox command and verify web target via browser_act",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            coder = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "Forge",
                    "--role",
                    "coder",
                    "--goal",
                    "Write proof file in sandbox",
                    "--backend",
                    "http",
                    "--capabilities",
                    "codeExec,readSharedState,proposeSharedState",
                ],
                db_path=ws.db_path,
            ).json
            browser_agent = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "Lookout",
                    "--role",
                    "browser_analyst",
                    "--goal",
                    "Navigate fixture and click OCR target",
                    "--backend",
                    "http",
                    "--capabilities",
                    "browser,ocr,readSharedState,proposeSharedState",
                ],
                db_path=ws.db_path,
            ).json

            ocr_url = srv.url("/ocr-target")

            def llm_responder(req: Dict[str, Any]) -> str:
                msgs = req.get("messages") or []
                user_text = str(msgs[-1].get("content", "")) if msgs else ""
                if "DECOMPOSE_GOAL" in user_text:
                    return json.dumps(
                        {
                            "tasks": [
                                {
                                    "temp_id": "t1",
                                    "title": "Run sandbox proof",
                                    "instructions": "Write t5_proof.txt in sandbox",
                                    "assigned_agent_id": coder["id"],
                                    "waiting_on_temp_ids": [],
                                },
                                {
                                    "temp_id": "t2",
                                    "title": "Browse OCR target",
                                    "instructions": "Click BRAVO ACTION via browser_act",
                                    "assigned_agent_id": browser_agent["id"],
                                    "waiting_on_temp_ids": ["t1"],
                                },
                            ]
                        }
                    )
                if "Write t5_proof.txt" in user_text:
                    return json.dumps(
                        {
                            "thought": "execute sandbox command",
                            "tool_calls": [
                                {
                                    "id": "call_sb",
                                    "name": "run_command",
                                    "arguments": {
                                        "command": "printf 'T5_ORCH_SANDBOX_OK' > t5_proof.txt && cat t5_proof.txt"
                                    },
                                }
                            ],
                        }
                    )
                return json.dumps(
                    {
                        "thought": "browse and click OCR target",
                        "tool_calls": [
                            {
                                "id": "call_br",
                                "name": "browser_act",
                                "arguments": {
                                    "action": "click_ocr",
                                    "url": ocr_url,
                                    "query": "BRAVO ACTION",
                                },
                            }
                        ],
                    }
                )

            with _LocalLLMServer(llm_responder) as llm_srv:
                with FocusGuard(interval_ms=50, strict_cursor=True) as guard:
                    report = run_helmctl(
                        ["run", "--project", proj["id"], "--max-steps", "10"],
                        db_path=ws.db_path,
                        env={"HELM_LLM_BASE_URL": llm_srv.base_url},
                        timeout=90.0,
                    ).json

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(report["status"], "completed")
            self.assertEqual(report["exceptions"], [])
            self.assertTrue((ws.ws_path / "t5_proof.txt").is_file())
            self.assertEqual(
                (ws.ws_path / "t5_proof.txt").read_text(encoding="utf-8"),
                "T5_ORCH_SANDBOX_OK",
            )
            self.assertTrue(
                any(
                    entry.get("category") == "observation"
                    and entry.get("trustLevel") == "untrustedData"
                    and "BRAVO CLICKED OK" in str(entry.get("content", "")).upper()
                    for entry in report.get("sharedState", [])
                ),
                f"Expected untrustedData browser observation in sharedState: {report.get('sharedState')}",
            )
            browser_artifacts = [
                a for a in report.get("artifacts", []) if a.get("kind") == "browser_screenshot"
            ]
            self.assertTrue(
                len(browser_artifacts) >= 1,
                f"Expected persisted browser_screenshot artifact: {report.get('artifacts')}",
            )
            for art in browser_artifacts:
                rel_path = str(art.get("relativePath", ""))
                self.assertTrue(
                    rel_path.startswith(".helm/artifacts/browser/"),
                    f"Expected workspace-relative browser artifact path, got {rel_path!r}",
                )
                artifact_file = ws.ws_path / rel_path
                self.assertTrue(
                    artifact_file.is_file(),
                    f"Expected artifactExists == True at {artifact_file}",
                )
                self.assertGreater(artifact_file.stat().st_size, 0)

            conn = sqlite3.connect(str(ws.db_path))
            try:
                rows = conn.execute(
                    "SELECT payload_json FROM events WHERE project_id = ? AND kind = 'toolExecuted'",
                    (proj["id"],),
                ).fetchall()
            finally:
                conn.close()
            browser_obs_paths = []
            for (payload_json,) in rows:
                if not payload_json:
                    continue
                payload = json.loads(payload_json)
                if "screenshotPNGPath" in payload:
                    raw_path = str(payload["screenshotPNGPath"])
                    if raw_path.startswith("file://"):
                        raw_path = unquote(urlparse(raw_path).path)
                    browser_obs_paths.append(raw_path)
            self.assertTrue(browser_obs_paths, "Expected browser_act toolExecuted event with screenshotPNGPath")
            browser_artifacts_dir = (ws.ws_path / ".helm" / "artifacts" / "browser").resolve()
            for obs_path in browser_obs_paths:
                resolved_obs = Path(obs_path).resolve()
                self.assertIn(
                    browser_artifacts_dir,
                    resolved_obs.parents,
                    f"Expected BrowserObservation.screenshotPNGPath inside {browser_artifacts_dir}, got {obs_path}",
                )
                self.assertTrue(resolved_obs.is_file(), f"Missing BrowserObservation screenshot: {obs_path}")

        time.sleep(0.2)
        self.assertEqual(_helm_chrome_pids() - pre_chrome, set())

    def test_T5_ADV_02_concurrent_2x_vm_and_2x_browser_under_focus_guard(self) -> None:
        """T5-ADV-02: Concurrent 2x Virtualization VM + 2x Headless Browser under FocusGuard."""
        require_helmctl()
        require_vm_assets()
        pre_chrome = _helm_chrome_pids()

        with TempWorkspace() as ws1, TempWorkspace() as ws2, FixtureServer() as srv:
            assert ws1.ws_path is not None and ws2.ws_path is not None
            assert ws1.artifacts_dir is not None and ws2.artifacts_dir is not None

            def run_vm(tag: str, workdir: Any) -> Dict[str, Any]:
                return validate_execution_result(
                    run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(workdir),
                            "--cmd",
                            f"uname -s && printf '{tag}_VM_OK'",
                            "--mode",
                            "vm",
                            "--timeout",
                            "45",
                        ],
                        timeout=60.0,
                    ).json
                )

            def run_browser(path: str, shot: Any) -> Dict[str, Any]:
                return validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url(path),
                            "--screenshot-out",
                            str(shot),
                            "--timeout",
                            "30",
                        ],
                        timeout=45.0,
                    ).json
                )

            with FocusGuard(interval_ms=50, strict_cursor=True) as guard:
                with ThreadPoolExecutor(max_workers=4) as pool:
                    f_vm1 = pool.submit(run_vm, "A", ws1.ws_path)
                    f_vm2 = pool.submit(run_vm, "B", ws2.ws_path)
                    f_br1 = pool.submit(run_browser, "/", ws1.artifacts_dir / "conc1.png")
                    f_br2 = pool.submit(run_browser, "/ocr-target", ws2.artifacts_dir / "conc2.png")

                    vm1 = f_vm1.result()
                    vm2 = f_vm2.result()
                    br1 = f_br1.result()
                    br2 = f_br2.result()

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(vm1["exitCode"], 0)
            self.assertEqual(vm2["exitCode"], 0)
            self.assertIn("A_VM_OK", vm1["stdout"])
            self.assertIn("B_VM_OK", vm2["stdout"])
            self.assertIn("HARBOR READY", "\n".join(l["text"] for l in br1["ocrLines"]).upper())
            self.assertIn("BRAVO ACTION", "\n".join(l["text"] for l in br2["ocrLines"]).upper())

        time.sleep(0.2)
        self.assertEqual(_helm_chrome_pids() - pre_chrome, set())

    def test_T5_ADV_03_cold_process_browser_latency_and_prompt_deadline(self) -> None:
        """T5-ADV-03: Cold-process browser act finishes well within 15s and /slow times out promptly."""
        require_helmctl()
        pre_chrome = _helm_chrome_pids()

        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None

            t0 = time.monotonic()
            obs = validate_browser_observation(
                run_helmctl(
                    [
                        "browser",
                        "act",
                        "--url",
                        srv.url("/ocr-target"),
                        "--screenshot-out",
                        str(ws.artifacts_dir / "cold_ocr.png"),
                        "--timeout",
                        "15",
                    ],
                    timeout=20.0,
                ).json
            )
            cold_elapsed = time.monotonic() - t0
            self.assertLess(cold_elapsed, 12.0, f"Cold browser act took {cold_elapsed:.2f}s")
            self.assertIn("ALPHA TARGET", "\n".join(l["text"] for l in obs["ocrLines"]).upper())

            t1 = time.monotonic()
            slow = run_helmctl(
                [
                    "browser",
                    "act",
                    "--url",
                    srv.url("/slow?delay=10"),
                    "--timeout",
                    "1.5",
                ],
                expect_json=False,
                check=False,
                timeout=10.0,
            )
            slow_elapsed = time.monotonic() - t1
            self.assertNotIn(slow.returncode, (0, 69))
            self.assertLess(slow_elapsed, 5.0, f"Timed-out browser act took {slow_elapsed:.2f}s")

        time.sleep(0.2)
        self.assertEqual(_helm_chrome_pids() - pre_chrome, set())

    def test_T5_ADV_04_crash_recovery_invariants_and_ipv6_loopback_http(self) -> None:
        """T5-ADV-04: Crash recovery reconciles orphaned running external task & IPv6 [::1] HTTP LLM works."""
        require_helmctl()

        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "CrashRecovery",
                    "--goal",
                    "Recover cleanly after simulated abrupt crash",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            agent = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "Worker",
                    "--role",
                    "coder",
                    "--goal",
                    "Complete work",
                    "--backend",
                    "http",
                ],
                db_path=ws.db_path,
            ).json

            # Inject an orphaned .running project + .running external side-effect task directly in SQLite
            task_id = "11111111-1111-1111-1111-111111111111"
            now_ts = time.time()
            conn = sqlite3.connect(str(ws.db_path))
            try:
                conn.execute(
                    "UPDATE projects SET status = 'running', updated_at = ? WHERE id = ?",
                    (now_ts, proj["id"]),
                )
                conn.execute(
                    """
                    INSERT INTO tasks (
                        id, project_id, parent_task_id, assigned_agent_id, created_by_agent_id,
                        title, instructions, status, waiting_on_json, attempt_count, max_attempts,
                        has_external_side_effect, result_summary, error_summary, artifact_paths_json,
                        created_at, updated_at, started_at, completed_at
                    ) VALUES (?, ?, NULL, ?, NULL, ?, ?, 'running', '[]', 0, 3, 1, NULL, NULL, '[]', ?, ?, ?, NULL)
                    """,
                    (
                        task_id,
                        proj["id"],
                        agent["id"],
                        "Interrupted External Task",
                        "Finish cleanly",
                        now_ts,
                        now_ts,
                        now_ts,
                    ),
                )
                conn.commit()
            finally:
                conn.close()

            # Fresh process triggers boot crash recovery -> holds with humanDecision
            held = run_helmctl(
                ["run", "--project", proj["id"], "--max-steps", "5"],
                db_path=ws.db_path,
            ).json
            self.assertEqual(held["status"], "held")
            self.assertEqual(len(held["exceptions"]), 1)
            self.assertEqual(held["exceptions"][0]["kind"], "humanDecision")
            self.assertEqual(held["tasks"][0]["status"], "outcomeUnknown")

            # Resolve via retry, then resume via IPv6 [::1] HTTP LLM without API key
            run_helmctl(
                [
                    "exceptions",
                    "resolve",
                    "--id",
                    held["exceptions"][0]["id"],
                    "--action",
                    "retry",
                ],
                db_path=ws.db_path,
            )

            def ipv6_responder(_req: Dict[str, Any]) -> str:
                return json.dumps(
                    {
                        "thought": "recovered",
                        "tool_calls": [
                            {
                                "id": "done1",
                                "name": "complete_task",
                                "arguments": {"summary": "Recovered over IPv6 loopback"},
                            }
                        ],
                    }
                )

            with _LocalLLMServer(ipv6_responder, ipv6=True) as ipv6_srv:
                resumed = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "5"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": ipv6_srv.base_url},
                ).json
            self.assertEqual(resumed["status"], "completed")
            self.assertEqual(resumed["tasks"][0]["status"], "done")


if __name__ == "__main__":
    raise SystemExit(run_tier_module_cli("5"))
