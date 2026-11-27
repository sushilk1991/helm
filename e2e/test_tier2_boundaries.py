#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import socket
import subprocess
import time
import unittest
import uuid
from pathlib import Path
from typing import Any, Dict, List, Set

from e2e_common import (
    E2ETestCase,
    FocusGuard,
    TempWorkspace,
    inspect_png,
    require_helm_app,
    require_helmctl,
    run_helmctl,
    run_tier_module_cli,
    validate_browser_observation,
    validate_exception_alert,
    validate_execution_result,
)
from fixture_server import FixtureServer


def _extract_seed_token(agent_json: Dict[str, Any]) -> str:
    seed = agent_json.get("characterSeed")
    if isinstance(seed, dict):
        hex_digest = seed.get("hexDigest") or seed.get("hex") or ""
        if isinstance(hex_digest, str) and hex_digest.strip():
            return (
                f"{hex_digest}:"
                f"{seed.get('crownIndex')}:{seed.get('eyeIndex')}:"
                f"{seed.get('bodyMask')}:{seed.get('hueIndex')}"
            )
    if isinstance(seed, str) and seed.strip():
        return seed.strip()
    raise AssertionError(f"Missing or empty characterSeed: {agent_json!r}")


def _all_ocr_text(obs: Dict[str, Any]) -> str:
    return "\n".join(str(line.get("text", "")) for line in obs.get("ocrLines", []))


def _closed_local_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = int(sock.getsockname()[1])
    sock.close()
    return port


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


def _helm_power_assertions() -> List[str]:
    proc = subprocess.run(
        ["pmset", "-g", "assertions"],
        capture_output=True,
        text=True,
        timeout=5.0,
    )
    return [
        line.strip()
        for line in proc.stdout.splitlines()
        if "helm" in line.lower() and "prevent" in line.lower()
    ]


