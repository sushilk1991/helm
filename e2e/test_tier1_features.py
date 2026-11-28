#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

from e2e_common import (
    E2ETestCase,
    FocusGuard,
    LocalLLMServer,
    REPO_ROOT,
    TempWorkspace,
    UnbuiltTargetSkip,
    find_helm_app_bundle,
    inspect_png,
    require_feature_field,
    require_helm_app,
    require_helmctl,
    require_vm_assets,
    run_helmctl,
    run_helmctl_feature,
    run_tier_module_cli,
    validate_agent_work_entry,
    validate_browser_observation,
    validate_chat_message,
    validate_exception_alert,
    validate_execution_result,
    validate_project_trust_policy,
)
from fixture_server import FixtureServer

SHA256_HEX_RE = re.compile(r"^[0-9a-fA-F]{64}$")


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
    raise AssertionError(f"Missing or empty characterSeed in agent payload: {agent_json!r}")


def _rect_xywh(rect: Any) -> Tuple[float, float, float, float]:
    if isinstance(rect, dict):
        if "origin" in rect and "size" in rect:
            return (
                float(rect["origin"]["x"]),
                float(rect["origin"]["y"]),
                float(rect["size"]["width"]),
                float(rect["size"]["height"]),
            )
        return (
            float(rect["x"]),
            float(rect["y"]),
            float(rect["width"]),
            float(rect["height"]),
        )
    if isinstance(rect, (list, tuple)) and len(rect) == 2:
        return (
            float(rect[0][0]),
            float(rect[0][1]),
            float(rect[1][0]),
            float(rect[1][1]),
        )
    raise AssertionError(f"Unexpected rect format: {rect!r}")


def _find_ocr_line(ocr_lines: List[Dict[str, Any]], needle: str) -> Optional[Dict[str, Any]]:
    needle_upper = needle.upper()
    for line in ocr_lines:
        if needle_upper in str(line.get("text", "")).upper():
            return line
    return None


def _all_ocr_text(obs: Dict[str, Any]) -> str:
    return "\n".join(str(line.get("text", "")) for line in obs.get("ocrLines", []))


def _listening_pids_on_port(port: int) -> Set[int]:
    proc = subprocess.run(
        ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
        capture_output=True,
        text=True,
        timeout=5.0,
    )
    pids: Set[int] = set()
    for tok in proc.stdout.split():
        tok = tok.strip()
        if tok.isdigit():
            pids.add(int(tok))
    return pids


def _run_headless_app_snapshot(
    app_exe: Path,
    snapshot_dir: Path,
    *,
    reduce_motion: bool = False,
    timeout: float = 45.0,
) -> Tuple[int, str, str, Dict[str, Any]]:
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(app_exe),
        "--headless",
        "--seed-demo",
        "--snapshot-dir",
        str(snapshot_dir),
    ]
    if reduce_motion:
        cmd.append("--reduce-motion")

    env = os.environ.copy()
    env["HELM_NO_ACTIVATE"] = "1"
    env.pop("HELM_SNAPSHOT_SETTINGS", None)
    env.pop("HELM_SNAPSHOT_EXTRA", None)
    if reduce_motion:
        env["HELM_REDUCE_MOTION"] = "1"
    else:
        env.pop("HELM_REDUCE_MOTION", None)

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
            raise AssertionError(
                f"Helm.app --headless timed out after {timeout}s"
            ) from exc

    assert guard.result is not None
    if guard.result["focusChanged"]:
        raise AssertionError(f"Helm.app stole focus: {guard.result!r}")
    if guard.result["cursorMoved"]:
        raise AssertionError(f"Helm.app moved cursor: {guard.result!r}")
    return proc.returncode, stdout, stderr, guard.result


def _create_project_and_agent(
    ws: TempWorkspace,
    *,
    project_name: str = "TestProject",
    project_goal: str = "Complete autonomous verification",
    agent_name: str = "Worker",
    role: str = "researcher",
    goal: str = "Execute delegated step",
    backend: str = "mock",
    capabilities: str = "readSharedState,proposeSharedState",
) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    assert ws.ws_path is not None and ws.db_path is not None
    proj = run_helmctl(
        [
            "project",
            "create",
            "--name",
            project_name,
            "--goal",
            project_goal,
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
            agent_name,
            "--role",
            role,
            "--goal",
            goal,
            "--backend",
            backend,
            "--capabilities",
            capabilities,
        ],
        db_path=ws.db_path,
    ).json
    return proj, agent


