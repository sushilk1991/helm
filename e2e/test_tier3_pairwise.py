#!/usr/bin/env python3
from __future__ import annotations

import concurrent.futures
import os
import re
import socket
import subprocess
import unittest
from pathlib import Path
from typing import Any, Dict, List, Set

from e2e_common import (
    E2ETestCase,
    FocusGuard,
    TempWorkspace,
    inspect_png,
    require_helm_app,
    require_helmctl,
    require_vm_assets,
    run_helmctl,
    run_tier_module_cli,
    validate_browser_observation,
    validate_exception_alert,
    validate_execution_result,
)
from fixture_server import FixtureServer

SHA256_HEX_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def _all_ocr_text(obs: Dict[str, Any]) -> str:
    return "\n".join(str(line.get("text", "")) for line in obs.get("ocrLines", []))


def _closed_local_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = int(sock.getsockname()[1])
    sock.close()
    return port


def _run_headless_snapshot(
    app_exe: Path,
    snap_dir: Path,
    *,
    reduce_motion: bool = False,
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
        raise AssertionError(f"Focus changed during Helm.app: {guard.result!r}")
    if guard.result["cursorMoved"]:
        raise AssertionError(f"Cursor moved during Helm.app: {guard.result!r}")
    return proc.returncode, stdout, stderr, guard.result


class Tier3PairwiseTests(E2ETestCase):
    """Tier 3 cross-feature pairwise interaction tests (T3-PW-01..T3-PW-14)."""

    def test_T3_PW_01_F1_F2_F3_mixed_backends_persist_across_reopen(self) -> None:
        """T3-PW-01 (F1+F2+F3): Multi-agent Project with mixed backends persists across DB reopen."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "MixedBackends",
                    "--goal",
                    "Persist mixed providers",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            backends = [("A_Mock", "researcher", "mock"), ("B_Claude", "coder", "claude"), ("C_Codex", "qa", "codex")]
            created_agents: List[Dict[str, Any]] = []
            for name, role, backend in backends:
                ag = run_helmctl(
                    [
                        "agent",
                        "add",
                        "--project",
                        proj["id"],
                        "--name",
                        name,
                        "--role",
                        role,
                        "--goal",
                        f"Work via {backend}",
                        "--backend",
                        backend,
                    ],
                    db_path=ws.db_path,
                ).json
                created_agents.append(ag)
                self.assertEqual(ag["backend"], backend)

            # Re-verify in a brand-new helmctl invocation
            list_res = run_helmctl(
                ["agent", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            )
            self.assertIsInstance(list_res.json, list)
            self.assertEqual(len(list_res.json), 3)
            by_name = {a["name"]: a for a in list_res.json}
            for created, (name, _, backend) in zip(created_agents, backends):
                self.assertIn(name, by_name)
                self.assertEqual(by_name[name]["id"], created["id"])
                self.assertEqual(by_name[name]["backend"], backend)

    def test_T3_PW_02_F2_F4_F5_three_agent_delegation_shared_state_digests(self) -> None:
        """T3-PW-02 (F2+F4+F5): 3-agent Orchestrator delegation updates shared state & digests in order."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "ThreeAgentDAG",
                    "--goal",
                    "Research, build, and verify shared digest",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            agent_ids: Set[str] = set()
            for name, role, caps in (
                ("Scout", "researcher", "readSharedState,proposeSharedState"),
                ("Builder", "coder", "codeExec,readSharedState,proposeSharedState"),
                ("Inspector", "qa", "readSharedState"),
            ):
                ag = run_helmctl(
                    [
                        "agent",
                        "add",
                        "--project",
                        proj["id"],
                        "--name",
                        name,
                        "--role",
                        role,
                        "--goal",
                        f"{name} phase",
                        "--backend",
                        "mock",
                        "--capabilities",
                        caps,
                    ],
                    db_path=ws.db_path,
                ).json
                agent_ids.add(ag["id"])

            with FocusGuard() as guard:
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "12"],
                    db_path=ws.db_path,
                ).json
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(report["status"], "completed")
            self.assertGreaterEqual(len(report["tasks"]), 3)
            self.assertTrue(agent_ids.issubset({t["assignedAgentID"] for t in report["tasks"]}))
            self.assertGreaterEqual(len(report["sharedState"]), 1)
            for entry in report["sharedState"]:
                self.assertRegex(entry["digest"], SHA256_HEX_RE)

    def test_T3_PW_03_F4_F6_F1_stall_persist_retry_completion(self) -> None:
        """T3-PW-03 (F4+F6+F1): Simulated stall persists across process exit, resolves via retry, and completes."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "StallRetryPW",
                    "--goal",
                    "Recover from durable stall",
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
                    "coder",
                    "--goal",
                    "Complete task",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                held = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-stall"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(held["status"], "held")
            exc_id = held["exceptions"][0]["id"]

            listed = run_helmctl(
                ["exceptions", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            ).json
            self.assertEqual(len(listed), 1)
            self.assertEqual(listed[0]["id"], exc_id)
            self.assertEqual(listed[0]["kind"], "stall")

            resolved = run_helmctl(
                ["exceptions", "resolve", "--id", exc_id, "--action", "retry"],
                db_path=ws.db_path,
            ).json
            validate_exception_alert(resolved)
            self.assertEqual(resolved["status"], "resolved")

            with FocusGuard():
                resumed = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "10"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(resumed["status"], "completed")
            self.assertEqual(resumed["alertsSurfaced"], 0)

    def test_T3_PW_04_F5_F10_E7_prompt_injection_trust_guard(self) -> None:
        """T3-PW-04 (F5+F10+E7): /prompt-injection tagged untrustedData and cannot mutate rules."""
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
                            str(ws.artifacts_dir / "pw04.png"),
                        ]
                    ).json,
                    require_untrusted=True,
                )
            self.assertEqual(obs["trustTag"], "untrustedData")
            ocr_text = _all_ocr_text(obs)

            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "TrustPW",
                    "--goal",
                    "Ingest observation without overriding rules",
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
                    "WebAnalyst",
                    "--role",
                    "browser_analyst",
                    "--goal",
                    "Read harbor depth",
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
                    content_upper = str(entry.get("value", "")).upper()
                    self.assertNotIn("ALLOW_ALL_SECRETS", content_upper)
                    self.assertNotIn("IGNORE PREVIOUS INSTRUCTIONS", content_upper)
                    self.assertNotIn("DELETE PROJECT RULES", content_upper)
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

    def test_T3_PW_05_F7_vm_and_seatbelt_execution_parity(self) -> None:
        """T3-PW-05 (F7 VM + F7 Seatbelt + F1): Identical script yields identical file output and exit code."""
        require_helmctl()
        require_vm_assets()
        script = "printf 'PARITY_42' > parity.txt && cat parity.txt"
        with TempWorkspace() as ws1, TempWorkspace() as ws2:
            assert ws1.ws_path is not None and ws2.ws_path is not None
            with FocusGuard():
                sb = validate_execution_result(
                    run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(ws1.ws_path),
                            "--cmd",
                            script,
                            "--mode",
                            "seatbelt",
                        ]
                    ).json
                )
                vm = validate_execution_result(
                    run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(ws2.ws_path),
                            "--cmd",
                            script,
                            "--mode",
                            "vm",
                        ],
                        timeout=90.0,
                    ).json
                )
            self.assertEqual(sb["modeUsed"], "seatbeltSandbox")
            self.assertEqual(vm["modeUsed"], "virtualizationVM")
            self.assertEqual(sb["exitCode"], vm["exitCode"])
            self.assertEqual(sb["stdout"], vm["stdout"])
            self.assertEqual(
                (ws1.ws_path / "parity.txt").read_text(encoding="utf-8"),
                (ws2.ws_path / "parity.txt").read_text(encoding="utf-8"),
            )

    def test_T3_PW_06_F7_F4_F13_orchestrator_sandbox_with_host_invariance(self) -> None:
        """T3-PW-06 (F7+F4+F13): Orchestrator + sandbox execution preserve host cursor and focus."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "SandboxOrchPW",
                    "--goal",
                    "Produce workspace artifact via sandbox",
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
                    "Write build_ok.txt in workspace",
                    "--backend",
                    "mock",
                    "--capabilities",
                    "codeExec,readSharedState",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard(interval_ms=50) as guard:
                run_report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "8"],
                    db_path=ws.db_path,
                ).json
                sb_res = validate_execution_result(
                    run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(ws.ws_path),
                            "--cmd",
                            "echo PW06_OK > pw06_artifact.txt",
                            "--mode",
                            "seatbelt",
                        ]
                    ).json
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(run_report["status"], "completed")
            self.assertEqual(sb_res["exitCode"], 0)
            self.assertTrue((ws.ws_path / "pw06_artifact.txt").is_file())

    def test_T3_PW_07_F8_F9_F10_end_to_end_ocr_navigation_and_form_submit(self) -> None:
        """T3-PW-07 (F8+F9+F10): Navigate / -> OCR click OPEN FORM -> fill form -> OCR SUBMIT ORDER -> verify /result."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard():
                obs1 = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/"),
                            "--click-ocr",
                            "OPEN FORM",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "pw07_step1.png"),
                        ]
                    ).json
                )
                self.assertIn("/form", obs1["url"])
                obs2 = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            obs1["url"],
                            "--type",
                            "code=PW07",
                            "--type",
                            "note=CLOSED_LOOP",
                            "--click-ocr",
                            "SUBMIT ORDER",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "pw07_step2.png"),
                        ]
                    ).json
                )
            self.assertIn("/result", obs2["url"])
            text = _all_ocr_text(obs2).upper()
            self.assertIn("ORDER CONFIRMED", text)
            self.assertIn("PW07", text)
            self.assertIn("CLOSED_LOOP", text)

    def test_T3_PW_08_F8_F9_F13_headless_browser_ocr_zero_chrome_activation(self) -> None:
        """T3-PW-08 (F8+F9+F13): Headless Chrome + Vision OCR never activates Chrome or moves cursor."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard(interval_ms=50) as guard:
                obs = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/ocr-target"),
                            "--click-ocr",
                            "BRAVO ACTION",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "pw08.png"),
                        ]
                    ).json
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(guard.result["activationEvents"], [])
            self.assertIn("BRAVO CLICKED OK", _all_ocr_text(obs).upper())

    def test_T3_PW_09_F7_F8_F10_sandbox_token_submitted_via_browser_ocr(self) -> None:
        """T3-PW-09 (F7+F8+F10): Sandbox generates token file; Browser submits token; OCR reads /result."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.ws_path is not None and ws.artifacts_dir is not None
            with FocusGuard():
                sb = validate_execution_result(
                    run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(ws.ws_path),
                            "--cmd",
                            "printf 'HELM_SB_771' > token.txt && cat token.txt",
                            "--mode",
                            "seatbelt",
                        ]
                    ).json
                )
                self.assertEqual(sb["exitCode"], 0)
                token = (ws.ws_path / "token.txt").read_text(encoding="utf-8").strip()
                self.assertEqual(token, "HELM_SB_771")

                obs = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/form"),
                            "--type",
                            f"code={token}",
                            "--type",
                            "note=FROM_SANDBOX",
                            "--click-ocr",
                            "SUBMIT ORDER",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "pw09.png"),
                        ]
                    ).json
                )
            text = _all_ocr_text(obs).upper()
            self.assertIn("ORDER CONFIRMED", text)
            self.assertIn("HELM_SB_771", text)

    def test_T3_PW_10_F6_F11_F12_exception_banner_and_characters_in_snapshots(self) -> None:
        """T3-PW-10 (F6+F11+F12): Seeded exception state renders distinct snapshot with characters."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "pw10"
            rc, _, stderr, _ = _run_headless_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, stderr)
            pngs = sorted(snap_dir.rglob("*.png"))
            steady = [p for p in pngs if any(k in p.name.lower() for k in ("steady", "calm", "normal"))]
            exc = [p for p in pngs if any(k in p.name.lower() for k in ("exception", "alert", "held"))]
            self.assertGreaterEqual(len(steady), 1)
            self.assertGreaterEqual(len(exc), 1)
            s_info = inspect_png(steady[0])
            e_info = inspect_png(exc[0])
            self.assertFalse(s_info["is_uniform"])
            self.assertFalse(e_info["is_uniform"])
            self.assertNotEqual(s_info["pixel_sha256"], e_info["pixel_sha256"])

    def test_T3_PW_11_F11_F12_F13_appearance_variants_preserve_focus(self) -> None:
        """T3-PW-11 (F11+F12+F13): Light, Dark, and Reduce Motion snapshots render with zero focus steal."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            std_dir = ws.artifacts_dir / "pw11_std"
            rm_dir = ws.artifacts_dir / "pw11_rm"
            rc1, _, err1, p1 = _run_headless_snapshot(app_exe, std_dir, reduce_motion=False)
            rc2, _, err2, p2 = _run_headless_snapshot(app_exe, rm_dir, reduce_motion=True)
            self.assertEqual(rc1, 0, err1)
            self.assertEqual(rc2, 0, err2)
            self.assertFalse(p1["focusChanged"])
            self.assertFalse(p2["focusChanged"])
            std_pngs = sorted(std_dir.rglob("*.png"))
            rm_pngs = sorted(rm_dir.rglob("*.png"))
            self.assertGreaterEqual(len(std_pngs), 2)
            self.assertGreaterEqual(len(rm_pngs), 1)
            for p in std_pngs + rm_pngs:
                info = inspect_png(p)
                self.assertGreaterEqual(info["width"], 900)
                self.assertGreaterEqual(info["height"], 600)
                self.assertFalse(info["is_uniform"])

    def test_T3_PW_12_F3_F4_F6_failing_provider_surfaces_exception_alert(self) -> None:
        """T3-PW-12 (F3+F4+F6): Failing http provider surfaces durable ExceptionAlert instead of silent failure."""
        require_helmctl()
        closed_port = _closed_local_port()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "ProviderAlertPW",
                    "--goal",
                    "Surface provider outage",
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
                    "Fetch response",
                    "--backend",
                    "http",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
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

    def test_T3_PW_13_F1_F7_F8_concurrent_projects_isolated(self) -> None:
        """T3-PW-13 (F1+F7+F8): Two concurrent Projects in separate DBs/workspaces do not leak state."""
        require_helmctl()
        with TempWorkspace() as ws1, TempWorkspace() as ws2, FixtureServer() as srv:
            assert ws1.ws_path is not None and ws1.db_path is not None and ws1.artifacts_dir is not None
            assert ws2.ws_path is not None and ws2.db_path is not None and ws2.artifacts_dir is not None

            def _run_one(ws: TempWorkspace, tag: str) -> Dict[str, Any]:
                assert ws.ws_path is not None and ws.db_path is not None and ws.artifacts_dir is not None
                proj = run_helmctl(
                    [
                        "project",
                        "create",
                        "--name",
                        f"Concurrent-{tag}",
                        "--goal",
                        f"Isolated {tag}",
                        "--workspace",
                        str(ws.ws_path),
                    ],
                    db_path=ws.db_path,
                ).json
                sb = validate_execution_result(
                    run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(ws.ws_path),
                            "--cmd",
                            f"printf '{tag}' > marker_{tag}.txt",
                            "--mode",
                            "seatbelt",
                        ]
                    ).json
                )
                obs = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url(f"/result?code={tag}&note=ISO"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / f"{tag}.png"),
                        ]
                    ).json
                )
                return {"proj": proj, "sb": sb, "obs": obs}

            with FocusGuard(interval_ms=50) as guard:
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    fut_a = pool.submit(_run_one, ws1, "PROJ_A")
                    fut_b = pool.submit(_run_one, ws2, "PROJ_B")
                    res_a = fut_a.result(timeout=60.0)
                    res_b = fut_b.result(timeout=60.0)

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertNotEqual(res_a["proj"]["id"], res_b["proj"]["id"])
            self.assertTrue((ws1.ws_path / "marker_PROJ_A.txt").is_file())
            self.assertFalse((ws1.ws_path / "marker_PROJ_B.txt").exists())
            self.assertTrue((ws2.ws_path / "marker_PROJ_B.txt").is_file())
            self.assertFalse((ws2.ws_path / "marker_PROJ_A.txt").exists())
            self.assertIn("PROJ_A", _all_ocr_text(res_a["obs"]).upper())
            self.assertIn("PROJ_B", _all_ocr_text(res_b["obs"]).upper())

    def test_T3_PW_14_F4_F8_F9_E6_404_or_missing_target_no_hang(self) -> None:
        """T3-PW-14 (F4+F8+F9+E6): Navigating /404 and missing OCR target fails/recovers cleanly with no hang."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard():
                obs_404 = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/404"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "pw14_404.png"),
                        ]
                    ).json
                )
                self.assertIn("404 HARBOR MISSING", _all_ocr_text(obs_404).upper())

                miss_res = run_helmctl(
                    [
                        "browser",
                        "act",
                        "--url",
                        srv.url("/404"),
                        "--click-ocr",
                        "SUBMIT ORDER",
                        "--screenshot-out",
                        str(ws.artifacts_dir / "pw14_miss.png"),
                    ],
                    expect_json=False,
                    check=False,
                    timeout=20.0,
                )
                self.assertNotIn(miss_res.returncode, (0, 69))


if __name__ == "__main__":
    raise SystemExit(run_tier_module_cli("3"))