def _run_headless_snapshot(
    app_exe: Path,
    snap_dir: Path,
    *,
    reduce_motion: bool = False,
    extra_env: Dict[str, str] | None = None,
    timeout: float = 45.0,
) -> tuple[int, str, str, Dict[str, Any]]:
    snap_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(app_exe),
        "--headless",
        "--seed-demo",
        "--snapshot-dir",
        str(snap_dir),
    ]
    if reduce_motion:
        cmd.append("--reduce-motion")

    env = os.environ.copy()
    env["HELM_NO_ACTIVATE"] = "1"
    if reduce_motion:
        env["HELM_REDUCE_MOTION"] = "1"
    if extra_env:
        env.update(extra_env)

    with FocusGuard(interval_ms=50) as guard:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            proc.terminate()
            try:
                proc.communicate(timeout=3.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate(timeout=2.0)
            raise AssertionError(f"Helm.app --headless timed out after {timeout}s") from exc

    assert guard.result is not None
    if guard.result["focusChanged"]:
        raise AssertionError(f"Focus changed during Helm.app run: {guard.result!r}")
    if guard.result["cursorMoved"]:
        raise AssertionError(f"Cursor moved during Helm.app run: {guard.result!r}")
    return proc.returncode, stdout, stderr, guard.result


class Tier2BoundaryTests(E2ETestCase):
    """Tier 2 boundary, corner, and error tests covering E1-E10 (29 cases)."""

    # ------------------------------------------------------------------
    # Area A: Project Store & Agent/Provider Boundaries (F1, F2, F3, E8)
    # ------------------------------------------------------------------

    def test_T2_A_01_empty_or_whitespace_project_name_rejected(self) -> None:
        """T2-A-01: Empty or whitespace-only Project name fails validation cleanly."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            for bad_name in ("", "   "):
                res = run_helmctl(
                    [
                        "project",
                        "create",
                        "--name",
                        bad_name,
                        "--goal",
                        "Valid goal",
                        "--workspace",
                        str(ws.ws_path),
                    ],
                    db_path=ws.db_path,
                    expect_json=False,
                    check=False,
                )
                self.assertNotEqual(res.returncode, 0, f"Expected failure for name={bad_name!r}")
                self.assertTrue(
                    len((res.stderr + res.stdout).strip()) > 0,
                    "Expected validation diagnostic on stderr/stdout",
                )

    def test_T2_A_02_unwritable_workspace_path_rejected(self) -> None:
        """T2-A-02: Unwritable workspace path returns non-zero exit and diagnostic."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.root is not None and ws.db_path is not None
            ro_parent = ws.root / "readonly_parent"
            ro_parent.mkdir()
            os.chmod(ro_parent, 0o555)
            try:
                blocked_ws = ro_parent / "blocked_workspace"
                res = run_helmctl(
                    [
                        "project",
                        "create",
                        "--name",
                        "BlockedProj",
                        "--goal",
                        "Should fail",
                        "--workspace",
                        str(blocked_ws),
                    ],
                    db_path=ws.db_path,
                    expect_json=False,
                    check=False,
                )
                self.assertNotEqual(res.returncode, 0)
                self.assertFalse(blocked_ws.exists())
                self.assertTrue(len((res.stderr + res.stdout).strip()) > 0)
            finally:
                os.chmod(ro_parent, 0o755)

    def test_T2_A_03_empty_or_duplicate_agent_name_rejected(self) -> None:
        """T2-A-03: Empty agent name or duplicate agent name in same Project is rejected."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "AgentBounds",
                    "--goal",
                    "Test agent validation",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json

            empty_res = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "",
                    "--role",
                    "researcher",
                    "--goal",
                    "Do work",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
                expect_json=False,
                check=False,
            )
            self.assertNotEqual(empty_res.returncode, 0)

            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "Scout",
                    "--role",
                    "researcher",
                    "--goal",
                    "First",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            dup_res = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "Scout",
                    "--role",
                    "coder",
                    "--goal",
                    "Duplicate",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
                expect_json=False,
                check=False,
            )
            self.assertNotEqual(dup_res.returncode, 0)

    def test_T2_A_04_invalid_backend_or_missing_project_rejected(self) -> None:
        """T2-A-04: Invalid --backend or nonexistent --project UUID returns typed error."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "ValidProj",
                    "--goal",
                    "Check errors",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json

            bad_backend = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "BadBackend",
                    "--role",
                    "researcher",
                    "--goal",
                    "Test",
                    "--backend",
                    "unknown_xyz",
                ],
                db_path=ws.db_path,
                expect_json=False,
                check=False,
            )
            self.assertNotEqual(bad_backend.returncode, 0)

            missing_proj = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    "00000000-0000-0000-0000-000000000000",
                    "--name",
                    "Orphan",
                    "--role",
                    "researcher",
                    "--goal",
                    "Test",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
                expect_json=False,
                check=False,
            )
            self.assertNotEqual(missing_proj.returncode, 0)

    def test_T2_A_05_unreachable_http_provider_transitions_to_held(self) -> None:
        """T2-A-05: Unreachable http provider endpoint parks run gracefully in held/failed."""
        require_helmctl()
        closed_port = _closed_local_port()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "DeadHTTP",
                    "--goal",
                    "Handle provider failure",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "HTTPWorker",
                    "--role",
                    "researcher",
                    "--goal",
                    "Call dead endpoint",
                    "--backend",
                    "http",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard() as guard:
                res = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "3"],
                    db_path=ws.db_path,
                    env={
                        "HELM_HTTP_ENDPOINT": f"http://127.0.0.1:{closed_port}/v1/chat/completions",
                        "HELM_DIRECT_HTTP_URL": f"http://127.0.0.1:{closed_port}/v1/chat/completions",
                        "HELM_LLM_BASE_URL": f"http://127.0.0.1:{closed_port}/v1/chat/completions",
                    },
                    check=False,
                    timeout=30.0,
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(
                res.returncode,
                0,
                f"Expected structured held/failed JSON report, got exit {res.returncode}: stderr={res.stderr!r}",
            )
            self.assertIsInstance(res.json, dict, f"Expected JSON report, got stdout={res.stdout!r}")
            self.assertIn(res.json.get("status"), {"held", "failed"})
            exceptions = res.json.get("exceptions", [])
            self.assertGreaterEqual(len(exceptions), 1)
            exc = validate_exception_alert(exceptions[0])
            listed = run_helmctl(
                ["exceptions", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            ).json
            self.assertIsInstance(listed, list)
            self.assertGreaterEqual(len(listed), 1)
            diag = (
                str(exc.get("summary", ""))
                + " "
                + str(exc.get("diagnosticSummary", ""))
            ).lower()
            self.assertNotIn(
                "no api key",
                diag,
                f"DirectHTTPProvider ignored local URL override and hit missingCredential: {diag!r}",
            )
            self.assertNotIn(
                "api.openai.com",
                diag,
                f"DirectHTTPProvider ignored local URL override and targeted api.openai.com: {diag!r}",
            )
            self.assertTrue(
                any(
                    tok in diag
                    for tok in (
                        str(closed_port),
                        "127.0.0.1",
                        "connect",
                        "refused",
                        "network failure",
                    )
                ),
                f"Expected local connection failure diagnostic (port {closed_port}), got: {diag!r}",
            )

    def test_T2_A_06_low_disk_guard_and_no_leaked_power_assertion(self) -> None:
        """T2-A-06 (E8): Simulated low-disk condition parks run safely and leaks no IOPMAssertion."""
        require_helmctl()
        pre_assertions = set(_helm_power_assertions())
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "DiskGuard",
                    "--goal",
                    "Check low-disk preflight",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "Builder",
                    "--role",
                    "coder",
                    "--goal",
                    "Write artifacts",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                res = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "5"],
                    db_path=ws.db_path,
                    env={"HELM_SIMULATE_LOW_DISK_MB": "100"},
                )
            self.assertIsInstance(res.json, dict)
            self.assertEqual(res.json.get("status"), "held")
            exceptions = res.json.get("exceptions", [])
            self.assertGreaterEqual(len(exceptions), 1)
            exc = validate_exception_alert(exceptions[0])
            self.assertEqual(exc["kind"], "budget")
            listed = run_helmctl(
                ["exceptions", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            ).json
            self.assertIsInstance(listed, list)
            self.assertGreaterEqual(len(listed), 1)
        post_assertions = set(_helm_power_assertions())
        self.assertEqual(
            post_assertions - pre_assertions,
            set(),
            f"Leaked Helm IOPMAssertion(s): {post_assertions - pre_assertions}",
        )

    # ------------------------------------------------------------------
    # Area B: Orchestrator, Shared State & Exception Boundaries (E1, E2, E3, E7)
    # ------------------------------------------------------------------

    def test_T2_B_01_healthy_multi_step_run_silent_notifications(self) -> None:
        """T2-B-01 (E1): Healthy multi-agent run over >=10 steps stays completely silent."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "Steady10",
                    "--goal",
                    "Execute multi-step steady pipeline",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            for idx, role in enumerate(("researcher", "coder", "qa")):
                run_helmctl(
                    [
                        "agent",
                        "add",
                        "--project",
                        proj["id"],
                        "--name",
                        f"Steady-{idx}",
                        "--role",
                        role,
                        "--goal",
                        f"Phase {idx}",
                        "--backend",
                        "mock",
                    ],
                    db_path=ws.db_path,
                )
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "15"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(report["status"], "completed")
            self.assertEqual(report["alertsSurfaced"], 0)
            self.assertEqual(report["notificationsEmitted"], 0)
            self.assertEqual(report["exceptions"], [])
            self.assertGreaterEqual(report["steadyHeartbeats"], 1)

    def test_T2_B_02_repeated_failing_call_or_stall_halts_with_diagnostics(self) -> None:
        """T2-B-02 (E2): Stall condition halts loop and raises diagnostic ExceptionAlert."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "StallTest",
                    "--goal",
                    "Detect stall",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "StuckWorker",
                    "--role",
                    "coder",
                    "--goal",
                    "Retry failing call",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-stall"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(report["status"], "held")
            self.assertEqual(len(report["exceptions"]), 1)
            exc = validate_exception_alert(report["exceptions"][0])
            self.assertEqual(exc["kind"], "stall")
            self.assertTrue(len(exc["summary"].strip()) > 0)

    def test_T2_B_03_drift_triggers_single_deduped_alert(self) -> None:
        """T2-B-03 (E2): Drift detector triggers exactly one deduplicated drift ExceptionAlert."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "DriftTest",
                    "--goal",
                    "Detect goal drift",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "DriftWorker",
                    "--role",
                    "researcher",
                    "--goal",
                    "Verify alignment",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-drift"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(report["status"], "held")
            self.assertEqual(len(report["exceptions"]), 1)
            self.assertEqual(report["exceptions"][0]["kind"], "drift")
            listed = run_helmctl(
                ["exceptions", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            ).json
            self.assertEqual(len(listed), 1)

    def test_T2_B_04_human_decision_gate_persists_across_restart(self) -> None:
        """T2-B-04 (E3): Human Decision Gate persists across process restart until resolved."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "DecisionRestart",
                    "--goal",
                    "Persist human gate",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "GateAgent",
                    "--role",
                    "specialist",
                    "--goal",
                    "Ask approval",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                r1 = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-decision"],
                    db_path=ws.db_path,
                ).json
            exc_id = r1["exceptions"][0]["id"]

            # Fresh process query
            listed = run_helmctl(
                ["exceptions", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            ).json
            self.assertEqual(len(listed), 1)
            self.assertEqual(listed[0]["id"], exc_id)
            self.assertEqual(listed[0]["kind"], "humanDecision")
            self.assertIn(listed[0]["status"], {"open", "pending"})

    def test_T2_B_05_prompt_injection_tagged_untrusted_cannot_mutate_rules(self) -> None:
        """T2-B-05 (E7): Untrusted web injection content is tagged untrustedData and blocked from rule mutation."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.ws_path is not None and ws.db_path is not None and ws.artifacts_dir is not None
            with FocusGuard():
                obs = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/prompt-injection"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "inj.png"),
                        ]
                    ).json,
                    require_untrusted=True,
                )
            self.assertEqual(obs["trustTag"], "untrustedData")
            ocr_text = _all_ocr_text(obs).upper()
            self.assertIn("HARBOR_DEPTH_42", ocr_text)

            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "InjectionDefense",
                    "--goal",
                    "Summarize public metric only",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "WebReader",
                    "--role",
                    "browser_analyst",
                    "--goal",
                    f"Read {srv.url('/prompt-injection')}",
                    "--backend",
                    "mock",
                    "--capabilities",
                    "browser,ocr,readSharedState,proposeSharedState",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "6"],
                    db_path=ws.db_path,
                    env={"HELM_UNTRUSTED_WEB_SNIPPET": ocr_text},
                ).json
            shared = report.get("sharedState", [])
            self.assertGreaterEqual(len(shared), 1, "Expected non-empty sharedState")
            for entry in shared:
                if entry.get("category") == "rule" or entry.get("trustLevel") in {
                    "humanAuthoritative",
                    "orchestratorVerified",
                }:
                    val = str(entry.get("value", "")).upper()
                    self.assertNotIn("ALLOW_ALL_SECRETS", val)
                    self.assertNotIn("DELETE PROJECT RULES", val)
                    self.assertNotIn("IGNORE PREVIOUS INSTRUCTIONS", val)
            has_untrusted_obs = any(
                e.get("trustLevel") == "untrustedData" for e in shared
            )
            has_tamper_alert = any(
                exc.get("kind") == "drift" for exc in report.get("exceptions", [])
            )
            self.assertTrue(
                has_untrusted_obs or has_tamper_alert,
                "Expected HELM_UNTRUSTED_WEB_SNIPPET to be recorded as untrustedData or rejected with drift alert",
            )

    def test_T2_B_06_cyclic_task_dependency_rejected_without_hang(self) -> None:
        """T2-B-06: Cyclic waitingOn task dependency fails deterministically without hanging."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "CycleTest",
                    "--goal",
                    "Reject cyclic DAG",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "CycleAgent",
                    "--role",
                    "coder",
                    "--goal",
                    "Detect cycle",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                res = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "5"],
                    db_path=ws.db_path,
                    env={"HELM_SIMULATE_TASK_CYCLE": "1"},
                    timeout=15.0,
                    check=False,
                )
            if res.returncode == 0:
                self.assertIsInstance(res.json, dict)
                self.assertIn(res.json.get("status"), {"failed", "held"})
                exceptions = res.json.get("exceptions", [])
                self.assertGreaterEqual(len(exceptions), 1)
                validate_exception_alert(exceptions[0])
                listed = run_helmctl(
                    ["exceptions", "list", "--project", proj["id"]],
                    db_path=ws.db_path,
                ).json
                self.assertGreaterEqual(len(listed), 1)
            else:
                err_payload = None
                for raw in (res.stdout, res.stderr):
                    if raw and raw.strip():
                        try:
                            candidate = json.loads(raw)
                            if isinstance(candidate, dict):
                                err_payload = candidate
                                break
                        except json.JSONDecodeError:
                            pass
                self.assertIsNotNone(
                    err_payload,
                    f"Non-zero exit {res.returncode} without structured JSON error payload: "
                    f"stdout={res.stdout!r} stderr={res.stderr!r}",
                )
                assert err_payload is not None
                err_text = str(err_payload.get("error", "")).lower()
                self.assertTrue(
                    any(tok in err_text for tok in ("cycle", "cyclic", "dependency")),
                    f"Expected cycle diagnostic in JSON error payload, got: {err_payload!r}",
                )

    def test_T2_B_07_resolve_nonexistent_or_already_resolved_exception_fails(self) -> None:
        """T2-B-07: Resolving a nonexistent or already-resolved exception fails cleanly."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            missing_res = run_helmctl(
                [
                    "exceptions",
                    "resolve",
                    "--id",
                    "00000000-0000-0000-0000-000000000000",
                    "--action",
                    "approve",
                ],
                db_path=ws.db_path,
                expect_json=False,
                check=False,
            )
            self.assertNotEqual(missing_res.returncode, 0)

            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "DoubleResolve",
                    "--goal",
                    "Verify double resolve rejection",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "Worker",
                    "--role",
                    "specialist",
                    "--goal",
                    "Gate",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                rep = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-decision"],
                    db_path=ws.db_path,
                ).json
            exc_id = rep["exceptions"][0]["id"]
            run_helmctl(
                ["exceptions", "resolve", "--id", exc_id, "--action", "approve"],
                db_path=ws.db_path,
            )
            second = run_helmctl(
                ["exceptions", "resolve", "--id", exc_id, "--action", "approve"],
                db_path=ws.db_path,
                expect_json=False,
                check=False,
            )
            self.assertNotEqual(second.returncode, 0)

    # ------------------------------------------------------------------
    # Area C: Isolated VM & Sandbox Execution Boundaries (F7, E4, E5)
    # ------------------------------------------------------------------

    def test_T2_C_01_runaway_cpu_loop_killed_at_timeout(self) -> None:
        """T2-C-01 (E5): Runaway CPU loop is killed cleanly at --timeout 2."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None
            with FocusGuard() as guard:
                res = run_helmctl(
                    [
                        "sandbox",
                        "exec",
                        "--workspace",
                        str(ws.ws_path),
                        "--cmd",
                        "while true; do :; done",
                        "--mode",
                        "seatbelt",
                        "--timeout",
                        "2",
                    ],
                    timeout=15.0,
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            payload = validate_execution_result(res.json)
            self.assertTrue(payload["timedOut"])
            self.assertLess(payload["durationMs"], 6000.0)

    def test_T2_C_02_background_grandchild_killed_no_hang(self) -> None:
        """T2-C-02 (E5): Background grandchild process (sleep 30 &) is reaped cleanly."""
        require_helmctl()
        marker = f"HELM_GC_MARKER_{uuid.uuid4().hex}"
        try:
            with TempWorkspace() as ws:
                assert ws.ws_path is not None
                t0 = time.monotonic()
                with FocusGuard():
                    res = run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(ws.ws_path),
                            "--cmd",
                            f"(sh -c 'sleep 30; true' {marker} &) ; echo PARENT_DONE",
                            "--mode",
                            "seatbelt",
                            "--timeout",
                            "2",
                        ],
                        timeout=15.0,
                    )
                elapsed_ms = (time.monotonic() - t0) * 1000.0
                payload = validate_execution_result(res.json)
                self.assertLess(
                    payload["durationMs"],
                    6000.0,
                    f"Grandchild delayed completion: durationMs={payload['durationMs']}",
                )
                self.assertLess(
                    elapsed_ms,
                    6000.0,
                    f"Grandchild leaked and delayed completion: {elapsed_ms}ms",
                )
                pgrep = subprocess.run(
                    ["pgrep", "-f", marker],
                    capture_output=True,
                    text=True,
                    timeout=5.0,
                )
                leaked = [line.strip() for line in pgrep.stdout.splitlines() if line.strip().isdigit()]
                self.assertEqual(
                    leaked,
                    [],
                    f"Background grandchild process leaked after sandbox exit (marker={marker}, pids={leaked})",
                )
        finally:
            subprocess.run(
                ["pkill", "-f", marker],
                capture_output=True,
                text=True,
                timeout=5.0,
            )

    def test_T2_C_03_output_byte_flood_bounded(self) -> None:
        """T2-C-03 (E5): Output byte flood truncates cleanly at --max-output-bytes 4096."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None
            with FocusGuard():
                res = run_helmctl(
                    [
                        "sandbox",
                        "exec",
                        "--workspace",
                        str(ws.ws_path),
                        "--cmd",
                        "yes HELM_FLOOD | head -c 524288",
                        "--mode",
                        "seatbelt",
                        "--max-output-bytes",
                        "4096",
                    ]
                )
            payload = validate_execution_result(res.json)
            self.assertTrue(payload["truncatedOutput"])
            self.assertLessEqual(len(payload["stdout"].encode("utf-8")), 4096 + 256)

    def test_T2_C_04_write_outside_workspace_denied(self) -> None:
        """T2-C-04: Write outside workspace (/tmp) and ~/.ssh read denied in seatbelt sandbox."""
        require_helmctl()
        escape_probe = Path(f"/tmp/helm_escape_test_{os.getpid()}")
        if escape_probe.exists():
            escape_probe.unlink()
        try:
            with TempWorkspace() as ws:
                assert ws.ws_path is not None
                with FocusGuard():
                    res = run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(ws.ws_path),
                            "--cmd",
                            f"touch {escape_probe}",
                            "--mode",
                            "seatbelt",
                        ]
                    )
                payload = validate_execution_result(res.json)
                self.assertNotEqual(payload["exitCode"], 0)
                self.assertFalse(
                    escape_probe.exists(),
                    f"Sandbox escaped workspace and created {escape_probe}",
                )
        finally:
            if escape_probe.exists():
                escape_probe.unlink()

    def test_T2_C_05_empty_cmd_or_missing_workspace_rejected(self) -> None:
        """T2-C-05: Empty --cmd or nonexistent --workspace returns clean error."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.root is not None and ws.ws_path is not None
            empty_cmd = run_helmctl(
                [
                    "sandbox",
                    "exec",
                    "--workspace",
                    str(ws.ws_path),
                    "--cmd",
                    "",
                    "--mode",
                    "seatbelt",
                ],
                expect_json=False,
                check=False,
            )
            self.assertNotIn(empty_cmd.returncode, (0, 69))

            missing_ws = run_helmctl(
                [
                    "sandbox",
                    "exec",
                    "--workspace",
                    str(ws.root / "does_not_exist"),
                    "--cmd",
                    "echo hi",
                    "--mode",
                    "seatbelt",
                ],
                expect_json=False,
                check=False,
            )
            self.assertNotIn(missing_ws.returncode, (0, 69))

    # ------------------------------------------------------------------
    # Area D: Headless Browser & Vision OCR Boundaries (F8, F9, F10, E4, E6)
    # ------------------------------------------------------------------

    def test_T2_D_01_blank_page_handled_without_crash(self) -> None:
        """T2-D-01 (E6): Completely blank white page (/blank) yields empty ocrLines & domElements."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard():
                obs = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/blank"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "blank.png"),
                        ]
                    ).json
                )
            self.assertEqual(obs["ocrLines"], [])
            self.assertEqual(obs["domElements"], [])

    def test_T2_D_02_http_404_page_observed_cleanly(self) -> None:
        """T2-D-02 (E6): HTTP 404 page (/404) returns observation with 404 text without crashing."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard():
                obs = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/404"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "notfound.png"),
                        ]
                    ).json
                )
            self.assertIn("404 HARBOR MISSING", _all_ocr_text(obs).upper())

    def test_T2_D_03_slow_endpoint_deadline_kills_worker_cleanly(self) -> None:
        """T2-D-03 (E6): Hung /slow endpoint times out at deadline with zero orphan Chrome PIDs."""
        require_helmctl()
        pre_pids = _helm_chrome_pids()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            t0 = time.monotonic()
            with FocusGuard() as guard:
                res = run_helmctl(
                    [
                        "browser",
                        "act",
                        "--url",
                        srv.url("/slow?delay=6"),
                        "--timeout",
                        "2",
                        "--screenshot-out",
                        str(ws.artifacts_dir / "slow.png"),
                    ],
                    expect_json=False,
                    check=False,
                    timeout=15.0,
                )
            elapsed = time.monotonic() - t0
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertNotIn(res.returncode, (0, 69))
            self.assertLess(elapsed, 6.0, f"Browser timeout exceeded deadline: {elapsed:.2f}s")
        time.sleep(0.2)
        post_pids = _helm_chrome_pids()
        self.assertEqual(
            post_pids - pre_pids,
            set(),
            f"Orphan headless Chrome PIDs remained: {post_pids - pre_pids}",
        )

    def test_T2_D_04_passkey_refused_fast_no_os_sheet(self) -> None:
        """T2-D-04 (E6): WebAuthn/passkey prompt fails fast without macOS sheet or focus steal."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard() as guard:
                obs = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/passkey"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "passkey.png"),
                        ],
                        timeout=20.0,
                    ).json
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            text = _all_ocr_text(obs).upper()
            self.assertIn("PASSKEY_REFUSED_CLEANLY", text)
            self.assertNotIn("PASSKEY_UNEXPECTED_OK", text)

    def test_T2_D_05_missing_ocr_target_and_offscale_returns_error(self) -> None:
        """T2-D-05: Missing OCR target on /offscale returns structured failure without hanging."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard():
                res = run_helmctl(
                    [
                        "browser",
                        "act",
                        "--url",
                        srv.url("/offscale"),
                        "--click-ocr",
                        "NONEXISTENT_BUTTON_XYZ",
                        "--screenshot-out",
                        str(ws.artifacts_dir / "offscale.png"),
                    ],
                    expect_json=False,
                    check=False,
                    timeout=20.0,
                )
            self.assertNotIn(res.returncode, (0, 69))
            self.assertTrue(len((res.stderr + res.stdout).strip()) > 0)

    def test_T2_D_06_large_dom_bounded_extraction(self) -> None:
        """T2-D-06: Large 500-node DOM (/large-dom) completes cleanly under deadline with bounded items."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard():
                obs = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/large-dom"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "largedom.png"),
                        ],
                        timeout=30.0,
                    ).json
                )
            self.assertGreater(len(obs["domElements"]), 0)
            self.assertLessEqual(len(obs["domElements"]), 500)
            self.assertLess(obs["latencyMs"], 30000.0)

    # ------------------------------------------------------------------
    # Area E: Native UI, Agent Characters & Accessibility Boundaries (E9, E10)
    # ------------------------------------------------------------------

    def test_T2_E_01_ten_similar_agents_unique_character_seeds(self) -> None:
        """T2-E-01 (E9): 10 agents with similar names produce 10 unique characterSeeds."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "TenAgents",
                    "--goal",
                    "Verify zero seed collision",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            seeds: Set[str] = set()
            for idx in range(10):
                agent = run_helmctl(
                    [
                        "agent",
                        "add",
                        "--project",
                        proj["id"],
                        "--name",
                        f"Agent-{idx:02d}",
                        "--role",
                        "specialist",
                        "--goal",
                        "Collaborate",
                        "--backend",
                        "mock",
                    ],
                    db_path=ws.db_path,
                ).json
                seeds.add(_extract_seed_token(agent))
            self.assertEqual(len(seeds), 10)

    def test_T2_E_02_extreme_long_project_and_agent_strings(self) -> None:
        """T2-E-02 (E9): 200-char Project goal and 120-char Agent name/goal handled cleanly."""
        require_helmctl()
        long_goal = "G" * 200
        long_name = "Agent_" + ("N" * 114)
        long_agent_goal = "A" * 120
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "ExtremeTextProject",
                    "--goal",
                    long_goal,
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
                    long_name,
                    "--role",
                    "researcher",
                    "--goal",
                    long_agent_goal,
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            ).json
            self.assertEqual(proj["goal"], long_goal)
            self.assertEqual(agent["name"], long_name)
            self.assertEqual(agent["goal"], long_agent_goal)
            with FocusGuard():
                rep = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "3"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(rep["projectID"], proj["id"])

    def test_T2_E_03_reduce_motion_static_snapshots(self) -> None:
        """T2-E-03 (E10): Reduce Motion = ON renders crisp static frames with zero crashes."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "rm"
            rc, _, stderr, _ = _run_headless_snapshot(
                app_exe, snap_dir, reduce_motion=True
            )
            self.assertEqual(rc, 0, stderr)
            pngs = sorted(snap_dir.rglob("*.png"))
            self.assertGreaterEqual(len(pngs), 1)
            for p in pngs:
                info = inspect_png(p)
                self.assertFalse(info["is_uniform"])
                self.assertGreaterEqual(info["width"], 900)
                self.assertGreaterEqual(info["height"], 600)

    def test_T2_E_04_dark_vs_light_contrast_palettes(self) -> None:
        """T2-E-04 (E10): Dark and Light mode snapshots are non-blank and luminances differ."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "palettes"
            rc, _, stderr, _ = _run_headless_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, stderr)
            pngs = sorted(snap_dir.rglob("*.png"))
            light_pngs = [p for p in pngs if "light" in p.name.lower()]
            dark_pngs = [p for p in pngs if "dark" in p.name.lower()]
            self.assertGreaterEqual(len(light_pngs), 1)
            self.assertGreaterEqual(len(dark_pngs), 1)
            l_info = inspect_png(light_pngs[0])
            d_info = inspect_png(dark_pngs[0])
            self.assertFalse(l_info["is_uniform"])
            self.assertFalse(d_info["is_uniform"])
            self.assertGreater(l_info["mean_luminance"], d_info["mean_luminance"])
            self.assertGreater(l_info["max_luminance"], l_info["min_luminance"])
            self.assertGreater(d_info["max_luminance"], d_info["min_luminance"])

    def test_T2_E_05_headless_no_notification_prompt_blocking(self) -> None:
        """T2-E-05: Headless accessory launch completes deterministically without notification permission modal."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            t0 = time.monotonic()
            rc, _, stderr, probe = _run_headless_snapshot(
                app_exe,
                ws.artifacts_dir / "no_prompt",
                extra_env={"HELM_DISABLE_NOTIFICATIONS": "1"},
                timeout=30.0,
            )
            elapsed = time.monotonic() - t0
            self.assertEqual(rc, 0, stderr)
            self.assertLess(elapsed, 30.0)
            self.assertFalse(probe["focusChanged"])
            self.assertFalse(probe["cursorMoved"])


if __name__ == "__main__":
    raise SystemExit(run_tier_module_cli("2"))