class Tier1FeatureTests(E2ETestCase):
    """Tier 1 isolated happy-path feature coverage (T1-F1-01..T1-F13-05)."""

    # ------------------------------------------------------------------
    # F1 — Project Lifecycle & Workspace Store
    # ------------------------------------------------------------------

    def test_T1_F1_01_create_project_valid(self) -> None:
        """T1-F1-01: Create a new Project with valid name, goal, workspace, and SQLite DB."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            res = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "Alpha",
                    "--goal",
                    "Ship MVP",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            )
            self.assertEqual(res.returncode, 0)
            proj = res.json
            self.assertIsInstance(proj, dict)
            self.assertTrue(isinstance(proj.get("id"), str) and len(proj["id"]) > 0)
            self.assertEqual(proj.get("name"), "Alpha")
            self.assertEqual(proj.get("goal"), "Ship MVP")
            self.assertIn("status", proj)
            self.assertIn("createdAt", proj)
            self.assertTrue(ws.db_path.is_file())

    def test_T1_F1_02_multiple_independent_projects_same_db(self) -> None:
        """T1-F1-02: Create multiple independent Projects in the same SQLite DB."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.root is not None and ws.db_path is not None
            ws_a = ws.root / "ws_alpha"
            ws_b = ws.root / "ws_beta"
            ws_a.mkdir()
            ws_b.mkdir()
            p1 = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "Alpha",
                    "--goal",
                    "Goal A",
                    "--workspace",
                    str(ws_a),
                ],
                db_path=ws.db_path,
            ).json
            p2 = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "Beta",
                    "--goal",
                    "Goal B",
                    "--workspace",
                    str(ws_b),
                ],
                db_path=ws.db_path,
            ).json
            self.assertNotEqual(p1["id"], p2["id"])
            self.assertEqual(p1["name"], "Alpha")
            self.assertEqual(p2["name"], "Beta")
            self.assertTrue(ws_a.is_dir() and ws_b.is_dir())

    def test_T1_F1_03_project_persists_across_process_boundary(self) -> None:
        """T1-F1-03: Project persists across fresh helmctl process invocation (WAL durability)."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj, _ = _create_project_and_agent(
                ws, project_name="DurableProj", project_goal="Persist across restart"
            )
            with FocusGuard() as guard:
                run_res = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "1"],
                    db_path=ws.db_path,
                )
            self.assertIsNotNone(guard.result)
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(run_res.returncode, 0)
            self.assertEqual(run_res.json.get("projectID"), proj["id"])

    def test_T1_F1_04_project_workspace_auto_created_and_writable(self) -> None:
        """T1-F1-04: Project workspace subdirectory is auto-created and writable."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.root is not None and ws.db_path is not None
            nested_ws = ws.root / "nested" / "new_subdir"
            self.assertFalse(nested_ws.exists())
            res = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "AutoDir",
                    "--goal",
                    "Create workspace dir",
                    "--workspace",
                    str(nested_ws),
                ],
                db_path=ws.db_path,
            )
            self.assertEqual(res.returncode, 0)
            self.assertTrue(nested_ws.is_dir())
            self.assertTrue(os.access(nested_ws, os.W_OK))

    def test_T1_F1_05_project_multiline_unicode_goal_persists(self) -> None:
        """T1-F1-05: Multiline and Unicode Project name/goal preserved across restart."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            goal_text = "Line1\nLine2 — verify UTF-8 ⚓"
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "Harbor-α",
                    "--goal",
                    goal_text,
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            self.assertEqual(proj.get("name"), "Harbor-α")
            self.assertEqual(proj.get("goal"), goal_text)
            # Re-verify via fresh process (`project show` if available, else `run`)
            show_res = run_helmctl(
                ["project", "show", "--id", proj["id"]],
                db_path=ws.db_path,
                check=False,
            )
            if show_res.returncode == 0 and isinstance(show_res.json, dict):
                self.assertEqual(show_res.json.get("name"), "Harbor-α")
                self.assertEqual(show_res.json.get("goal"), goal_text)
            else:
                with FocusGuard():
                    run_res = run_helmctl(
                        ["run", "--project", proj["id"], "--max-steps", "0"],
                        db_path=ws.db_path,
                    )
                self.assertEqual(run_res.json.get("projectID"), proj["id"])

    # ------------------------------------------------------------------
    # F2 — Specialized Agent Creation & Distinct Goals
    # ------------------------------------------------------------------

    def test_T1_F2_01_add_researcher_agent(self) -> None:
        """T1-F2-01: Add specialized Researcher agent to Project."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "F2Proj",
                    "--goal",
                    "Research",
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
                    "Scout",
                    "--role",
                    "researcher",
                    "--goal",
                    "Gather docs",
                    "--backend",
                    "mock",
                    "--capabilities",
                    "browser,ocr,readSharedState",
                ],
                db_path=ws.db_path,
            ).json
            self.assertEqual(agent.get("projectID"), proj["id"])
            self.assertEqual(agent.get("name"), "Scout")
            self.assertEqual(agent.get("role"), "researcher")
            self.assertEqual(agent.get("goal"), "Gather docs")
            self.assertTrue(len(_extract_seed_token(agent)) > 0)

    def test_T1_F2_02_add_second_coder_agent_distinct_seed(self) -> None:
        """T1-F2-02: Add second Coder agent with distinct goal, ID, and characterSeed."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj, scout = _create_project_and_agent(
                ws,
                agent_name="Scout",
                role="researcher",
                goal="Gather docs",
                capabilities="browser,ocr,readSharedState",
            )
            builder = run_helmctl(
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
                    "Write and test script",
                    "--backend",
                    "mock",
                    "--capabilities",
                    "codeExec,readSharedState",
                ],
                db_path=ws.db_path,
            ).json
            self.assertNotEqual(scout["id"], builder["id"])
            self.assertNotEqual(_extract_seed_token(scout), _extract_seed_token(builder))
            self.assertEqual(builder.get("role"), "coder")

    def test_T1_F2_03_add_three_collaborating_agents(self) -> None:
        """T1-F2-03: Register >= 3 collaborating specialized agents on one Project."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj, a1 = _create_project_and_agent(
                ws, agent_name="Scout", role="researcher", goal="Gather docs"
            )
            a2 = run_helmctl(
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
                    "Build solution",
                    "--backend",
                    "mock",
                    "--capabilities",
                    "codeExec,readSharedState",
                ],
                db_path=ws.db_path,
            ).json
            a3 = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "Inspector",
                    "--role",
                    "qa",
                    "--goal",
                    "Verify form result",
                    "--backend",
                    "mock",
                    "--capabilities",
                    "browser,ocr",
                ],
                db_path=ws.db_path,
            ).json
            ids = {a1["id"], a2["id"], a3["id"]}
            self.assertEqual(len(ids), 3)

    def test_T1_F2_04_agent_seed_determinism_across_restart(self) -> None:
        """T1-F2-04: Agent characterSeed remains deterministic across process boundary."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj, scout = _create_project_and_agent(
                ws, agent_name="Scout", role="researcher", goal="Gather docs"
            )
            seed1 = _extract_seed_token(scout)
            list_res = run_helmctl(
                ["agent", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            )
            self.assertIsInstance(list_res.json, list)
            matches = [a for a in list_res.json if a.get("id") == scout["id"]]
            self.assertEqual(len(matches), 1)
            self.assertEqual(_extract_seed_token(matches[0]), seed1)
            self.assertEqual(matches[0].get("characterSeed"), scout.get("characterSeed"))

    def test_T1_F2_05_agent_capabilities_preserved(self) -> None:
        """T1-F2-05: Agent capabilities subset is preserved accurately in JSON output."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj, coder = _create_project_and_agent(
                ws,
                agent_name="CodeOnly",
                role="coder",
                goal="Run isolated script",
                capabilities="codeExec",
            )
            browser_agent = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "WebOnly",
                    "--role",
                    "qa",
                    "--goal",
                    "Inspect pages",
                    "--backend",
                    "mock",
                    "--capabilities",
                    "browser,ocr",
                ],
                db_path=ws.db_path,
            ).json
            self.assertEqual(set(coder.get("capabilities", [])), {"codeExec"})
            self.assertEqual(set(browser_agent.get("capabilities", [])), {"browser", "ocr"})

    # ------------------------------------------------------------------
    # F3 — Pluggable LLM Backend Provider Seam
    # ------------------------------------------------------------------

    def test_T1_F3_01_mock_provider_completes_plan(self) -> None:
        """T1-F3-01: MockLLMProvider executes deterministic multi-turn plan to completion."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, backend="mock")
            with FocusGuard() as guard:
                run_res = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "5"],
                    db_path=ws.db_path,
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            report = run_res.json
            self.assertEqual(report["status"], "completed")
            self.assertGreaterEqual(report["stepsExecuted"], 1)

    def test_T1_F3_02_mixed_backends_registration(self) -> None:
        """T1-F3-02: Mixed backends (claude and codex) accepted on same Project."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj, a_claude = _create_project_and_agent(
                ws, agent_name="ClaudeWorker", role="researcher", backend="claude"
            )
            a_codex = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "CodexWorker",
                    "--role",
                    "coder",
                    "--goal",
                    "Write code",
                    "--backend",
                    "codex",
                ],
                db_path=ws.db_path,
            ).json
            self.assertEqual(a_claude.get("backend"), "claude")
            self.assertEqual(a_codex.get("backend"), "codex")

    def test_T1_F3_03_http_and_foundation_backend_registration(self) -> None:
        """T1-F3-03: DirectHTTP (http) and FoundationModels (foundation) registration seam."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj, a_http = _create_project_and_agent(
                ws, agent_name="HTTPWorker", role="researcher", backend="http"
            )
            a_found = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "FoundationWorker",
                    "--role",
                    "specialist",
                    "--goal",
                    "Summarize locally",
                    "--backend",
                    "foundation",
                ],
                db_path=ws.db_path,
            ).json
            self.assertEqual(a_http.get("backend"), "http")
            self.assertEqual(a_found.get("backend"), "foundation")

    def test_T1_F3_04_max_steps_bound_respected(self) -> None:
        """T1-F3-04: Provider turn accounting respects --max-steps bound."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="A1", backend="mock")
            run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "A2",
                    "--role",
                    "coder",
                    "--goal",
                    "Step 2",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "3"],
                    db_path=ws.db_path,
                ).json
            self.assertLessEqual(report["stepsExecuted"], 3)
            self.assertIn(report["status"], {"completed", "maxStepsReached"})

    def test_T1_F3_05_live_llm_cli_smoke(self) -> None:
        """T1-F3-05: Live headless CLI provider smoke (gated by HELM_LIVE_LLM=1)."""
        require_helmctl()
        if os.environ.get("HELM_LIVE_LLM") != "1":
            raise unittest.SkipTest("HELM_LIVE_LLM=1 not enabled for live CLI provider smoke")

        backend = "claude" if shutil.which("claude") else ("codex" if shutil.which("codex") else None)
        if backend is None:
            raise unittest.SkipTest("Neither claude nor codex CLI found on PATH")

        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(
                ws,
                project_goal="Reply with one short confirmation line",
                agent_name="LiveAgent",
                role="researcher",
                goal="Emit a concise single-step summary",
                backend=backend,
            )
            with FocusGuard() as guard:
                res = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "2"],
                    db_path=ws.db_path,
                    timeout=90.0,
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(res.returncode, 0)
            self.assertGreaterEqual(res.json["stepsExecuted"], 1)

    # ------------------------------------------------------------------
    # F4 — Exception-Only Orchestrator Agent
    # ------------------------------------------------------------------

    def test_T1_F4_01_orchestrator_delegates_to_multiple_agents(self) -> None:
        """T1-F4-01: Orchestrator decomposes goal and delegates asynchronously to >=2 agents."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, a1 = _create_project_and_agent(
                ws, agent_name="Scout", role="researcher", goal="Research target"
            )
            a2 = run_helmctl(
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
                    "Implement output",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            ).json
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "10"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(report["status"], "completed")
            self.assertGreaterEqual(len(report["tasks"]), 2)
            assigned = {t["assignedAgentID"] for t in report["tasks"]}
            self.assertIn(a1["id"], assigned)
            self.assertIn(a2["id"], assigned)

    def test_T1_F4_02_silent_steady_ok_heartbeat_no_alerts(self) -> None:
        """T1-F4-02: Healthy run emits STEADY_OK heartbeats with zero alerts or notifications."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
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
                    "Compute",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "10"],
                    db_path=ws.db_path,
                ).json
            self.assertGreaterEqual(report["steadyHeartbeats"], 1)
            self.assertEqual(report["alertsSurfaced"], 0)
            self.assertEqual(report["notificationsEmitted"], 0)
            self.assertEqual(report["exceptions"], [])

    def test_T1_F4_03_orchestrator_self_corrects_transient_fault(self) -> None:
        """T1-F4-03: Orchestrator self-corrects minor transient mock failure without alerting human."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(
                ws,
                project_goal="Self-correct transient retry step and complete",
                agent_name="ResilientWorker",
                role="coder",
                goal="Handle transient retryable step without escalation",
                backend="mock",
            )
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "10"],
                    db_path=ws.db_path,
                    env={"HELM_MOCK_TRANSIENT_FAIL_ONCE": "1"},
                ).json
            self.assertEqual(report["status"], "completed")
            self.assertEqual(report["alertsSurfaced"], 0)
            self.assertEqual(report["exceptions"], [])
            tasks = report.get("tasks", [])
            self.assertGreaterEqual(len(tasks), 1)
            explicit_retries = int(
                report.get("selfCorrections", report.get("selfCorrectedEvents", 0))
            )
            self.assertTrue(
                explicit_retries >= 1 or int(report["stepsExecuted"]) >= len(tasks) + 1,
                "Expected observable transient retry / self-correction evidence "
                f"(stepsExecuted={report.get('stepsExecuted')}, tasks={len(tasks)}, "
                f"selfCorrections={explicit_retries}). "
                "Verify HELM_MOCK_TRANSIENT_FAIL_ONCE=1 triggers a retryable fault.",
            )

    def test_T1_F4_04_simulate_stall_surfaces_stall_exception(self) -> None:
        """T1-F4-04: Orchestrator surfaces stall exception when --simulate-stall invoked."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws)
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-stall"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(report["status"], "held")
            self.assertEqual(len(report["exceptions"]), 1)
            exc = validate_exception_alert(report["exceptions"][0])
            self.assertEqual(exc["kind"], "stall")

    def test_T1_F4_05_simulate_drift_surfaces_drift_exception(self) -> None:
        """T1-F4-05: Orchestrator surfaces drift exception when --simulate-drift invoked."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws)
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-drift"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(report["status"], "held")
            self.assertEqual(len(report["exceptions"]), 1)
            exc = validate_exception_alert(report["exceptions"][0])
            self.assertEqual(exc["kind"], "drift")

    # ------------------------------------------------------------------
    # F5 — Shared State & Trust-Verified Memory
    # ------------------------------------------------------------------

    def test_T1_F5_01_shared_state_written_with_sha256_digest(self) -> None:
        """T1-F5-01: Multi-agent run writes sharedState entries with 64-hex SHA-256 digests."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(
                ws, agent_name="Scout", role="researcher", capabilities="readSharedState,proposeSharedState"
            )
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
                    "Consume shared findings",
                    "--backend",
                    "mock",
                    "--capabilities",
                    "codeExec,readSharedState",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "10"],
                    db_path=ws.db_path,
                ).json
            shared = report.get("sharedState", [])
            self.assertGreaterEqual(len(shared), 1)
            for entry in shared:
                self.assertRegex(str(entry.get("digest", "")), SHA256_HEX_RE)

    def test_T1_F5_02_shared_state_digest_stable_when_unchanged(self) -> None:
        """T1-F5-02: Unchanged shared-state entry retains identical SHA-256 digest across runs."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
            with FocusGuard():
                r1 = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "5"],
                    db_path=ws.db_path,
                ).json
            with FocusGuard():
                r2 = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "1"],
                    db_path=ws.db_path,
                ).json
            map1 = {e["key"]: e["digest"] for e in r1["sharedState"]}
            map2 = {e["key"]: e["digest"] for e in r2["sharedState"]}
            common_keys = set(map1.keys()) & set(map2.keys())
            self.assertGreater(len(common_keys), 0)
            for k in common_keys:
                if (
                    next(e["value"] for e in r1["sharedState"] if e["key"] == k)
                    == next(e["value"] for e in r2["sharedState"] if e["key"] == k)
                ):
                    self.assertEqual(map1[k], map2[k])

    def test_T1_F5_03_shared_state_digest_mutates_on_update(self) -> None:
        """T1-F5-03: Shared-state update mutates SHA-256 digest deterministically."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
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
                    "Continue after decision redirect",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                r1 = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "1"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(r1["status"], "maxStepsReached")
            self.assertGreaterEqual(len(r1["sharedState"]), 1)
            for entry in r1["sharedState"]:
                self.assertRegex(entry["digest"], SHA256_HEX_RE)

            with FocusGuard():
                r2 = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-decision"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(r2["status"], "held")
            self.assertGreaterEqual(len(r2["exceptions"]), 1)
            exc_id = r2["exceptions"][0]["id"]
            run_helmctl(
                [
                    "exceptions",
                    "resolve",
                    "--id",
                    exc_id,
                    "--action",
                    "redirect",
                    "--note",
                    "Updated shared directive v2",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                r3 = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "5"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(r3["status"], "completed")
            self.assertGreater(len(r3["sharedState"]), len(r1["sharedState"]))
            digests_before = {(e["key"], e["value"]): e["digest"] for e in r1["sharedState"]}
            digests_after = {(e["key"], e["value"]): e["digest"] for e in r3["sharedState"]}
            self.assertNotEqual(digests_before, digests_after)
            redirect_entries = [
                e for e in r3["sharedState"] if e.get("value") == "Updated shared directive v2"
            ]
            self.assertEqual(len(redirect_entries), 1)
            self.assertNotIn(
                redirect_entries[0]["digest"],
                {e["digest"] for e in r1["sharedState"]},
            )
            for entry in r3["sharedState"]:
                self.assertRegex(entry["digest"], SHA256_HEX_RE)
            state_listed = run_helmctl(
                ["state", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            ).json
            self.assertEqual(
                {e["digest"] for e in state_listed},
                {e["digest"] for e in r3["sharedState"]},
            )

    def test_T1_F5_04_task_dependency_dag_order(self) -> None:
        """T1-F5-04: Task dependency DAG (waitingOn) resolves downstream after upstream."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
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
                    "Build after research",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "10"],
                    db_path=ws.db_path,
                ).json
            tasks = report["tasks"]
            self.assertGreaterEqual(len(tasks), 2)
            by_id = {t["id"]: t for t in tasks}
            has_dep = any(len(t.get("waitingOn", [])) > 0 for t in tasks)
            self.assertTrue(has_dep, f"Expected at least one task with waitingOn DAG dependency: {tasks!r}")
            for t in tasks:
                self.assertIn(t["status"], {"done", "completed"})
                for dep_id in t.get("waitingOn", []):
                    self.assertIn(dep_id, by_id)
                    self.assertIn(by_id[dep_id]["status"], {"done", "completed"})

    def test_T1_F5_05_shared_state_provenance_trust_level(self) -> None:
        """T1-F5-05: Shared-state provenance tracks trusted levels cleanly (never untrustedData for rules)."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
            with FocusGuard():
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "8"],
                    db_path=ws.db_path,
                ).json
            trusted_levels = {"humanAuthoritative", "orchestratorVerified", "agentGenerated", "trusted", "system", "orchestrator"}
            self.assertGreaterEqual(len(report["sharedState"]), 1)
            for entry in report["sharedState"]:
                self.assertIn(entry["trustLevel"], trusted_levels)
                self.assertNotEqual(entry["trustLevel"], "untrustedData")

    # ------------------------------------------------------------------
    # F6 — Exception Alerting & Human Resolution Flow
    # ------------------------------------------------------------------

    def test_T1_F6_01_simulate_decision_lists_pending_exception(self) -> None:
        """T1-F6-01: Durable ExceptionAlert created on --simulate-decision and listed via CLI."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws)
            with FocusGuard():
                run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-decision"],
                    db_path=ws.db_path,
                )
            listed = run_helmctl(
                ["exceptions", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            ).json
            self.assertIsInstance(listed, list)
            self.assertGreaterEqual(len(listed), 1)
            exc = validate_exception_alert(listed[0])
            self.assertEqual(exc["kind"], "humanDecision")
            self.assertIn(exc["status"], {"open", "pending"})

    def test_T1_F6_02_resolve_exception_approve(self) -> None:
        """T1-F6-02: Resolve exception with --action approve."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws)
            with FocusGuard():
                run_report = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-decision"],
                    db_path=ws.db_path,
                ).json
            exc_id = run_report["exceptions"][0]["id"]
            resolved = run_helmctl(
                ["exceptions", "resolve", "--id", exc_id, "--action", "approve"],
                db_path=ws.db_path,
            ).json
            validate_exception_alert(resolved)
            self.assertEqual(resolved["status"], "resolved")
            self.assertEqual(resolved["resolution"]["action"], "approve")
            listed = run_helmctl(
                ["exceptions", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            ).json
            open_items = [e for e in listed if e["status"] in {"open", "pending"}]
            self.assertEqual(open_items, [])

    def test_T1_F6_03_resolve_exception_redirect_with_note(self) -> None:
        """T1-F6-03: Resolve exception with --action redirect --note."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws)
            with FocusGuard():
                run_report = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-drift"],
                    db_path=ws.db_path,
                ).json
            exc_id = run_report["exceptions"][0]["id"]
            resolved = run_helmctl(
                [
                    "exceptions",
                    "resolve",
                    "--id",
                    exc_id,
                    "--action",
                    "redirect",
                    "--note",
                    "Use strategy B",
                ],
                db_path=ws.db_path,
            ).json
            validate_exception_alert(resolved)
            self.assertEqual(resolved["status"], "resolved")
            self.assertEqual(resolved["resolution"]["action"], "redirect")
            self.assertEqual(resolved["resolution"].get("note"), "Use strategy B")

    def test_T1_F6_04_resolve_exception_retry(self) -> None:
        """T1-F6-04: Resolve exception with --action retry."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws)
            with FocusGuard():
                run_report = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-stall"],
                    db_path=ws.db_path,
                ).json
            exc_id = run_report["exceptions"][0]["id"]
            resolved = run_helmctl(
                ["exceptions", "resolve", "--id", exc_id, "--action", "retry"],
                db_path=ws.db_path,
            ).json
            validate_exception_alert(resolved)
            self.assertEqual(resolved["status"], "resolved")
            self.assertEqual(resolved["resolution"]["action"], "retry")

    def test_T1_F6_05_resolve_exception_abort(self) -> None:
        """T1-F6-05: Resolve exception with --action abort."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws)
            with FocusGuard():
                run_report = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-decision"],
                    db_path=ws.db_path,
                ).json
            exc_id = run_report["exceptions"][0]["id"]
            resolved = run_helmctl(
                ["exceptions", "resolve", "--id", exc_id, "--action", "abort"],
                db_path=ws.db_path,
            ).json
            validate_exception_alert(resolved)
            self.assertEqual(resolved["status"], "resolved")
            self.assertEqual(resolved["resolution"]["action"], "abort")

    # ------------------------------------------------------------------
    # F7 — Headless Isolated Code Execution Sandbox/VM
    # ------------------------------------------------------------------

    def test_T1_F7_01_seatbelt_exec_echo_and_uname(self) -> None:
        """T1-F7-01: Execute echo/uname command in Seatbelt sandbox lane (--mode seatbelt)."""
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
                        "/bin/echo HELM_SB_OK && uname -m",
                        "--mode",
                        "seatbelt",
                    ]
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            payload = validate_execution_result(res.json)
            self.assertEqual(payload["modeUsed"], "seatbeltSandbox")
            self.assertEqual(payload["exitCode"], 0)
            self.assertFalse(payload["timedOut"])
            self.assertIn("HELM_SB_OK", payload["stdout"])

    def test_T1_F7_02_seatbelt_workspace_file_rw(self) -> None:
        """T1-F7-02: Create and read workspace file inside Seatbelt sandbox."""
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
                        "printf 'v1' > artifact.txt && cat artifact.txt",
                        "--mode",
                        "seatbelt",
                    ]
                )
            payload = validate_execution_result(res.json)
            self.assertEqual(payload["exitCode"], 0)
            self.assertEqual(payload["stdout"], "v1")
            artifact = ws.ws_path / "artifact.txt"
            self.assertTrue(artifact.is_file())
            self.assertEqual(artifact.read_text(encoding="utf-8"), "v1")

    def test_T1_F7_03_vm_exec_linux_uname(self) -> None:
        """T1-F7-03: Execute command in Alpine ARM64 Virtualization.framework VM (--mode vm)."""
        require_helmctl()
        require_vm_assets()
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
                        "uname -s && echo VM_OK",
                        "--mode",
                        "vm",
                    ],
                    timeout=90.0,
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            payload = validate_execution_result(res.json)
            self.assertEqual(payload["modeUsed"], "virtualizationVM")
            self.assertEqual(payload["exitCode"], 0)
            self.assertIn("Linux", payload["stdout"])
            self.assertIn("VM_OK", payload["stdout"])

    def test_T1_F7_04_vm_virtiofs_workspace_mount_parity(self) -> None:
        """T1-F7-04: virtiofs workspace mount parity in VM lane (--mode vm)."""
        require_helmctl()
        require_vm_assets()
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
                        "echo vm_art > vm_out.txt",
                        "--mode",
                        "vm",
                    ],
                    timeout=90.0,
                )
            payload = validate_execution_result(res.json)
            self.assertEqual(payload["modeUsed"], "virtualizationVM")
            self.assertEqual(payload["exitCode"], 0)
            out_file = ws.ws_path / "vm_out.txt"
            self.assertTrue(out_file.is_file())
            self.assertEqual(out_file.read_text(encoding="utf-8").strip(), "vm_art")

    def test_T1_F7_05_sandbox_propagates_nonzero_exit_code(self) -> None:
        """T1-F7-05: Non-zero command exit code propagated accurately without crashing runner."""
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
                        "exit 42",
                        "--mode",
                        "seatbelt",
                    ]
                )
            self.assertEqual(res.returncode, 0)
            payload = validate_execution_result(res.json)
            self.assertEqual(payload["exitCode"], 42)
            self.assertFalse(payload["timedOut"])

    # ------------------------------------------------------------------
    # F8 — Lightweight Headless Browser Engine
    # ------------------------------------------------------------------

    def test_T1_F8_01_browser_navigate_and_screenshot(self) -> None:
        """T1-F8-01: Navigate headless browser to GET / and capture valid screenshot."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            shot = ws.artifacts_dir / "home.png"
            with FocusGuard() as guard:
                res = run_helmctl(
                    [
                        "browser",
                        "act",
                        "--url",
                        srv.url("/"),
                        "--screenshot-out",
                        str(shot),
                    ]
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            obs = validate_browser_observation(res.json)
            self.assertTrue(obs["url"].rstrip("/").endswith(f":{srv.port}"))
            self.assertTrue(len(obs["title"].strip()) > 0)
            info = inspect_png(shot)
            self.assertGreater(info["file_bytes"], 1024)
            self.assertFalse(info["is_uniform"])

    def test_T1_F8_02_dom_interactive_elements_extracted(self) -> None:
        """T1-F8-02: DOM interactive elements extracted with positive bounding rects on /form."""
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
                            srv.url("/form"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "form.png"),
                        ]
                    ).json
                )
            elem_ids = {el.get("elementID") for el in obs["domElements"]}
            for required_id in ("code", "note", "submit-btn"):
                self.assertIn(required_id, elem_ids)
                matching = [el for el in obs["domElements"] if el.get("elementID") == required_id][0]
                _, _, w, h = _rect_xywh(matching["cssRect"])
                self.assertGreater(w, 0.0)
                self.assertGreater(h, 0.0)

    def test_T1_F8_03_ephemeral_per_session_isolation(self) -> None:
        """T1-F8-03: Ephemeral per-session browser isolation does not leak localStorage."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard():
                run_helmctl(
                    [
                        "browser",
                        "act",
                        "--url",
                        srv.url("/"),
                        "--eval-js",
                        "localStorage.setItem('helm_iso_k','v1'); document.title='SET_OK';",
                        "--screenshot-out",
                        str(ws.artifacts_dir / "s1.png"),
                    ]
                )
            with FocusGuard():
                obs2 = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/"),
                            "--eval-js",
                            "document.title = String(localStorage.getItem('helm_iso_k'));",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "s2.png"),
                        ]
                    ).json
                )
            self.assertEqual(obs2["title"], "null")

    def test_T1_F8_04_ephemeral_cdp_port_never_touches_9222(self) -> None:
        """T1-F8-04: Headless browser never spawns a listener on port 9222 or activates Chrome."""
        require_helmctl()
        pre_9222 = _listening_pids_on_port(9222)
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard() as guard:
                obs = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "cdp.png"),
                        ]
                    ).json
                )
            post_9222 = _listening_pids_on_port(9222)
            self.assertEqual(
                post_9222,
                pre_9222,
                f"Port 9222 listener PIDs changed: pre={pre_9222}, post={post_9222}",
            )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(guard.result.get("activationEvents", []), [])
            self.assertGreater(obs["latencyMs"], 0.0)

    def test_T1_F8_05_navigate_and_click_css_coordinates(self) -> None:
        """T1-F8-05: Navigate to /ocr-target and click CSS coordinates under budget."""
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
                            srv.url("/ocr-target"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "pre.png"),
                        ]
                    ).json
                )
            bravo_line = _find_ocr_line(obs1["ocrLines"], "BRAVO ACTION")
            self.assertIsNotNone(bravo_line, f"BRAVO ACTION not found in {obs1['ocrLines']!r}")
            assert bravo_line is not None
            bx, by, bw, bh = _rect_xywh(bravo_line["cssRect"])
            cx, cy = bx + bw / 2.0, by + bh / 2.0

            with FocusGuard():
                obs2 = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/ocr-target"),
                            "--click-css",
                            f"{cx:.1f},{cy:.1f}",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "post.png"),
                        ]
                    ).json
                )
            self.assertLess(obs2["latencyMs"], 10000.0)
            self.assertIn("BRAVO CLICKED OK", _all_ocr_text(obs2).upper())

    # ------------------------------------------------------------------
    # F9 — Native macOS OCR Pipeline (Vision.framework)
    # ------------------------------------------------------------------

    def test_T1_F9_01_ocr_extracts_home_text_with_confidence(self) -> None:
        """T1-F9-01: Vision OCR extracts deterministic text lines from GET /."""
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
                            srv.url("/"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "ocr_home.png"),
                        ]
                    ).json
                )
            for expected in ("HELM HARBOR FIXTURE", "STATUS: HARBOR READY"):
                line = _find_ocr_line(obs["ocrLines"], expected)
                self.assertIsNotNone(line, f"Missing OCR line '{expected}' in {obs['ocrLines']!r}")
                assert line is not None
                self.assertGreaterEqual(float(line["confidence"]), 0.7)

    def test_T1_F9_02_ocr_extracts_three_targets(self) -> None:
        """T1-F9-02: Vision OCR extracts all three target labels on /ocr-target."""
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
                            srv.url("/ocr-target"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "ocr_targets.png"),
                        ]
                    ).json
                )
            for label in ("ALPHA TARGET", "BRAVO ACTION", "CHARLIE VERIFY"):
                self.assertIsNotNone(_find_ocr_line(obs["ocrLines"], label))

    def test_T1_F9_03_ocr_coordinate_mapping_consistency(self) -> None:
        """T1-F9-03: Normalized bottom-left rects and CSS top-left rects are ordered consistently."""
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
                            srv.url("/ocr-target"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "coords.png"),
                        ]
                    ).json
                )
            for line in obs["ocrLines"]:
                nx, ny, nw, nh = _rect_xywh(line["normalizedRect"])
                self.assertGreaterEqual(nx, 0.0)
                self.assertGreaterEqual(ny, 0.0)
                self.assertGreater(nw, 0.0)
                self.assertGreater(nh, 0.0)
                self.assertLessEqual(nx + nw, 1.001)
                self.assertLessEqual(ny + nh, 1.001)

            alpha = _find_ocr_line(obs["ocrLines"], "ALPHA TARGET")
            bravo = _find_ocr_line(obs["ocrLines"], "BRAVO ACTION")
            charlie = _find_ocr_line(obs["ocrLines"], "CHARLIE VERIFY")
            self.assertIsNotNone(alpha)
            self.assertIsNotNone(bravo)
            self.assertIsNotNone(charlie)
            assert alpha is not None and bravo is not None and charlie is not None

            ay = _rect_xywh(alpha["cssRect"])[1]
            by = _rect_xywh(bravo["cssRect"])[1]
            cy = _rect_xywh(charlie["cssRect"])[1]
            self.assertLess(ay, by)
            self.assertLess(by, cy)

            any_norm = _rect_xywh(alpha["normalizedRect"])[1]
            charlie_norm = _rect_xywh(charlie["normalizedRect"])[1]
            self.assertGreater(any_norm, charlie_norm)

    def test_T1_F9_04_warm_ocr_latency_budget(self) -> None:
        """T1-F9-04: Warm consecutive Vision OCR call completes within interactive budget."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard():
                run_helmctl(
                    [
                        "browser",
                        "act",
                        "--url",
                        srv.url("/ocr-target"),
                        "--screenshot-out",
                        str(ws.artifacts_dir / "warm1.png"),
                    ]
                )
                obs2 = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/ocr-target"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "warm2.png"),
                        ]
                    ).json
                )
            self.assertLess(obs2["latencyMs"], 15000.0)
            self.assertIsNotNone(_find_ocr_line(obs2["ocrLines"], "BRAVO ACTION"))

    def test_T1_F9_05_ocr_reads_dynamic_result_page(self) -> None:
        """T1-F9-05: Vision OCR reads dynamic query params rendered on /result."""
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
                            srv.url("/result?code=HELM99&note=PASS"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "result.png"),
                        ]
                    ).json
                )
            text = _all_ocr_text(obs).upper()
            self.assertIn("ORDER CONFIRMED", text)
            self.assertIn("HELM99", text)
            self.assertIn("PASS", text)

    # ------------------------------------------------------------------
    # F10 — Browse-Read-Act Closed Loop
    # ------------------------------------------------------------------

    def test_T1_F10_01_click_ocr_target_button(self) -> None:
        """T1-F10-01: Click visible button matched purely by Vision OCR text (--click-ocr)."""
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
                            srv.url("/ocr-target"),
                            "--click-ocr",
                            "BRAVO ACTION",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "clicked.png"),
                        ]
                    ).json
                )
            self.assertIn("BRAVO CLICKED OK", _all_ocr_text(obs).upper())

    def test_T1_F10_02_type_form_and_submit_ocr(self) -> None:
        """T1-F10-02: Type into form fields and submit via OCR click to reach /result."""
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
                            srv.url("/form"),
                            "--type",
                            "code=HLM42",
                            "--type",
                            "note=ALPHA",
                            "--click-ocr",
                            "SUBMIT ORDER",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "submitted.png"),
                        ]
                    ).json
                )
            self.assertIn("/result", obs["url"])
            text = _all_ocr_text(obs).upper()
            self.assertIn("ORDER CONFIRMED", text)
            self.assertIn("HLM42", text)
            self.assertIn("ALPHA", text)

    def test_T1_F10_03_post_click_screenshot_artifact_valid(self) -> None:
        """T1-F10-03: Screenshot artifact written cleanly and reflects post-click state."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            shot = ws.artifacts_dir / "after.png"
            with FocusGuard():
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
                            str(shot),
                        ]
                    ).json
                )
            self.assertTrue(shot.is_file())
            self.assertTrue(Path(obs["screenshotPNGPath"]).is_file())
            info = inspect_png(shot)
            self.assertGreater(info["width"], 400)
            self.assertGreater(info["height"], 300)
            self.assertFalse(info["is_uniform"])

    def test_T1_F10_04_observation_tagged_untrusted_data(self) -> None:
        """T1-F10-04: External web observation is strictly tagged untrustedData."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.artifacts_dir is not None
            with FocusGuard():
                res = run_helmctl(
                    [
                        "browser",
                        "act",
                        "--url",
                        srv.url("/"),
                        "--screenshot-out",
                        str(ws.artifacts_dir / "trust.png"),
                    ]
                )
            obs = validate_browser_observation(res.json, require_untrusted=True)
            self.assertEqual(obs["trustTag"], "untrustedData")

    def test_T1_F10_05_follow_link_from_home_to_form(self) -> None:
        """T1-F10-05: Navigate from / to /form via OCR click on OPEN FORM."""
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
                            srv.url("/"),
                            "--click-ocr",
                            "OPEN FORM",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "nav_form.png"),
                        ]
                    ).json
                )
            self.assertTrue(obs["url"].rstrip("/").endswith("/form"), f"Unexpected url: {obs['url']}")
            self.assertIn("DISPATCH FORM", _all_ocr_text(obs).upper())

    # ------------------------------------------------------------------
    # F11 — Native macOS Control Plane UI, Custom Logo & Animations
    # ------------------------------------------------------------------

    def test_T1_F11_01_helm_app_headless_launches_and_writes_snapshots(self) -> None:
        """T1-F11-01: Helm.app launches with HELM_NO_ACTIVATE=1 --headless and writes snapshots."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "snaps"
            rc, _, stderr, _ = _run_headless_app_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, f"Helm.app exited {rc}: {stderr}")
            pngs = sorted(snap_dir.rglob("*.png"))
            self.assertGreaterEqual(len(pngs), 1, f"No snapshots written to {snap_dir}")

    def test_T1_F11_02_custom_appicon_icns_bundled(self) -> None:
        """T1-F11-02: Custom Compass-Helm AppIcon.icns bundled in Helm.app."""
        require_helm_app()
        bundle = find_helm_app_bundle()
        self.assertIsNotNone(bundle, "Expected .app bundle for Helm.app")
        assert bundle is not None
        info_plist = bundle / "Contents" / "Info.plist"
        self.assertTrue(info_plist.is_file(), f"Missing Info.plist at {info_plist}")
        plist_text = subprocess.run(
            ["plutil", "-p", str(info_plist)],
            capture_output=True,
            text=True,
            timeout=5.0,
            check=True,
        ).stdout
        self.assertIn("CFBundleIcon", plist_text)
        resources_dir = bundle / "Contents" / "Resources"
        icns_files = list(resources_dir.glob("*.icns")) if resources_dir.is_dir() else []
        self.assertGreaterEqual(len(icns_files), 1, f"Expected .icns in {resources_dir}")
        self.assertGreater(icns_files[0].stat().st_size, 1024)

    def test_T1_F11_03_light_and_dark_snapshots_distinct_luminance(self) -> None:
        """T1-F11-03: Deterministic Light and Dark mode UI snapshots generated with lightMean > darkMean."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "appearance"
            rc, _, stderr, _ = _run_headless_app_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, f"Helm.app exited {rc}: {stderr}")
            pngs = sorted(snap_dir.rglob("*.png"))
            light_pngs = [p for p in pngs if "light" in p.name.lower()]
            dark_pngs = [p for p in pngs if "dark" in p.name.lower()]
            self.assertGreaterEqual(len(light_pngs), 1, f"No light PNG in {[p.name for p in pngs]}")
            self.assertGreaterEqual(len(dark_pngs), 1, f"No dark PNG in {[p.name for p in pngs]}")
            light_info = inspect_png(light_pngs[0])
            dark_info = inspect_png(dark_pngs[0])
            self.assertGreaterEqual(light_info["width"], 900)
            self.assertGreaterEqual(light_info["height"], 600)
            self.assertGreaterEqual(dark_info["width"], 900)
            self.assertGreaterEqual(dark_info["height"], 600)
            self.assertFalse(light_info["is_uniform"])
            self.assertFalse(dark_info["is_uniform"])
            self.assertGreater(light_info["mean_luminance"], dark_info["mean_luminance"])

    def test_T1_F11_04_steady_vs_exception_snapshots_differ(self) -> None:
        """T1-F11-04: Steady-state vs Exception-state snapshots captured and visibly distinct."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "states"
            rc, _, stderr, _ = _run_headless_app_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, f"Helm.app exited {rc}: {stderr}")
            pngs = sorted(snap_dir.rglob("*.png"))
            steady = [p for p in pngs if any(k in p.name.lower() for k in ("steady", "calm", "normal"))]
            alert = [p for p in pngs if any(k in p.name.lower() for k in ("exception", "alert", "held"))]
            self.assertGreaterEqual(len(steady), 1, f"Missing steady snapshot in {[p.name for p in pngs]}")
            self.assertGreaterEqual(len(alert), 1, f"Missing exception snapshot in {[p.name for p in pngs]}")
            s_info = inspect_png(steady[0])
            a_info = inspect_png(alert[0])
            self.assertNotEqual(s_info["pixel_sha256"], a_info["pixel_sha256"])

    def test_T1_F11_05_virtualization_entitlement_signed(self) -> None:
        """T1-F11-05: Entitlement com.apple.security.virtualization present on signed Helm.app."""
        require_helm_app()
        bundle = find_helm_app_bundle()
        self.assertIsNotNone(bundle)
        assert bundle is not None
        proc = subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", str(bundle)],
            capture_output=True,
            text=True,
            timeout=10.0,
        )
        combined = proc.stdout + "\n" + proc.stderr
        self.assertEqual(proc.returncode, 0, f"codesign failed: {combined}")
        self.assertIn("com.apple.security.virtualization", combined)

    # ------------------------------------------------------------------
    # F12 — Pattern-Assigned Animated Agent Characters
    # ------------------------------------------------------------------

    def test_T1_F12_01_seeded_snapshots_render_characters(self) -> None:
        """T1-F12-01: Seeded demo snapshots render non-blank Orchestrator and worker glyphs."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "chars"
            rc, _, stderr, _ = _run_headless_app_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, f"Helm.app exited {rc}: {stderr}")
            pngs = sorted(snap_dir.rglob("*.png"))
            self.assertGreaterEqual(len(pngs), 1)
            for p in pngs:
                info = inspect_png(p)
                self.assertFalse(info["is_uniform"], f"Blank uniform snapshot: {p}")
                self.assertGreater(info["file_bytes"], 5000)

    def test_T1_F12_02_character_seed_uniqueness_across_five_agents(self) -> None:
        """T1-F12-02: 5 distinct agents yield 5 distinct characterSeeds."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "SeedUniq",
                    "--goal",
                    "Test seeds",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            seeds: Set[str] = set()
            for idx in range(5):
                agent = run_helmctl(
                    [
                        "agent",
                        "add",
                        "--project",
                        proj["id"],
                        "--name",
                        f"Agent-{idx}",
                        "--role",
                        "specialist",
                        "--goal",
                        f"Task {idx}",
                        "--backend",
                        "mock",
                    ],
                    db_path=ws.db_path,
                ).json
                seeds.add(_extract_seed_token(agent))
            self.assertEqual(len(seeds), 5)

    def test_T1_F12_03_agent_state_transitions_reflected_in_snapshots(self) -> None:
        """T1-F12-03: Seeded snapshots reflect distinct agent activity/exception states."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "agent_states"
            rc, _, stderr, _ = _run_headless_app_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, f"Helm.app exited {rc}: {stderr}")
            pngs = sorted(snap_dir.rglob("*.png"))
            self.assertGreaterEqual(len(pngs), 2)
            hashes = {inspect_png(p)["pixel_sha256"] for p in pngs}
            self.assertGreaterEqual(len(hashes), 2)

    def test_T1_F12_04_deterministic_rendering_across_runs(self) -> None:
        """T1-F12-04: Repeated --seed-demo runs produce deterministic layout/dimensions."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            dir1 = ws.artifacts_dir / "det1"
            dir2 = ws.artifacts_dir / "det2"
            rc1, _, err1, _ = _run_headless_app_snapshot(app_exe, dir1)
            rc2, _, err2, _ = _run_headless_app_snapshot(app_exe, dir2)
            self.assertEqual(rc1, 0, err1)
            self.assertEqual(rc2, 0, err2)
            pngs1 = {p.name: inspect_png(p) for p in sorted(dir1.rglob("*.png"))}
            pngs2 = {p.name: inspect_png(p) for p in sorted(dir2.rglob("*.png"))}
            self.assertEqual(set(pngs1.keys()), set(pngs2.keys()))
            self.assertGreater(len(pngs1), 0)
            for name in pngs1:
                self.assertEqual(
                    (pngs1[name]["width"], pngs1[name]["height"]),
                    (pngs2[name]["width"], pngs2[name]["height"]),
                )

    def test_T1_F12_05_reduce_motion_static_frame(self) -> None:
        """T1-F12-05: Reduce Motion fallback produces crisp static PNG frames cleanly."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "reduce_motion"
            rc, _, stderr, _ = _run_headless_app_snapshot(
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

    # ------------------------------------------------------------------
    # F13 — Automated Unit, E2E & Host-Invariance Verification
    # ------------------------------------------------------------------

    def test_T1_F13_01_helm_app_preserves_frontmost_application(self) -> None:
        """T1-F13-01: HELM_NO_ACTIVATE=1 --headless preserves host frontmostApplication."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            _, _, _, report = _run_headless_app_snapshot(app_exe, ws.artifacts_dir / "focus")
            self.assertFalse(report["focusChanged"])
            self.assertEqual(report["activationEvents"], [])
            self.assertEqual(
                report["initial"]["processIdentifier"],
                report["final"]["processIdentifier"],
            )

    def test_T1_F13_02_helm_app_zero_cursor_warp(self) -> None:
        """T1-F13-02: Helm.app --headless produces zero cursor delta."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            _, _, _, report = _run_headless_app_snapshot(app_exe, ws.artifacts_dir / "cursor")
            self.assertFalse(report["cursorMoved"])
            self.assertEqual(report["maxCursorDeltaCG"]["dx"], 0.0)
            self.assertEqual(report["maxCursorDeltaCG"]["dy"], 0.0)
            self.assertEqual(report["maxCursorDeltaNS"]["dx"], 0.0)
            self.assertEqual(report["maxCursorDeltaNS"]["dy"], 0.0)

    def test_T1_F13_03_sandbox_exec_preserves_cursor_and_focus(self) -> None:
        """T1-F13-03: helmctl sandbox exec preserves host cursor and focus."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None
            with FocusGuard(interval_ms=50) as guard:
                res = run_helmctl(
                    [
                        "sandbox",
                        "exec",
                        "--workspace",
                        str(ws.ws_path),
                        "--cmd",
                        "sleep 0.3 && echo INV_OK",
                        "--mode",
                        "seatbelt",
                    ]
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertIn("INV_OK", validate_execution_result(res.json)["stdout"])

    def test_T1_F13_04_browser_act_preserves_cursor_and_focus(self) -> None:
        """T1-F13-04: helmctl browser act (--click-ocr) preserves host cursor and focus."""
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
                            str(ws.artifacts_dir / "inv_browser.png"),
                        ]
                    ).json
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(guard.result["activationEvents"], [])
            self.assertIn("BRAVO CLICKED OK", _all_ocr_text(obs).upper())

    def test_T1_F13_05_simulate_hooks_deterministic(self) -> None:
        """T1-F13-05: --simulate-stall, --simulate-drift, and --simulate-decision hooks match kinds."""
        require_helmctl()
        cases = [
            ("--simulate-stall", "stall"),
            ("--simulate-drift", "drift"),
            ("--simulate-decision", "humanDecision"),
        ]
        for flag, expected_kind in cases:
            with TempWorkspace() as ws:
                assert ws.db_path is not None
                proj, _ = _create_project_and_agent(ws)
                with FocusGuard() as guard:
                    report = run_helmctl(
                        ["run", "--project", proj["id"], flag],
                        db_path=ws.db_path,
                    ).json
                assert guard.result is not None
                self.assertFalse(guard.result["focusChanged"])
                self.assertFalse(guard.result["cursorMoved"])
                self.assertEqual(report["status"], "held")
                self.assertEqual(len(report["exceptions"]), 1)
                self.assertEqual(report["exceptions"][0]["kind"], expected_kind)

    # ------------------------------------------------------------------
    # F14 — Chat Domain Models & Persistence (R1 / M1)
    # ------------------------------------------------------------------

    def test_T1_F14_01_crew_chat_send_list_and_workspace_context(self) -> None:
        """T1-F14-01: Crew chat message send & list persists in crew channel with workspace context."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            (ws.ws_path / "README.md").write_text("PORT=8080\nSERVICE=harbor\n", encoding="utf-8")
            proj, _ = _create_project_and_agent(ws, agent_name="Scout", role="researcher")

            def responder(req: Dict[str, Any]) -> str:
                joined = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                if "PORT=8080" in joined or "README.md" in joined or str(ws.ws_path) in joined:
                    return "Observed PORT=8080 in workspace context."
                return "Crew acknowledged request."

            with LocalLLMServer(responder) as llm:
                sent = run_helmctl_feature(
                    [
                        "chat",
                        "send",
                        "--project",
                        proj["id"],
                        "--channel",
                        "crew",
                        "--content",
                        "Summarize project port from README.md",
                        "--wait",
                    ],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                    feature_name="chat send",
                ).json
                validate_chat_message(sent)
                listed = run_helmctl_feature(
                    ["chat", "list", "--project", proj["id"], "--channel", "crew"],
                    db_path=ws.db_path,
                    feature_name="chat list",
                ).json
                self.assertIsInstance(listed, list)
                self.assertGreaterEqual(len(listed), 1)
                for msg in listed:
                    validate_chat_message(msg)
                    self.assertEqual(msg["channelKey"], "crew")
                self.assertTrue(any(m["senderKind"] == "user" for m in listed))

    def test_T1_F14_02_direct_chat_isolation_between_agents(self) -> None:
        """T1-F14-02: 1-on-1 direct chat isolates messages per agent channel."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, scout = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
            forge = run_helmctl(
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
                    "Build code",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            ).json

            run_helmctl_feature(
                [
                    "chat",
                    "send",
                    "--project",
                    proj["id"],
                    "--channel",
                    f"direct:{scout['id']}",
                    "--content",
                    "Private prompt for Scout only",
                    "--wait",
                ],
                db_path=ws.db_path,
                feature_name="chat send direct",
            )
            scout_msgs = run_helmctl_feature(
                ["chat", "list", "--project", proj["id"], "--channel", f"direct:{scout['id']}"],
                db_path=ws.db_path,
                feature_name="chat list direct",
            ).json
            forge_msgs = run_helmctl_feature(
                ["chat", "list", "--project", proj["id"], "--channel", f"direct:{forge['id']}"],
                db_path=ws.db_path,
                feature_name="chat list direct",
            ).json
            self.assertGreaterEqual(len(scout_msgs), 1)
            for m in scout_msgs:
                validate_chat_message(m)
                self.assertEqual(m["channelKey"], f"agent:{scout['id']}")
            self.assertEqual(forge_msgs, [])

    def test_T1_F14_03_chat_multi_turn_chronological_and_focus_guard(self) -> None:
        """T1-F14-03: Multi-turn direct chat preserves chronological order under FocusGuard."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, scout = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
            with FocusGuard(interval_ms=50) as guard:
                run_helmctl_feature(
                    [
                        "chat",
                        "send",
                        "--project",
                        proj["id"],
                        "--channel",
                        f"direct:{scout['id']}",
                        "--content",
                        "Turn 1 inspect config",
                        "--wait",
                    ],
                    db_path=ws.db_path,
                    feature_name="chat send",
                )
                run_helmctl_feature(
                    [
                        "chat",
                        "send",
                        "--project",
                        proj["id"],
                        "--channel",
                        f"direct:{scout['id']}",
                        "--content",
                        "Turn 2 update timeout",
                        "--wait",
                    ],
                    db_path=ws.db_path,
                    feature_name="chat send",
                )
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            msgs = run_helmctl_feature(
                ["chat", "list", "--project", proj["id"], "--channel", f"direct:{scout['id']}"],
                db_path=ws.db_path,
                feature_name="chat list",
            ).json
            contents = [m["content"] for m in msgs]
            idx1 = next(i for i, c in enumerate(contents) if "Turn 1 inspect config" in c)
            idx2 = next(i for i, c in enumerate(contents) if "Turn 2 update timeout" in c)
            self.assertLess(idx1, idx2)

    def test_T1_F14_04_chat_sqlite_persistence_and_metadata(self) -> None:
        """T1-F14-04: Chat messages persist in SQLite chat_messages table with channel metadata."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
            sent = run_helmctl_feature(
                [
                    "chat",
                    "send",
                    "--project",
                    proj["id"],
                    "--channel",
                    "crew",
                    "--content",
                    "Check SQLite durability",
                ],
                db_path=ws.db_path,
                feature_name="chat send",
            ).json
            validate_chat_message(sent)
            conn = sqlite3.connect(str(ws.db_path))
            try:
                tables = {
                    r[0]
                    for r in conn.execute(
                        "SELECT name FROM sqlite_master WHERE type='table'"
                    ).fetchall()
                }
                self.assertIn("chat_messages", tables)
                rows = conn.execute(
                    "SELECT id, channel_key, sender_kind, content FROM chat_messages WHERE project_id = ?",
                    (proj["id"],),
                ).fetchall()
                self.assertGreaterEqual(len(rows), 1)
                self.assertTrue(any(r[0] == sent["id"] and r[1] == "crew" for r in rows))
            finally:
                conn.close()

    def test_T1_F14_05_multi_project_chat_isolation_across_restart(self) -> None:
        """T1-F14-05: Two projects in same SQLite DB isolate chat messages across fresh CLI restarts."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.root is not None and ws.db_path is not None
            ws1 = ws.root / "p1"
            ws2 = ws.root / "p2"
            ws1.mkdir()
            ws2.mkdir()
            p1 = run_helmctl(
                ["project", "create", "--name", "ChatP1", "--goal", "G1", "--workspace", str(ws1)],
                db_path=ws.db_path,
            ).json
            p2 = run_helmctl(
                ["project", "create", "--name", "ChatP2", "--goal", "G2", "--workspace", str(ws2)],
                db_path=ws.db_path,
            ).json
            run_helmctl_feature(
                ["chat", "send", "--project", p1["id"], "--channel", "crew", "--content", "ALPHA_ONLY_MSG"],
                db_path=ws.db_path,
                feature_name="chat send",
            )
            run_helmctl_feature(
                ["chat", "send", "--project", p2["id"], "--channel", "crew", "--content", "BETA_ONLY_MSG"],
                db_path=ws.db_path,
                feature_name="chat send",
            )
            list1 = run_helmctl_feature(
                ["chat", "list", "--project", p1["id"], "--channel", "crew"],
                db_path=ws.db_path,
                feature_name="chat list",
            ).json
            list2 = run_helmctl_feature(
                ["chat", "list", "--project", p2["id"], "--channel", "crew"],
                db_path=ws.db_path,
                feature_name="chat list",
            ).json
            self.assertTrue(any("ALPHA_ONLY_MSG" in m["content"] for m in list1))
            self.assertFalse(any("BETA_ONLY_MSG" in m["content"] for m in list1))
            self.assertTrue(any("BETA_ONLY_MSG" in m["content"] for m in list2))
            self.assertFalse(any("ALPHA_ONLY_MSG" in m["content"] for m in list2))

    # ------------------------------------------------------------------
    # F15 — Editable System Prompt & Role Templates (R4 / M1)
    # ------------------------------------------------------------------

    def test_T1_F15_01_agent_system_prompt_update_persists_across_restart(self) -> None:
        """T1-F15-01: agent update --system-prompt persists across fresh process and in SQLite."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, agent = _create_project_and_agent(ws, agent_name="PromptBot", role="coder")
            updated = run_helmctl_feature(
                [
                    "agent",
                    "update",
                    "--id",
                    agent["id"],
                    "--system-prompt",
                    "Always include TAG_CUSTOM_42 in responses.",
                ],
                db_path=ws.db_path,
                feature_name="agent update",
            ).json
            sp = require_feature_field(updated, "systemPrompt", "Editable systemPrompt")
            self.assertEqual(sp, "Always include TAG_CUSTOM_42 in responses.")
            listed = run_helmctl(["agent", "list", "--project", proj["id"]], db_path=ws.db_path).json
            self.assertEqual(listed[0]["systemPrompt"], "Always include TAG_CUSTOM_42 in responses.")

    def test_T1_F15_02_edited_system_prompt_reaches_llm_request(self) -> None:
        """T1-F15-02: Edited systemPrompt reaches subsequent LLM system message verbatim."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, agent = _create_project_and_agent(
                ws, agent_name="DirectBot", role="researcher", backend="http"
            )
            run_helmctl_feature(
                [
                    "agent",
                    "update",
                    "--id",
                    agent["id"],
                    "--system-prompt",
                    "DIRECTIVE_OMEGA_991: verify local project files first.",
                ],
                db_path=ws.db_path,
                feature_name="agent update",
            )

            def responder(req: Dict[str, Any]) -> str:
                transcript = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                if "DECOMPOSE_GOAL" in transcript:
                    return json.dumps(
                        {
                            "tasks": [
                                {
                                    "temp_id": "t1",
                                    "title": "VerifyDirective",
                                    "instructions": "Verify custom system prompt directive",
                                    "assigned_agent_id": agent["id"],
                                    "waiting_on_temp_ids": [],
                                }
                            ]
                        }
                    )
                return json.dumps(
                    {
                        "thought": "done",
                        "tool_calls": [
                            {
                                "id": "done1",
                                "name": "complete_task",
                                "arguments": {"summary": "Verified directive"},
                            }
                        ],
                    }
                )

            with LocalLLMServer(responder) as llm:
                run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "4"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                )
                worker_reqs = [
                    r
                    for r in llm.requests
                    if "DECOMPOSE_GOAL" not in "\n".join(str(m.get("content", "")) for m in r.get("messages", []))
                ]
                self.assertGreaterEqual(len(worker_reqs), 1)
                sys_msgs = [
                    str(m.get("content", ""))
                    for req in worker_reqs
                    for m in req.get("messages", [])
                    if m.get("role") == "system"
                ]
                self.assertTrue(
                    any("DIRECTIVE_OMEGA_991" in s for s in sys_msgs),
                    f"Expected DIRECTIVE_OMEGA_991 in LLM worker system prompt: {sys_msgs!r}",
                )

    def test_T1_F15_03_role_personality_preset_populates_non_locking_template(self) -> None:
        """T1-F15-03: Role + personality populates non-empty systemPrompt template without locking edits."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, agent = _create_project_and_agent(ws, agent_name="PresetBot", role="coder")
            initial_sp = require_feature_field(agent, "systemPrompt", "Default systemPrompt template")
            self.assertTrue(isinstance(initial_sp, str) and len(initial_sp.strip()) > 0)
            custom = "Custom un-locked prompt v2\nLine 2"
            updated = run_helmctl_feature(
                ["agent", "update", "--id", agent["id"], "--system-prompt", custom],
                db_path=ws.db_path,
                feature_name="agent update",
            ).json
            self.assertEqual(updated["systemPrompt"], custom)

    def test_T1_F15_04_system_prompt_multiline_and_personality_switch(self) -> None:
        """T1-F15-04: Multiline systemPrompt persists alongside personality changes."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, agent = _create_project_and_agent(ws, agent_name="MultiLine", role="qa")
            multiline = "Rule 1: Check edge cases.\nRule 2: Cite exact files.\nRule 3: Be concise."
            updated = run_helmctl_feature(
                [
                    "agent",
                    "update",
                    "--id",
                    agent["id"],
                    "--personality",
                    "adversarialReviewer",
                    "--system-prompt",
                    multiline,
                ],
                db_path=ws.db_path,
                feature_name="agent update",
            ).json
            self.assertEqual(updated.get("personality"), "adversarialReviewer")
            self.assertEqual(updated.get("systemPrompt"), multiline)

    def test_T1_F15_05_v2_to_v3_migration_backfills_system_prompt(self) -> None:
        """T1-F15-05: Opening a genuine v2 schema database backfills agents.system_prompt and projects.sandbox_trust_policy in v3."""
        import hashlib
        import uuid

        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj_id = str(uuid.uuid4()).upper()
            agent_id = str(uuid.uuid4()).upper()
            digest_bytes = hashlib.sha256(agent_id.encode("utf-8")).digest()
            seed_json = json.dumps(
                {
                    "agentID": agent_id,
                    "isOrchestrator": False,
                    "hexDigest": digest_bytes.hex(),
                    "crownIndex": digest_bytes[0] % 8,
                    "eyeIndex": digest_bytes[1] % 6,
                    "bodyMask": (((digest_bytes[2] << 8) | digest_bytes[3]) & 0x7FFF) or 0x0420,
                    "hueIndex": digest_bytes[4] % 6,
                }
            )
            budget_json = json.dumps(
                {
                    "maxStepsPerRun": 50,
                    "stepTimeoutSeconds": 120.0,
                    "maxConsecutiveToolFailures": 3,
                    "coordinatorStallSeconds": 180.0,
                    "minFreeDiskMB": 500,
                    "memoryCharBudget": 4000,
                }
            )
            conn = sqlite3.connect(str(ws.db_path))
            try:
                conn.executescript(
                    """
                    CREATE TABLE projects (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        goal TEXT NOT NULL,
                        workspace_root TEXT NOT NULL,
                        status TEXT NOT NULL CHECK (status IN ('idle','running','paused','held','completed','failed')),
                        budget_policy_json TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    );
                    CREATE TABLE agents (
                        id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                        name TEXT NOT NULL,
                        role TEXT NOT NULL,
                        goal TEXT NOT NULL,
                        capabilities_json TEXT NOT NULL,
                        backend_kind TEXT NOT NULL,
                        model_override TEXT,
                        activity_state TEXT NOT NULL CHECK (activity_state IN ('idle','thinking','browsing','executing','waiting','exception','paused','completed')),
                        character_seed_json TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        personality TEXT NOT NULL DEFAULT 'pragmaticBuilder',
                        personality_notes TEXT NOT NULL DEFAULT '',
                        UNIQUE(project_id, name)
                    );
                    CREATE TABLE tasks (
                        id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                        parent_task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
                        assigned_agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
                        created_by_agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
                        title TEXT NOT NULL,
                        instructions TEXT NOT NULL,
                        status TEXT NOT NULL CHECK (status IN ('queued','running','blocked','needsHuman','done','failed','cancelled','outcomeUnknown')),
                        waiting_on_json TEXT NOT NULL DEFAULT '[]',
                        attempt_count INTEGER NOT NULL DEFAULT 0,
                        max_attempts INTEGER NOT NULL DEFAULT 3,
                        has_external_side_effect INTEGER NOT NULL DEFAULT 0,
                        result_summary TEXT,
                        error_summary TEXT,
                        artifact_paths_json TEXT NOT NULL DEFAULT '[]',
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        started_at REAL,
                        completed_at REAL
                    );
                    CREATE TABLE shared_state (
                        id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                        scope TEXT NOT NULL CHECK (scope IN ('agentPrivate','projectShared')),
                        owner_agent_id TEXT REFERENCES agents(id) ON DELETE CASCADE,
                        category TEXT NOT NULL CHECK (category IN ('rule','fact','decision','artifactRef','continuity','observation')),
                        state_key TEXT NOT NULL,
                        title TEXT NOT NULL,
                        content TEXT NOT NULL,
                        trust_level TEXT NOT NULL CHECK (trust_level IN ('untrustedData','agentGenerated','orchestratorVerified','humanAuthoritative')),
                        provenance_json TEXT NOT NULL,
                        content_sha256 TEXT NOT NULL,
                        pinned INTEGER NOT NULL DEFAULT 0,
                        access_count INTEGER NOT NULL DEFAULT 0,
                        last_accessed_at REAL NOT NULL,
                        supersedes_entry_id TEXT,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    );
                    CREATE TABLE events (
                        seq INTEGER PRIMARY KEY AUTOINCREMENT,
                        id TEXT NOT NULL UNIQUE,
                        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                        agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
                        task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
                        kind TEXT NOT NULL,
                        summary TEXT NOT NULL,
                        payload_json TEXT,
                        trust_level TEXT NOT NULL CHECK (trust_level IN ('untrustedData','agentGenerated','orchestratorVerified','humanAuthoritative')),
                        created_at REAL NOT NULL
                    );
                    CREATE TABLE exceptions (
                        id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                        task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
                        agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
                        kind TEXT NOT NULL CHECK (kind IN ('stall','loop','drift','budget','humanDecision','coordinatorStalled','providerFailure')),
                        severity TEXT NOT NULL CHECK (severity IN ('attention','critical')),
                        status TEXT NOT NULL CHECK (status IN ('open','resolved','dismissed')),
                        dedup_key TEXT NOT NULL,
                        title TEXT NOT NULL,
                        summary TEXT NOT NULL,
                        diagnostic_summary TEXT NOT NULL,
                        suggested_options_json TEXT NOT NULL DEFAULT '[]',
                        evidence_json TEXT,
                        resolution_json TEXT,
                        created_at REAL NOT NULL,
                        resolved_at REAL
                    );
                    CREATE TABLE artifacts (
                        id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                        agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
                        task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
                        kind TEXT NOT NULL,
                        relative_path TEXT NOT NULL,
                        mime_type TEXT,
                        byte_size INTEGER NOT NULL DEFAULT 0,
                        sha256 TEXT NOT NULL,
                        created_at REAL NOT NULL
                    );
                    CREATE TABLE prompt_channel_digests (
                        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                        agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
                        channel TEXT NOT NULL,
                        digest TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        PRIMARY KEY (project_id, agent_id, channel)
                    );
                    """
                )
                conn.execute(
                    "INSERT INTO projects (id, name, goal, workspace_root, status, budget_policy_json, created_at, updated_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        proj_id,
                        "LegacyV2Project",
                        "Verify v2 to v3 migration",
                        ws.ws_path.as_uri(),
                        "idle",
                        budget_json,
                        1700000000.0,
                        1700000000.0,
                    ),
                )
                conn.execute(
                    "INSERT INTO agents (id, project_id, name, role, goal, capabilities_json, backend_kind, model_override, "
                    "activity_state, character_seed_json, created_at, updated_at, personality, personality_notes) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        agent_id,
                        proj_id,
                        "MigBot",
                        "coder",
                        "Migrate legacy v2 goal",
                        json.dumps(["codeExec", "readSharedState"]),
                        "mock",
                        None,
                        "idle",
                        seed_json,
                        1700000000.0,
                        1700000000.0,
                        "pragmaticBuilder",
                        "Legacy v2 note: check edge cases",
                    ),
                )
                conn.execute("PRAGMA user_version = 2;")
                conn.commit()
            finally:
                conn.close()

            listed = run_helmctl(["agent", "list", "--project", proj_id], db_path=ws.db_path).json
            self.assertEqual(len(listed), 1)
            self.assertEqual(listed[0]["id"], agent_id)
            backfilled_sp = require_feature_field(listed[0], "systemPrompt", "Schema v3 systemPrompt")
            self.assertIn("Migrate legacy v2 goal", backfilled_sp)
            self.assertIn("Legacy v2 note: check edge cases", backfilled_sp)

            shown = run_helmctl(["project", "show", "--id", proj_id], db_path=ws.db_path).json
            validate_project_trust_policy(shown, expected="standardWorkspace")

            conn = sqlite3.connect(str(ws.db_path))
            try:
                user_version = conn.execute("PRAGMA user_version").fetchone()[0]
                self.assertGreaterEqual(user_version, 3)
                agent_cols = {r[1] for r in conn.execute("PRAGMA table_info(agents)").fetchall()}
                proj_cols = {r[1] for r in conn.execute("PRAGMA table_info(projects)").fetchall()}
                tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
                self.assertIn("system_prompt", agent_cols)
                self.assertIn("sandbox_trust_policy", proj_cols)
                self.assertIn("chat_messages", tables)
                self.assertIn("agent_work_entries", tables)
                row = conn.execute("SELECT system_prompt FROM agents WHERE id = ?", (agent_id,)).fetchone()
                self.assertIsNotNone(row)
                self.assertIn("Migrate legacy v2 goal", str(row[0]))
            finally:
                conn.close()

    # ------------------------------------------------------------------
    # F16 — Simplified Project Sandbox/Trust Policy (R4 / M1)
    # ------------------------------------------------------------------

    def test_T1_F16_01_project_trust_policy_default_and_updates(self) -> None:
        """T1-F16-01: Project defaults to standardWorkspace and persists trust-policy transitions."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "TrustProj",
                    "--goal",
                    "Verify trust policy",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            require_feature_field(proj, "sandboxTrustPolicy", "Project sandboxTrustPolicy")
            validate_project_trust_policy(proj, expected="standardWorkspace")
            for mode in ("sandboxed", "trustedFullAccess", "standardWorkspace"):
                upd = run_helmctl_feature(
                    ["project", "update-trust", "--id", proj["id"], "--trust-policy", mode],
                    db_path=ws.db_path,
                    feature_name="project update-trust",
                ).json
                validate_project_trust_policy(upd, expected=mode)
                shown = run_helmctl(
                    ["project", "show", "--id", proj["id"]], db_path=ws.db_path
                ).json
                validate_project_trust_policy(shown, expected=mode)

    # ------------------------------------------------------------------
    # F17 — Per-Agent Work Feed Schema & Queries (R3 / M1)
    # ------------------------------------------------------------------

    def test_T1_F17_01_work_feed_entries_emitted_with_structured_fields(self) -> None:
        """T1-F17-01: Autonomous run emits structured AgentWorkEntry items queryable via work-feed list."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="FeedBot", role="coder", backend="mock")
            run_helmctl(["run", "--project", proj["id"], "--max-steps", "6"], db_path=ws.db_path)
            entries = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            self.assertIsInstance(entries, list)
            self.assertGreaterEqual(len(entries), 1)
            for entry in entries:
                validate_agent_work_entry(entry)

    def test_T1_F17_02_work_feed_filter_by_agent_id(self) -> None:
        """T1-F17-02: work-feed list --agent filters strictly to the requested agent."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, a1 = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
            a2 = run_helmctl(
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
                    "Write output",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            ).json
            run_helmctl(["run", "--project", proj["id"], "--max-steps", "10"], db_path=ws.db_path)
            a1_entries = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"], "--agent", a1["id"]],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            self.assertGreaterEqual(len(a1_entries), 1)
            for entry in a1_entries:
                validate_agent_work_entry(entry)
                self.assertEqual(entry["agentID"], a1["id"])
                self.assertNotEqual(entry["agentID"], a2["id"])

    def test_T1_F17_03_work_feed_tracks_touched_files_and_artifacts(self) -> None:
        """T1-F17-03: Work-feed entries track touchedFiles and artifactPaths accurately."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            (ws.ws_path / "in.txt").write_text("INPUT_DATA_123", encoding="utf-8")
            proj, file_bot = _create_project_and_agent(
                ws,
                agent_name="FileBot",
                role="coder",
                backend="http",
                capabilities="codeExec,readSharedState,proposeSharedState",
            )
            step = {"n": 0}

            def responder(req: Dict[str, Any]) -> str:
                transcript = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                if "DECOMPOSE_GOAL" in transcript:
                    return json.dumps(
                        {
                            "tasks": [
                                {
                                    "temp_id": "t1",
                                    "title": "TrackTouchedFiles",
                                    "instructions": "Read in.txt and write out.txt",
                                    "assigned_agent_id": file_bot["id"],
                                    "waiting_on_temp_ids": [],
                                }
                            ]
                        }
                    )
                step["n"] += 1
                if step["n"] == 1:
                    return json.dumps(
                        {
                            "thought": "read input",
                            "tool_calls": [
                                {"id": "c1", "name": "read_workspace_file", "arguments": {"path": "in.txt"}}
                            ],
                        }
                    )
                if step["n"] == 2:
                    return json.dumps(
                        {
                            "thought": "write output",
                            "tool_calls": [
                                {
                                    "id": "c2",
                                    "name": "write_workspace_file",
                                    "arguments": {"path": "out.txt", "content": "OUTPUT_DATA_123"},
                                }
                            ],
                        }
                    )
                return json.dumps(
                    {
                        "thought": "complete",
                        "tool_calls": [
                            {"id": "c3", "name": "complete_task", "arguments": {"summary": "Wrote out.txt"}}
                        ],
                    }
                )

            with LocalLLMServer(responder) as llm:
                run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "8"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                )
                worker_reqs = [
                    r
                    for r in llm.requests
                    if "DECOMPOSE_GOAL" not in "\n".join(str(m.get("content", "")) for m in r.get("messages", []))
                ]
            entries = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            self.assertGreaterEqual(len(worker_reqs), 3)
            touched = {p for e in entries for p in e.get("touchedFiles", [])}
            self.assertTrue(
                any("out.txt" in p for p in touched),
                f"Expected out.txt in work-feed touchedFiles, got {entries!r}",
            )

    def test_T1_F17_04_work_feed_preserves_order_past_200_entries(self) -> None:
        """T1-F17-04: Work feed & events return latest chronological items when >210 rows exist."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, agent = _create_project_and_agent(ws, agent_name="ScrollBot", role="coder")
            run_helmctl(["run", "--project", proj["id"], "--max-steps", "4"], db_path=ws.db_path)
            # Check work-feed CLI exists first
            initial = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            self.assertGreaterEqual(len(initial), 1)
            conn = sqlite3.connect(str(ws.db_path))
            try:
                tables = {
                    r[0]
                    for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
                }
                self.assertIn("agent_work_entries", tables)
                base_ts = time.time() - 500.0
                for idx in range(215):
                    conn.execute(
                        """
                        INSERT INTO agent_work_entries (
                            id, project_id, agent_id, agent_name, task_id, task_title,
                            step_number, phase, summary, tool_name, tool_input_summary,
                            tool_output_summary, touched_files_json, artifact_paths_json, created_at
                        ) VALUES (?, ?, ?, ?, NULL, NULL, ?, 'reasoning', ?, NULL, NULL, NULL, '[]', '[]', ?)
                        """,
                        (
                            f"00000000-0000-0000-0000-{idx + 1000:012d}",
                            proj["id"],
                            agent["id"],
                            "ScrollBot",
                            idx,
                            f"SEEDED_ENTRY_{idx:03d}",
                            base_ts + idx,
                        ),
                    )
                conn.commit()
            finally:
                conn.close()

            latest = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"], "--limit", "50"],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            summaries = [e["summary"] for e in latest]
            self.assertTrue(
                any("SEEDED_ENTRY_214" in s for s in summaries),
                f"Expected latest entry SEEDED_ENTRY_214, got tail={summaries[-5:]!r}",
            )

    def test_T1_F17_05_work_feed_persists_across_process_restart(self) -> None:
        """T1-F17-05: Work-feed entries persist durably across separate helmctl processes."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="DurableFeed", role="researcher")
            run_helmctl(["run", "--project", proj["id"], "--max-steps", "5"], db_path=ws.db_path)
            first = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            second = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            self.assertGreaterEqual(len(first), 1)
            self.assertEqual([e["id"] for e in first], [e["id"] for e in second])

    # ------------------------------------------------------------------
    # F18 — Stateless Prompt Channel Context Fix (R2 / M1)
    # ------------------------------------------------------------------

    def test_T1_F18_01_stateless_http_turns_retain_project_context(self) -> None:
        """T1-F18-01: Stateless HTTP LLM turn 2+ retains project workspace context & shared memory."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            (ws.ws_path / "marker.txt").write_text("HARBOR_CTX_88", encoding="utf-8")
            proj, agent_stateless = _create_project_and_agent(
                ws,
                agent_name="StatelessWorker",
                role="coder",
                backend="http",
                capabilities="codeExec,readSharedState,proposeSharedState",
            )
            turn = {"n": 0}

            def responder(req: Dict[str, Any]) -> str:
                joined = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                if "DECOMPOSE_GOAL" in joined:
                    return json.dumps(
                        {
                            "tasks": [
                                {
                                    "temp_id": "t1",
                                    "title": "StatelessContextCheck",
                                    "instructions": "List files and finish",
                                    "assigned_agent_id": agent_stateless["id"],
                                    "waiting_on_temp_ids": [],
                                }
                            ]
                        }
                    )
                turn["n"] += 1
                if turn["n"] == 1:
                    return json.dumps(
                        {
                            "thought": "list files first",
                            "tool_calls": [
                                {"id": "t1", "name": "list_workspace_files", "arguments": {}}
                            ],
                        }
                    )
                return json.dumps(
                    {
                        "thought": "finish",
                        "tool_calls": [
                            {"id": "t2", "name": "complete_task", "arguments": {"summary": "Done"}}
                        ],
                    }
                )

            with LocalLLMServer(responder) as llm:
                run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "6"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                )
                worker_reqs = [
                    r
                    for r in llm.requests
                    if "DECOMPOSE_GOAL" not in "\n".join(str(m.get("content", "")) for m in r.get("messages", []))
                ]
                if len(worker_reqs) < 2:
                    raise UnbuiltTargetSkip("Multi-turn worker loop not active yet (fewer than 2 worker LLM turns)")
                turn2_user = "\n".join(
                    str(m.get("content", ""))
                    for m in worker_reqs[1].get("messages", [])
                    if m.get("role") == "user"
                )
                self.assertIn(str(ws.ws_path.name), turn2_user)

    # ------------------------------------------------------------------
    # F19 — Autonomous Multi-Turn Execution Loop (R2 / M2)
    # ------------------------------------------------------------------

    def test_T1_F19_01_autonomous_multi_turn_tool_result_feedback_loop(self) -> None:
        """T1-F19-01: AgentWorkerRunner feeds tool outputs across 3+ turns until complete_task."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            (ws.ws_path / "clue.txt").write_text("SECRET_HARBOR_TOKEN_774", encoding="utf-8")
            proj, auto_loop = _create_project_and_agent(
                ws,
                agent_name="AutoLoop",
                role="coder",
                backend="http",
                capabilities="codeExec,readSharedState,proposeSharedState",
            )

            def responder(req: Dict[str, Any]) -> str:
                transcript = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                if "DECOMPOSE_GOAL" in transcript:
                    return json.dumps(
                        {
                            "tasks": [
                                {
                                    "temp_id": "t1",
                                    "title": "AutoLoopTask",
                                    "instructions": "List files, read clue.txt, write proof.txt",
                                    "assigned_agent_id": auto_loop["id"],
                                    "waiting_on_temp_ids": [],
                                }
                            ]
                        }
                    )
                if "SECRET_HARBOR_TOKEN_774" in transcript:
                    if (ws.ws_path / "proof.txt").is_file():
                        return json.dumps(
                            {
                                "thought": "done",
                                "tool_calls": [
                                    {"id": "c4", "name": "complete_task", "arguments": {"summary": "Wrote proof"}}
                                ],
                            }
                        )
                    return json.dumps(
                        {
                            "thought": "write proof",
                            "tool_calls": [
                                {
                                    "id": "c3",
                                    "name": "write_workspace_file",
                                    "arguments": {"path": "proof.txt", "content": "SECRET_HARBOR_TOKEN_774"},
                                }
                            ],
                        }
                    )
                if "clue.txt" in transcript:
                    return json.dumps(
                        {
                            "thought": "read clue",
                            "tool_calls": [
                                {"id": "c2", "name": "read_workspace_file", "arguments": {"path": "clue.txt"}}
                            ],
                        }
                    )
                return json.dumps(
                    {
                        "thought": "list files",
                        "tool_calls": [
                            {"id": "c1", "name": "list_workspace_files", "arguments": {}}
                        ],
                    }
                )

            with LocalLLMServer(responder) as llm:
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "10"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                ).json
                worker_reqs = [
                    r
                    for r in llm.requests
                    if "DECOMPOSE_GOAL" not in "\n".join(str(m.get("content", "")) for m in r.get("messages", []))
                ]
                if len(worker_reqs) < 3:
                    raise UnbuiltTargetSkip("Multi-turn workspace tool feedback loop not implemented yet")
            self.assertEqual(report["status"], "completed")
            self.assertTrue((ws.ws_path / "proof.txt").is_file())
            self.assertEqual(
                (ws.ws_path / "proof.txt").read_text(encoding="utf-8"),
                "SECRET_HARBOR_TOKEN_774",
            )

    # ------------------------------------------------------------------
    # F20 — Workspace Discovery & Read Tools (R2 / M2)
    # ------------------------------------------------------------------

    def test_T1_F20_01_workspace_discovery_and_read_tools(self) -> None:
        """T1-F20-01: list_workspace_files, search_workspace, read_workspace_file work inside project folder."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            (ws.ws_path / "src").mkdir(parents=True, exist_ok=True)
            (ws.ws_path / "src" / "app.swift").write_text("let harborKey = \"ANCHOR_51\"\n", encoding="utf-8")
            proj, discoverer = _create_project_and_agent(
                ws,
                agent_name="Discoverer",
                role="researcher",
                backend="http",
                capabilities="readSharedState,proposeSharedState",
            )
            step = {"n": 0}

            def responder(req: Dict[str, Any]) -> str:
                transcript = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                if "DECOMPOSE_GOAL" in transcript:
                    return json.dumps(
                        {
                            "tasks": [
                                {
                                    "temp_id": "t1",
                                    "title": "DiscoverFiles",
                                    "instructions": "Search and read src/app.swift",
                                    "assigned_agent_id": discoverer["id"],
                                    "waiting_on_temp_ids": [],
                                }
                            ]
                        }
                    )
                step["n"] += 1
                if step["n"] == 1:
                    return json.dumps(
                        {
                            "thought": "search",
                            "tool_calls": [
                                {"id": "s1", "name": "search_workspace", "arguments": {"query": "ANCHOR_51"}}
                            ],
                        }
                    )
                if step["n"] == 2:
                    if "ANCHOR_51" not in transcript and "app.swift" not in transcript:
                        return json.dumps(
                            {
                                "thought": "missing search output",
                                "tool_calls": [
                                    {"id": "s2", "name": "complete_task", "arguments": {"summary": "NO_SEARCH_OUTPUT"}}
                                ],
                            }
                        )
                    return json.dumps(
                        {
                            "thought": "read file",
                            "tool_calls": [
                                {"id": "s2", "name": "read_workspace_file", "arguments": {"path": "src/app.swift"}}
                            ],
                        }
                    )
                return json.dumps(
                    {
                        "thought": "complete",
                        "tool_calls": [
                            {"id": "s3", "name": "complete_task", "arguments": {"summary": "FOUND_ANCHOR_51"}}
                        ],
                    }
                )

            with LocalLLMServer(responder) as llm:
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "8"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                ).json
                worker_reqs = [
                    r
                    for r in llm.requests
                    if "DECOMPOSE_GOAL" not in "\n".join(str(m.get("content", "")) for m in r.get("messages", []))
                ]
                if len(worker_reqs) < 2:
                    raise UnbuiltTargetSkip("Workspace discovery tools not implemented in multi-turn loop yet")
            self.assertEqual(report["status"], "completed")
            self.assertNotIn("NO_SEARCH_OUTPUT", json.dumps(report))

    # ------------------------------------------------------------------
    # F21 — Eliminate Spurious Human Decision Stalls (R2 / M2)
    # ------------------------------------------------------------------

    def test_T1_F21_01_default_agents_complete_without_ask_human_stall(self) -> None:
        """T1-F21-01: Default project agents exclude ask_human and complete multi-agent DAG with 0 holds."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            (ws.ws_path / "brief.md").write_text("Build summary for Harbor.\n", encoding="utf-8")
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "NoSpuriousStall",
                    "--goal",
                    "Analyze project folder and complete without asking human",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            a1 = run_helmctl(
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
                    "Inspect brief",
                    "--backend",
                    "http",
                ],
                db_path=ws.db_path,
            ).json
            require_feature_field(a1, "systemPrompt", "M1/M2 default agent capabilities overhaul")
            if "requestHumanDecision" in a1.get("capabilities", []):
                # Probe M2 CLI surface; skip cleanly while M2 hasn't landed, fail once M2 lands
                run_helmctl_feature(
                    ["agent", "update", "--id", a1["id"], "--system-prompt", a1["systemPrompt"]],
                    db_path=ws.db_path,
                    feature_name="M2 default agent ask_human removal",
                )
            self.assertNotIn("requestHumanDecision", a1.get("capabilities", []))

            saw_ask_human_in_prompt = {"value": False}

            def responder(req: Dict[str, Any]) -> str:
                transcript = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                if "DECOMPOSE_GOAL" in transcript:
                    return json.dumps(
                        {
                            "tasks": [
                                {
                                    "temp_id": "t1",
                                    "title": "AutonomousInspect",
                                    "instructions": "Inspect brief.md and complete without asking human",
                                    "assigned_agent_id": a1["id"],
                                    "waiting_on_temp_ids": [],
                                }
                            ]
                        }
                    )
                sys_text = "\n".join(
                    str(m.get("content", "")) for m in req.get("messages", []) if m.get("role") == "system"
                )
                if "ask_human" in sys_text and "do not" not in sys_text.lower() and "never" not in sys_text.lower():
                    saw_ask_human_in_prompt["value"] = True
                return json.dumps(
                    {
                        "thought": "proceed autonomously",
                        "tool_calls": [
                            {"id": "d1", "name": "complete_task", "arguments": {"summary": "Autonomous complete"}}
                        ],
                    }
                )

            with LocalLLMServer(responder) as llm:
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "8"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                ).json
                worker_reqs = [
                    r
                    for r in llm.requests
                    if "DECOMPOSE_GOAL" not in "\n".join(str(m.get("content", "")) for m in r.get("messages", []))
                ]
                self.assertGreaterEqual(len(worker_reqs), 1)
            self.assertFalse(
                saw_ask_human_in_prompt["value"],
                "Default agent system prompt unexpectedly advertised ask_human without prohibition",
            )
            self.assertEqual(report["status"], "completed")
            self.assertEqual(report["exceptions"], [])
            self.assertEqual(report["alertsSurfaced"], 0)

    # ------------------------------------------------------------------
    # F22 — Chat Execution & Crew Coordination Engine (R1, R2 / M2)
    # ------------------------------------------------------------------

    def test_T1_F22_01_crew_and_direct_chat_execution_engine(self) -> None:
        """T1-F22-01: Crew and 1-on-1 chat execution trigger agent replies using workspace context."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            (ws.ws_path / "status.txt").write_text("CREW_READY_99", encoding="utf-8")
            proj, scout = _create_project_and_agent(
                ws, agent_name="Scout", role="researcher", backend="http"
            )

            def responder(_req: Dict[str, Any]) -> str:
                return json.dumps(
                    {
                        "thought": "reply in chat",
                        "tool_calls": [
                            {"id": "c1", "name": "complete_task", "arguments": {"summary": "CREW_REPLY_OK"}}
                        ],
                    }
                )

            with LocalLLMServer(responder) as llm:
                run_helmctl_feature(
                    [
                        "chat",
                        "send",
                        "--project",
                        proj["id"],
                        "--channel",
                        "crew",
                        "--content",
                        "Coordinate workspace review",
                        "--wait",
                    ],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                    feature_name="chat send",
                )
                crew_msgs = run_helmctl_feature(
                    ["chat", "list", "--project", proj["id"], "--channel", "crew"],
                    db_path=ws.db_path,
                    feature_name="chat list",
                ).json
                self.assertTrue(
                    any(m["senderKind"] in {"agent", "orchestrator"} for m in crew_msgs),
                    f"Expected agent/orchestrator reply in crew chat: {crew_msgs!r}",
                )

    # ------------------------------------------------------------------
    # F23 — CLI Providers Workspace CWD & PATH + Hygiene (R2, R5 / M2)
    # ------------------------------------------------------------------

    def test_T1_F23_01_agy_and_pi_backends_register_and_persist(self) -> None:
        """T1-F23-01: agy and pi CLI backend kinds register cleanly and persist via helmctl."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, a_agy = _create_project_and_agent(
                ws, agent_name="AgyWorker", role="researcher", backend="agy"
            )
            a_pi = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    proj["id"],
                    "--name",
                    "PiWorker",
                    "--role",
                    "coder",
                    "--goal",
                    "Execute via pi",
                    "--backend",
                    "pi",
                ],
                db_path=ws.db_path,
            ).json
            self.assertEqual(a_agy["backend"], "agy")
            self.assertEqual(a_pi["backend"], "pi")
            listed = run_helmctl(["agent", "list", "--project", proj["id"]], db_path=ws.db_path).json
            self.assertEqual({a["backend"] for a in listed}, {"agy", "pi"})

    # ------------------------------------------------------------------
    # F24 — Chat-First Main Workspace UI (R1, R5 / M3)
    # ------------------------------------------------------------------

    def test_T1_F24_01_chat_first_workspace_dark_and_light_snapshots(self) -> None:
        """T1-F24-01: Redesigned chat-first workspace snapshots render non-uniform Dark & Light frames."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "chat_ui"
            rc, _, stderr, _ = _run_headless_app_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, stderr)
            light = inspect_png(snap_dir / "helm_light_steady.png")
            dark = inspect_png(snap_dir / "helm_dark_steady.png")
            self.assertGreaterEqual(light["width"], 900)
            self.assertGreaterEqual(light["height"], 600)
            self.assertFalse(light["is_uniform"])
            self.assertFalse(dark["is_uniform"])
            self.assertGreater(light["mean_luminance"], dark["mean_luminance"])

    # ------------------------------------------------------------------
    # F25 — Live Per-Agent Work Feed & Navigable Tasks UI (R3, R5 / M3)
    # ------------------------------------------------------------------

    def test_T1_F25_01_tasks_list_returns_metadata_and_dependencies(self) -> None:
        """T1-F25-01: helmctl tasks list returns structured tasks with status, agent, and waitingOn."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
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
                    "Implement after research",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            run_helmctl(["run", "--project", proj["id"], "--max-steps", "10"], db_path=ws.db_path)
            tasks = run_helmctl_feature(
                ["tasks", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="tasks list",
            ).json
            self.assertIsInstance(tasks, list)
            self.assertGreaterEqual(len(tasks), 2)
            for t in tasks:
                for key in ("id", "title", "status", "assignedAgentID", "waitingOn"):
                    self.assertIn(key, t)

    def test_T1_F25_02_tasks_and_work_feed_parity_after_mock_run(self) -> None:
        """T1-F25-02: Mock run populates matching tasks and per-agent work-feed entries."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, a1 = _create_project_and_agent(ws, agent_name="Scout", role="researcher")
            run_helmctl(["run", "--project", proj["id"], "--max-steps", "6"], db_path=ws.db_path)
            tasks = run_helmctl_feature(
                ["tasks", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="tasks list",
            ).json
            feed = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"], "--agent", a1["id"]],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            self.assertGreaterEqual(len(tasks), 1)
            self.assertGreaterEqual(len(feed), 1)
            self.assertTrue(all(e["agentID"] == a1["id"] for e in feed))

    def test_T1_F25_03_tasks_list_exposes_result_summary_and_artifact_paths(self) -> None:
        """T1-F25-03: Completed tasks expose resultSummary and artifactPaths list."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="Builder", role="coder")
            run_helmctl(["run", "--project", proj["id"], "--max-steps", "6"], db_path=ws.db_path)
            tasks = run_helmctl_feature(
                ["tasks", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="tasks list",
            ).json
            self.assertGreaterEqual(len(tasks), 1)
            for t in tasks:
                self.assertEqual(t["status"], "done")
                self.assertIn("artifactPaths", t)
                self.assertIsInstance(t["artifactPaths"], list)

    def test_T1_F25_04_headless_snapshots_steady_vs_exception_work_visibility(self) -> None:
        """T1-F25-04: Headless steady and exception snapshots remain visibly distinct."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "work_vis"
            rc, _, stderr, _ = _run_headless_app_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, stderr)
            steady = inspect_png(snap_dir / "helm_dark_steady.png")
            exc = inspect_png(snap_dir / "helm_dark_exception.png")
            self.assertNotEqual(steady["pixel_sha256"], exc["pixel_sha256"])

    def test_T1_F25_05_tasks_list_persists_across_process_restart(self) -> None:
        """T1-F25-05: Task list persists in SQLite across fresh helmctl invocations."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            proj, _ = _create_project_and_agent(ws, agent_name="TaskPersist", role="coder")
            run_helmctl(["run", "--project", proj["id"], "--max-steps", "5"], db_path=ws.db_path)
            t1 = run_helmctl_feature(
                ["tasks", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="tasks list",
            ).json
            t2 = run_helmctl_feature(
                ["tasks", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="tasks list",
            ).json
            self.assertEqual([x["id"] for x in t1], [x["id"] for x in t2])

    # ------------------------------------------------------------------
    # F26 — Editable System Prompt Inspector & Simplified Permissions UI (R4, R5 / M3)
    # ------------------------------------------------------------------

    def test_T1_F26_01_agent_update_system_prompt_and_personality(self) -> None:
        """T1-F26-01: agent update persists both systemPrompt and personality."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            _, agent = _create_project_and_agent(ws, agent_name="InspAgent", role="researcher")
            upd = run_helmctl_feature(
                [
                    "agent",
                    "update",
                    "--id",
                    agent["id"],
                    "--personality",
                    "methodicalArchitect",
                    "--system-prompt",
                    "Verify invariants before answering.",
                ],
                db_path=ws.db_path,
                feature_name="agent update",
            ).json
            self.assertEqual(upd.get("personality"), "methodicalArchitect")
            self.assertEqual(upd.get("systemPrompt"), "Verify invariants before answering.")

    def test_T1_F26_02_project_update_trust_cycles_all_modes(self) -> None:
        """T1-F26-02: project update-trust supports all 3 SandboxTrustPolicy variants."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "TrustCycle",
                    "--goal",
                    "Cycle trust modes",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            require_feature_field(proj, "sandboxTrustPolicy", "Project sandboxTrustPolicy")
            for policy in ("sandboxed", "standardWorkspace", "trustedFullAccess"):
                upd = run_helmctl_feature(
                    ["project", "update-trust", "--id", proj["id"], "--trust-policy", policy],
                    db_path=ws.db_path,
                    feature_name="project update-trust",
                ).json
                validate_project_trust_policy(upd, expected=policy)

    def test_T1_F26_03_default_agent_omits_spurious_human_decision_capability(self) -> None:
        """T1-F26-03: Default agent creation grants direct workspace access without ask_human wall."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "DefaultCapsProj",
                    "--goal",
                    "Verify default agent capabilities",
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
                    "DirectWorker",
                    "--role",
                    "specialist",
                    "--goal",
                    "Work autonomously",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            ).json
            require_feature_field(agent, "systemPrompt", "M1/M2 agent overhaul")
            if "requestHumanDecision" in agent.get("capabilities", []):
                run_helmctl_feature(
                    ["agent", "update", "--id", agent["id"], "--system-prompt", agent["systemPrompt"]],
                    db_path=ws.db_path,
                    feature_name="M2 default agent ask_human removal",
                )
            self.assertNotIn("requestHumanDecision", agent.get("capabilities", []))

    def test_T1_F26_04_capabilities_json_backward_compatibility(self) -> None:
        """T1-F26-04: Explicit --capabilities flags remain serialized in JSON for compatibility."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.db_path is not None
            _, agent = _create_project_and_agent(
                ws, agent_name="CompatBot", role="coder", capabilities="codeExec,readSharedState"
            )
            self.assertEqual(set(agent.get("capabilities", [])), {"codeExec", "readSharedState"})

    def test_T1_F26_05_inspector_seeded_snapshot_renders_cleanly(self) -> None:
        """T1-F26-05: Seeded inspector/workspace snapshot renders cleanly in Dark and Light modes."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "inspector_snap"
            rc, _, stderr, _ = _run_headless_app_snapshot(app_exe, snap_dir)
            self.assertEqual(rc, 0, stderr)
            for name in ("helm_light_steady.png", "helm_dark_steady.png"):
                info = inspect_png(snap_dir / name)
                self.assertFalse(info["is_uniform"])
                self.assertGreaterEqual(info["width"], 900)

    # ------------------------------------------------------------------
    # F27 — Preserved Capabilities: Settings/Auth, Updater, Avatars (R5 / M3)
    # ------------------------------------------------------------------

    def test_T1_F27_01_preserved_settings_snapshots_and_app_regression_suite(self) -> None:
        """T1-F27-01: Preserved Settings Dark/Light snapshots render and HelmAppTests pass."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "settings_snap"
            snap_dir.mkdir(parents=True, exist_ok=True)
            env = os.environ.copy()
            env.pop("HELM_REDUCE_MOTION", None)
            env.pop("HELM_SNAPSHOT_EXTRA", None)
            env["HELM_NO_ACTIVATE"] = "1"
            env["HELM_SNAPSHOT_SETTINGS"] = "1"
            with FocusGuard(interval_ms=50) as guard:
                proc = subprocess.run(
                    [
                        str(app_exe),
                        "--headless",
                        "--seed-demo",
                        "--snapshot-dir",
                        str(snap_dir),
                    ],
                    capture_output=True,
                    text=True,
                    env=env,
                    timeout=45.0,
                )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])

            dark_s = inspect_png(snap_dir / "helm_dark_settings.png")
            light_s = inspect_png(snap_dir / "helm_light_settings.png")
            self.assertFalse(dark_s["is_uniform"])
            self.assertFalse(light_s["is_uniform"])
            self.assertGreater(light_s["mean_luminance"], dark_s["mean_luminance"])

        in_baton = os.environ.get("HELM_IN_BATON") == "1" or bool(os.environ.get("_BATON_LANES"))
        has_xctest = any(
            (REPO_ROOT / ".build" / sub / "HelmAppTests.xctest").exists()
            for sub in ("debug", "arm64-apple-macosx/debug")
        )
        base_swift = ["swift", "test"] + (["--skip-build"] if has_xctest else []) + ["--filter", "HelmAppTests"]
        if not in_baton and os.environ.get("BATON") != "off" and shutil.which("baton"):
            swift_cmd = ["baton", "run", "--lane", "auto", "--"] + base_swift
        else:
            swift_cmd = base_swift
        swift_res = subprocess.run(
            swift_cmd,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=180.0,
        )
        if swift_res.returncode != 0 and has_xctest:
            fallback = (["baton", "run", "--lane", "auto", "--"] if (not in_baton and os.environ.get("BATON") != "off" and shutil.which("baton")) else []) + ["swift", "test", "--filter", "HelmAppTests"]
            swift_res = subprocess.run(
                fallback,
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                timeout=180.0,
            )
        self.assertEqual(
            swift_res.returncode,
            0,
            f"HelmAppTests failed:\n{swift_res.stdout}\n{swift_res.stderr}",
        )

    # ------------------------------------------------------------------
    # F28 — Headless Snapshot QA Completeness (R5 / M3)
    # ------------------------------------------------------------------

    def test_T1_F28_01_headless_snapshot_completeness_and_reduce_motion(self) -> None:
        """T1-F28-01: Default + Reduce Motion + Settings headless snapshots all emit valid non-uniform PNGs."""
        app_exe = require_helm_app()
        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            std_dir = ws.artifacts_dir / "std"
            rm_dir = ws.artifacts_dir / "rm"
            rc1, _, err1, _ = _run_headless_app_snapshot(app_exe, std_dir, reduce_motion=False)
            rc2, _, err2, _ = _run_headless_app_snapshot(app_exe, rm_dir, reduce_motion=True)
            self.assertEqual(rc1, 0, err1)
            self.assertEqual(rc2, 0, err2)
            for p in list(std_dir.glob("*.png")) + list(rm_dir.glob("*.png")):
                info = inspect_png(p)
                self.assertFalse(info["is_uniform"])
                self.assertGreaterEqual(info["width"], 900)
                self.assertGreaterEqual(info["height"], 600)

    # ------------------------------------------------------------------
    # F30 — Repository Privacy & Hygiene Checks (R5 / M4)
    # ------------------------------------------------------------------

    def _tracked_text_files(self) -> List[Path]:
        proc = subprocess.run(
            ["git", "ls-files"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=10.0,
            check=True,
        )
        out: List[Path] = []
        for rel in proc.stdout.splitlines():
            rel = rel.strip()
            if not rel:
                continue
            p = REPO_ROOT / rel
            if p.is_file() and p.suffix.lower() not in {".png", ".icns", ".jpg", ".jpeg", ".pdf"}:
                out.append(p)
        return out

    def test_T1_F30_01_privacy_no_local_user_paths_in_tracked_files(self) -> None:
        """T1-F30-01: Tracked repository files contain zero local user home paths."""
        local_user_re = re.compile(r"/" + "User" + r"s/[A-Za-z0-9._-]+/")
        hits: List[str] = []
        for p in self._tracked_text_files():
            text = p.read_text(encoding="utf-8", errors="ignore")
            for idx, line in enumerate(text.splitlines(), 1):
                if local_user_re.search(line):
                    hits.append(f"{p.relative_to(REPO_ROOT)}:{idx}")
        self.assertEqual(hits, [], f"Local user path(s) found in tracked files: {hits}")

    def test_T1_F30_02_privacy_no_secrets_api_keys_or_signing_material(self) -> None:
        """T1-F30-02: Tracked files contain zero API keys, private keys, or signing credentials."""
        proc = subprocess.run(
            ["git", "ls-files"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=10.0,
            check=True,
        )
        bad_exts = [
            f for f in proc.stdout.splitlines()
            if f.endswith((".p8", ".p12", ".mobileprovision", ".pem", ".key"))
        ]
        self.assertEqual(bad_exts, [], f"Signing/secret files tracked: {bad_exts}")

        secret_re = re.compile(
            "("
            + "sk-" + r"ant-[A-Za-z0-9_-]{10,}|"
            + "sk-" + r"proj-[A-Za-z0-9_-]{10,}|"
            + "gh" + r"p_[A-Za-z0-9]{20,}|"
            + "gh" + r"o_[A-Za-z0-9]{20,}|"
            + "github_" + r"pat_[A-Za-z0-9_]{20,}|"
            + "AK" + r"IA[0-9A-Z]{16}|"
            + r"-----BEGIN (RSA |EC |OPENSSH |PGP |)PRIVATE KEY-----"
            + ")"
        )
        hits: List[str] = []
        for p in self._tracked_text_files():
            text = p.read_text(encoding="utf-8", errors="ignore")
            for idx, line in enumerate(text.splitlines(), 1):
                if secret_re.search(line):
                    hits.append(f"{p.relative_to(REPO_ROOT)}:{idx}")
        self.assertEqual(hits, [], f"Secret/key pattern(s) found: {hits}")

    def test_T1_F30_03_privacy_no_apple_team_ids_or_personal_emails(self) -> None:
        """T1-F30-03: Tracked files contain zero Apple Team IDs or personal email addresses."""
        team_re = re.compile(
            r"(" + "DEVELOPMENT_" + r"TEAM\s*[:=]\s*[A-Z0-9]{10}|" + "Team" + r"Identifier[^A-Za-z0-9]*[A-Z0-9]{10})"
        )
        email_re = re.compile(
            r"[A-Za-z0-9._%+-]+@(" + "gm" + r"ail|" + "ic" + r"loud|" + "yah" + r"oo|" + "hot" + r"mail|" + "proton" + r"mail)\.[a-z]{2,}",
            re.IGNORECASE,
        )
        hits: List[str] = []
        for p in self._tracked_text_files():
            text = p.read_text(encoding="utf-8", errors="ignore")
            for idx, line in enumerate(text.splitlines(), 1):
                if team_re.search(line) or email_re.search(line):
                    hits.append(f"{p.relative_to(REPO_ROOT)}:{idx}")
        self.assertEqual(hits, [], f"Apple Team ID or personal email found: {hits}")

    def test_T1_F30_04_privacy_no_reference_screenshot_paths(self) -> None:
        """T1-F30-04: Tracked files contain zero reference screenshot upload paths or IDs."""
        ref_re = re.compile(
            "(" + "uploaded_" + "media_" + "|" + "500c71c6-" + "19da-4f8b-a193-8e57bbffdf0a" + ")"
        )
        hits: List[str] = []
        for p in self._tracked_text_files():
            text = p.read_text(encoding="utf-8", errors="ignore")
            for idx, line in enumerate(text.splitlines(), 1):
                if ref_re.search(line):
                    hits.append(f"{p.relative_to(REPO_ROOT)}:{idx}")
        self.assertEqual(hits, [], f"Reference screenshot path leaked: {hits}")

    def test_T1_F30_05_privacy_no_third_party_inspiration_names_or_unapproved_ids(self) -> None:
        """T1-F30-05: Tracked files contain zero third-party inspiration brand leaks or unapproved IDs."""
        banned_re = re.compile(
            "("
            + r"\.her" + "mes|"
            + "hermes" + r"-agent|"
            + "nous" + "research|"
            + r"(?<!an)tig" + "ravity"
            + ")",
            re.IGNORECASE,
        )
        personal_id_re = re.compile("sushil" + r"k1991", re.IGNORECASE)
        allowed_updater_files = {
            "README.md",
            "Sources/HelmApp/App/AppUpdateManager.swift",
            "Tests/HelmAppTests/HelmAppTier5Tests.swift",
        }
        hits: List[str] = []
        for p in self._tracked_text_files():
            rel = str(p.relative_to(REPO_ROOT))
            text = p.read_text(encoding="utf-8", errors="ignore")
            for idx, line in enumerate(text.splitlines(), 1):
                if banned_re.search(line):
                    hits.append(f"{rel}:{idx}:banned_token")
                if personal_id_re.search(line):
                    if not (
                        rel in allowed_updater_files
                        and ("github.com/" in line or "api.github.com/repos/" in line)
                    ):
                        hits.append(f"{rel}:{idx}:personal_id")
        self.assertEqual(hits, [], f"Disallowed third-party/personal identifier(s) found: {hits}")


if __name__ == "__main__":
    raise SystemExit(run_tier_module_cli("1"))
