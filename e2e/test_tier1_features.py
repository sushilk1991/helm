#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

from e2e_common import (
    E2ETestCase,
    FocusGuard,
    TempWorkspace,
    UnbuiltTargetSkip,
    find_helm_app_bundle,
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
            raise UnbuiltTargetSkip("HELM_LIVE_LLM=1 not enabled for live CLI provider smoke")

        backend = "claude" if shutil.which("claude") else ("codex" if shutil.which("codex") else None)
        if backend is None:
            raise UnbuiltTargetSkip("Neither claude nor codex CLI found on PATH")

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


if __name__ == "__main__":
    raise SystemExit(run_tier_module_cli("1"))
