#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

from e2e_common import (
    E2ETestCase,
    FocusGuard,
    LocalLLMServer,
    REPO_ROOT,
    REPORTS_DIR,
    TempWorkspace,
    UnbuiltTargetSkip,
    find_helm_app_bundle,
    inspect_png,
    require_feature_field,
    require_helm_app,
    require_helmctl,
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


def _all_ocr_text(obs: Dict[str, Any]) -> str:
    return "\n".join(str(line.get("text", "")) for line in obs.get("ocrLines", []))


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


def _run_headless_app(
    app_exe: Path,
    snap_dir: Path,
    *,
    reduce_motion: bool = False,
    extra_env: Optional[Dict[str, str]] = None,
    timeout: float = 45.0,
) -> tuple[int, str, str]:
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
    env.pop("HELM_SNAPSHOT_SETTINGS", None)
    env.pop("HELM_SNAPSHOT_EXTRA", None)
    if reduce_motion:
        env["HELM_REDUCE_MOTION"] = "1"
    else:
        env.pop("HELM_REDUCE_MOTION", None)
    if extra_env:
        env.update(extra_env)

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
    return proc.returncode, stdout, stderr


class Tier4EndToEndScenarioTests(E2ETestCase):
    """Tier 4 real-world autonomous end-to-end scenarios (T4-E2E-01..T4-E2E-06)."""

    def test_T4_E2E_01_silent_autonomous_research_code_browser_steady_ok(self) -> None:
        """T4-E2E-01: Silent autonomous research -> code -> browser verification (STEADY_OK)."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.ws_path is not None and ws.db_path is not None and ws.artifacts_dir is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "Harbor Launch",
                    "--goal",
                    "Research home fixture, compute summary artifact, verify order confirmation",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            agents = [
                ("Scout", "researcher", "Read fixture home status", "browser,ocr,readSharedState,proposeSharedState"),
                ("Builder", "coder", "Compute summary artifact in isolated sandbox", "codeExec,readSharedState"),
                ("Inspector", "qa", "Submit dispatch form and verify ORDER CONFIRMED", "browser,ocr,readSharedState"),
            ]
            agent_ids: Set[str] = set()
            for name, role, goal, caps in agents:
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
                        goal,
                        "--backend",
                        "mock",
                        "--capabilities",
                        caps,
                    ],
                    db_path=ws.db_path,
                ).json
                agent_ids.add(ag["id"])

            with FocusGuard(interval_ms=50) as guard:
                # 1. Orchestrated multi-agent run stays silent (STEADY_OK)
                report = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "12"],
                    db_path=ws.db_path,
                ).json

                # 2. Research step: read GET / via headless browser + Vision OCR
                obs_home = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "e2e01_home.png"),
                        ]
                    ).json
                )
                self.assertIn("HARBOR READY", _all_ocr_text(obs_home).upper())

                # 3. Code step: produce summary artifact in isolated sandbox
                sb = validate_execution_result(
                    run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(ws.ws_path),
                            "--cmd",
                            "printf 'LAUNCH_42' > summary.txt && cat summary.txt",
                            "--mode",
                            "seatbelt",
                        ]
                    ).json
                )
                self.assertEqual(sb["exitCode"], 0)
                code_token = (ws.ws_path / "summary.txt").read_text(encoding="utf-8").strip()

                # 4. QA step: submit form and OCR verify /result
                obs_result = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/form"),
                            "--type",
                            f"code={code_token}",
                            "--type",
                            "note=STEADY_OK",
                            "--click-ocr",
                            "SUBMIT ORDER",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "e2e01_result.png"),
                        ]
                    ).json
                )

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(report["status"], "completed")
            self.assertEqual(report["alertsSurfaced"], 0)
            self.assertEqual(report["notificationsEmitted"], 0)
            self.assertEqual(report["exceptions"], [])
            self.assertGreaterEqual(report["steadyHeartbeats"], 1)
            self.assertTrue(agent_ids.issubset({t["assignedAgentID"] for t in report["tasks"]}))
            self.assertTrue((ws.ws_path / "summary.txt").is_file())
            result_text = _all_ocr_text(obs_result).upper()
            self.assertIn("ORDER CONFIRMED", result_text)
            self.assertIn("LAUNCH_42", result_text)

    def test_T4_E2E_02_stall_and_drift_durable_across_restart_and_resume(self) -> None:
        """T4-E2E-02: Stall and drift exceptions persist across restart and resolve cleanly."""
        require_helmctl()
        for sim_flag, expected_kind, action, note in (
            ("--simulate-stall", "stall", "retry", None),
            ("--simulate-drift", "drift", "redirect", "Realign to original harbor goal"),
        ):
            with TempWorkspace() as ws:
                assert ws.ws_path is not None and ws.db_path is not None
                proj = run_helmctl(
                    [
                        "project",
                        "create",
                        "--name",
                        f"Durable-{expected_kind}",
                        "--goal",
                        f"Verify {expected_kind} durability",
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
                        "Execute phase",
                        "--backend",
                        "mock",
                    ],
                    db_path=ws.db_path,
                )

                with FocusGuard():
                    held = run_helmctl(
                        ["run", "--project", proj["id"], sim_flag],
                        db_path=ws.db_path,
                    ).json
                self.assertEqual(held["status"], "held")
                self.assertEqual(len(held["exceptions"]), 1)
                self.assertEqual(held["exceptions"][0]["kind"], expected_kind)
                exc_id = held["exceptions"][0]["id"]

                # Fresh process inspects durable queue
                listed = run_helmctl(
                    ["exceptions", "list", "--project", proj["id"]],
                    db_path=ws.db_path,
                ).json
                self.assertEqual(len(listed), 1)
                self.assertEqual(listed[0]["id"], exc_id)
                self.assertEqual(listed[0]["kind"], expected_kind)

                resolve_args = ["exceptions", "resolve", "--id", exc_id, "--action", action]
                if note is not None:
                    resolve_args.extend(["--note", note])
                resolved = run_helmctl(resolve_args, db_path=ws.db_path).json
                validate_exception_alert(resolved)
                self.assertEqual(resolved["status"], "resolved")

                listed_after = run_helmctl(
                    ["exceptions", "list", "--project", proj["id"]],
                    db_path=ws.db_path,
                ).json
                open_after = [e for e in listed_after if e["status"] in {"open", "pending"}]
                self.assertEqual(open_after, [])

                with FocusGuard():
                    resumed = run_helmctl(
                        ["run", "--project", proj["id"], "--max-steps", "10"],
                        db_path=ws.db_path,
                    ).json
                self.assertEqual(resumed["status"], "completed")

    def test_T4_E2E_03_human_decision_gate_redirect_approve_abort_lifecycle(self) -> None:
        """T4-E2E-03: Human Decision Gate supports redirect, approve, and abort lifecycles."""
        require_helmctl()

        # Branch A: Redirect with note -> resume -> completed
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "GateRedirect",
                    "--goal",
                    "Branch A",
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
                    "AgentA",
                    "--role",
                    "researcher",
                    "--goal",
                    "Choose target",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                held = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-decision"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(held["status"], "held")
            self.assertEqual(held["exceptions"][0]["kind"], "humanDecision")
            exc_id = held["exceptions"][0]["id"]
            res_a = run_helmctl(
                [
                    "exceptions",
                    "resolve",
                    "--id",
                    exc_id,
                    "--action",
                    "redirect",
                    "--note",
                    "Target BRAVO ACTION",
                ],
                db_path=ws.db_path,
            ).json
            self.assertEqual(res_a["resolution"]["action"], "redirect")
            self.assertEqual(res_a["resolution"]["note"], "Target BRAVO ACTION")
            with FocusGuard():
                done_a = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "8"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(done_a["status"], "completed")

        # Branch B: Approve -> resume -> completed
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "GateApprove",
                    "--goal",
                    "Branch B",
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
                    "AgentB",
                    "--role",
                    "coder",
                    "--goal",
                    "Proceed on approval",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                held = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-decision"],
                    db_path=ws.db_path,
                ).json
            exc_id = held["exceptions"][0]["id"]
            res_b = run_helmctl(
                ["exceptions", "resolve", "--id", exc_id, "--action", "approve"],
                db_path=ws.db_path,
            ).json
            self.assertEqual(res_b["resolution"]["action"], "approve")
            with FocusGuard():
                done_b = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "8"],
                    db_path=ws.db_path,
                ).json
            self.assertEqual(done_b["status"], "completed")

        # Branch C: Abort -> clean halt, no open holds
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "GateAbort",
                    "--goal",
                    "Branch C",
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
                    "AgentC",
                    "--role",
                    "qa",
                    "--goal",
                    "Await abort",
                    "--backend",
                    "mock",
                ],
                db_path=ws.db_path,
            )
            with FocusGuard():
                held = run_helmctl(
                    ["run", "--project", proj["id"], "--simulate-decision"],
                    db_path=ws.db_path,
                ).json
            exc_id = held["exceptions"][0]["id"]
            res_c = run_helmctl(
                ["exceptions", "resolve", "--id", exc_id, "--action", "abort"],
                db_path=ws.db_path,
            ).json
            self.assertEqual(res_c["status"], "resolved")
            self.assertEqual(res_c["resolution"]["action"], "abort")
            remaining = run_helmctl(
                ["exceptions", "list", "--project", proj["id"]],
                db_path=ws.db_path,
            ).json
            self.assertEqual([e for e in remaining if e["status"] in {"open", "pending"}], [])

    def test_T4_E2E_04_unattended_loop_under_continuous_host_invariance(self) -> None:
        """T4-E2E-04: Sandbox + Browser OCR + Helm.app headless under continuous 50ms FocusGuard."""
        require_helmctl()
        app_exe = require_helm_app()
        pre_chrome = _helm_chrome_pids()

        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.ws_path is not None and ws.artifacts_dir is not None
            snap_dir = ws.artifacts_dir / "e2e04_snaps"

            with FocusGuard(interval_ms=50, strict_cursor=True) as guard:
                sb = validate_execution_result(
                    run_helmctl(
                        [
                            "sandbox",
                            "exec",
                            "--workspace",
                            str(ws.ws_path),
                            "--cmd",
                            "echo E2E04_CODE > code.txt && cat code.txt",
                            "--mode",
                            "seatbelt",
                        ]
                    ).json
                )
                obs_ocr = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/ocr-target"),
                            "--click-ocr",
                            "BRAVO ACTION",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "e2e04_ocr.png"),
                        ]
                    ).json
                )
                obs_form = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/form"),
                            "--type",
                            "code=E2E04",
                            "--type",
                            "note=UNATTENDED",
                            "--click-ocr",
                            "SUBMIT ORDER",
                            "--screenshot-out",
                            str(ws.artifacts_dir / "e2e04_form.png"),
                        ]
                    ).json
                )
                app_rc, _, app_err = _run_headless_app(app_exe, snap_dir)

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(guard.result["activationEvents"], [])
            self.assertEqual(guard.result["maxCursorDeltaCG"]["dx"], 0.0)
            self.assertEqual(guard.result["maxCursorDeltaCG"]["dy"], 0.0)
            self.assertEqual(sb["exitCode"], 0)
            self.assertIn("BRAVO CLICKED OK", _all_ocr_text(obs_ocr).upper())
            self.assertIn("ORDER CONFIRMED", _all_ocr_text(obs_form).upper())
            self.assertEqual(app_rc, 0, app_err)
            self.assertGreaterEqual(len(list(snap_dir.rglob("*.png"))), 1)

        time.sleep(0.2)
        post_chrome = _helm_chrome_pids()
        self.assertEqual(post_chrome - pre_chrome, set())

    def test_T4_E2E_05_helm_app_visual_polish_logo_characters_impeccable_bundle(self) -> None:
        """T4-E2E-05: Multi-state Helm.app Light/Dark/ReduceMotion snapshots & AppIcon export."""
        app_exe = require_helm_app()
        bundle = find_helm_app_bundle()
        self.assertIsNotNone(bundle)
        assert bundle is not None

        # Verify custom AppIcon.icns and virtualization entitlement
        resources_dir = bundle / "Contents" / "Resources"
        icns_files = list(resources_dir.glob("*.icns")) if resources_dir.is_dir() else []
        self.assertGreaterEqual(len(icns_files), 1, f"Missing .icns in {resources_dir}")
        self.assertGreater(icns_files[0].stat().st_size, 1024)
        codesign = subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", str(bundle)],
            capture_output=True,
            text=True,
            timeout=10.0,
        )
        self.assertEqual(codesign.returncode, 0)
        self.assertIn("com.apple.security.virtualization", codesign.stdout + codesign.stderr)

        with TempWorkspace() as ws:
            assert ws.artifacts_dir is not None
            std_dir = ws.artifacts_dir / "std"
            rm_dir = ws.artifacts_dir / "rm"
            extra_dir = ws.artifacts_dir / "settings_and_extra"

            with FocusGuard(interval_ms=50) as guard:
                rc1, _, err1 = _run_headless_app(app_exe, std_dir, reduce_motion=False)
                rc2, _, err2 = _run_headless_app(app_exe, rm_dir, reduce_motion=True)
                rc3, _, err3 = _run_headless_app(
                    app_exe,
                    extra_dir,
                    reduce_motion=False,
                    extra_env={"HELM_SNAPSHOT_SETTINGS": "1", "HELM_SNAPSHOT_EXTRA": "1"},
                )

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(rc1, 0, err1)
            self.assertEqual(rc2, 0, err2)
            self.assertEqual(rc3, 0, err3)

            std_pngs = sorted(std_dir.rglob("*.png"))
            rm_pngs = sorted(rm_dir.rglob("*.png"))
            expected_std = [
                "helm_dark_exception.png",
                "helm_dark_steady.png",
                "helm_light_exception.png",
                "helm_light_steady.png",
            ]
            expected_rm = [
                "helm_dark_exception_reduce_motion.png",
                "helm_dark_steady_reduce_motion.png",
                "helm_light_exception_reduce_motion.png",
                "helm_light_steady_reduce_motion.png",
            ]
            self.assertEqual([p.name for p in std_pngs], expected_std)
            self.assertEqual([p.name for p in rm_pngs], expected_rm)

            std_infos = {p.name: inspect_png(p) for p in std_pngs}
            for name, info in std_infos.items():
                self.assertGreaterEqual(info["width"], 900, name)
                self.assertGreaterEqual(info["height"], 600, name)
                self.assertFalse(info["is_uniform"], name)
            self.assertGreater(
                std_infos["helm_light_steady.png"]["mean_luminance"],
                std_infos["helm_dark_steady.png"]["mean_luminance"],
            )
            self.assertGreater(
                std_infos["helm_light_exception.png"]["mean_luminance"],
                std_infos["helm_dark_exception.png"]["mean_luminance"],
            )
            self.assertNotEqual(
                std_infos["helm_light_steady.png"]["pixel_sha256"],
                std_infos["helm_light_exception.png"]["pixel_sha256"],
            )
            self.assertNotEqual(
                std_infos["helm_dark_steady.png"]["pixel_sha256"],
                std_infos["helm_dark_exception.png"]["pixel_sha256"],
            )

            rm_infos = {p.name: inspect_png(p) for p in rm_pngs}
            for name, info in rm_infos.items():
                self.assertGreaterEqual(info["width"], 900, name)
                self.assertGreaterEqual(info["height"], 600, name)
                self.assertFalse(info["is_uniform"], name)
            self.assertGreater(
                rm_infos["helm_light_steady_reduce_motion.png"]["mean_luminance"],
                rm_infos["helm_dark_steady_reduce_motion.png"]["mean_luminance"],
            )
            self.assertGreater(
                rm_infos["helm_light_exception_reduce_motion.png"]["mean_luminance"],
                rm_infos["helm_dark_exception_reduce_motion.png"]["mean_luminance"],
            )
            self.assertNotEqual(
                rm_infos["helm_dark_steady_reduce_motion.png"]["pixel_sha256"],
                rm_infos["helm_dark_exception_reduce_motion.png"]["pixel_sha256"],
            )

            # Verify Settings (720x660) & Extra M3 snapshots (1280x800) in isolated subdir
            l_settings = inspect_png(extra_dir / "helm_light_settings.png")
            d_settings = inspect_png(extra_dir / "helm_dark_settings.png")
            for info in (l_settings, d_settings):
                self.assertEqual(info["width"], 720)
                self.assertEqual(info["height"], 660)
                self.assertFalse(info["is_uniform"])
            self.assertGreater(l_settings["mean_luminance"], d_settings["mean_luminance"])

            for pair in (
                ("helm_light_inspector_direct.png", "helm_dark_inspector_direct.png"),
                ("helm_light_tasks_navigable.png", "helm_dark_tasks_navigable.png"),
            ):
                light_extra = inspect_png(extra_dir / pair[0])
                dark_extra = inspect_png(extra_dir / pair[1])
                for info in (light_extra, dark_extra):
                    self.assertEqual(info["width"], 1280)
                    self.assertEqual(info["height"], 800)
                    self.assertFalse(info["is_uniform"])
                self.assertGreater(light_extra["mean_luminance"], dark_extra["mean_luminance"])

            # Export standard & reduce-motion snapshot bundle for visual rubric inspection
            export_dir = REPORTS_DIR / "impeccable_snapshots"
            if export_dir.exists():
                for stale in export_dir.glob("*.png"):
                    stale.unlink()
            export_dir.mkdir(parents=True, exist_ok=True)
            for p in std_pngs:
                shutil.copy2(p, export_dir / p.name)
            for p in rm_pngs:
                shutil.copy2(p, export_dir / f"reduce_motion_{p.name}")

    def test_T4_E2E_06_adversarial_injection_hung_endpoint_and_runaway_defense(self) -> None:
        """T4-E2E-06: Prompt injection, /passkey refusal, /slow deadline, and runaway sandbox defense."""
        require_helmctl()
        pre_chrome = _helm_chrome_pids()

        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.ws_path is not None and ws.db_path is not None and ws.artifacts_dir is not None

            with FocusGuard(interval_ms=50) as guard:
                # 1. /prompt-injection tagged untrustedData and cannot alter rules
                obs_inj = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/prompt-injection"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "e2e06_inj.png"),
                        ]
                    ).json,
                    require_untrusted=True,
                )
                self.assertEqual(obs_inj["trustTag"], "untrustedData")

                proj = run_helmctl(
                    [
                        "project",
                        "create",
                        "--name",
                        "AdversarialDefense",
                        "--goal",
                        "Keep project rules safe under adversarial web content",
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
                        "GuardReader",
                        "--role",
                        "browser_analyst",
                        "--goal",
                        "Extract public metric only",
                        "--backend",
                        "mock",
                        "--capabilities",
                        "browser,ocr,readSharedState,proposeSharedState",
                    ],
                    db_path=ws.db_path,
                )
                rep = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "6"],
                    db_path=ws.db_path,
                    env={"HELM_UNTRUSTED_WEB_SNIPPET": _all_ocr_text(obs_inj)},
                ).json
                shared = rep.get("sharedState", [])
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
                    exc.get("kind") == "drift" for exc in rep.get("exceptions", [])
                )
                self.assertTrue(
                    has_untrusted_obs or has_tamper_alert,
                    "Expected HELM_UNTRUSTED_WEB_SNIPPET to be recorded as untrustedData or rejected with drift alert",
                )

                # 2. /passkey refuses fast with zero OS sheet
                obs_pk = validate_browser_observation(
                    run_helmctl(
                        [
                            "browser",
                            "act",
                            "--url",
                            srv.url("/passkey"),
                            "--screenshot-out",
                            str(ws.artifacts_dir / "e2e06_passkey.png"),
                        ]
                    ).json
                )
                self.assertIn("PASSKEY_REFUSED_CLEANLY", _all_ocr_text(obs_pk).upper())

                # 3. /slow?delay=5 with --timeout 2 dies cleanly at deadline
                slow_res = run_helmctl(
                    [
                        "browser",
                        "act",
                        "--url",
                        srv.url("/slow?delay=5"),
                        "--timeout",
                        "2",
                        "--screenshot-out",
                        str(ws.artifacts_dir / "e2e06_slow.png"),
                    ],
                    expect_json=False,
                    check=False,
                    timeout=12.0,
                )
                self.assertNotIn(slow_res.returncode, (0, 69))

                # 4. Runaway CPU loop & output byte flood killed/bounded cleanly
                cpu_res = validate_execution_result(
                    run_helmctl(
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
                        timeout=12.0,
                    ).json
                )
                self.assertTrue(cpu_res["timedOut"])
                self.assertLess(cpu_res["durationMs"], 6000.0)

                flood_res = validate_execution_result(
                    run_helmctl(
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
                            "2048",
                        ]
                    ).json
                )
                self.assertTrue(flood_res["truncatedOutput"])
                self.assertLessEqual(len(flood_res["stdout"].encode("utf-8")), 2048 + 256)

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])

        time.sleep(0.2)
        post_chrome = _helm_chrome_pids()
        self.assertEqual(post_chrome - pre_chrome, set())

    def test_T4_E2E_07_project_folder_autonomous_discovery_crew_chat_to_output(self) -> None:
        """T4-E2E-07 (R1+R2+R3): Populated project folder -> Crew Chat -> autonomous multi-turn discovery -> live work feed."""
        require_helmctl()
        with TempWorkspace() as ws, FixtureServer() as srv:
            assert ws.ws_path is not None and ws.db_path is not None
            (ws.ws_path / "README.md").write_text("# Harbor Service\nRead config.json for endpoint.\n", encoding="utf-8")
            (ws.ws_path / "config.json").write_text(json.dumps({"service_url": srv.url("/")}), encoding="utf-8")
            (ws.ws_path / "src").mkdir(parents=True, exist_ok=True)
            (ws.ws_path / "src" / "calc.py").write_text("def add(a: int, b: int) -> int:\n    return a + b\n", encoding="utf-8")

            proj = run_helmctl(
                [
                    "project",
                    "create",
                    "--name",
                    "HarborDiscovery",
                    "--goal",
                    "Inspect project folder, verify service, write report.md",
                    "--workspace",
                    str(ws.ws_path),
                ],
                db_path=ws.db_path,
            ).json
            scout = run_helmctl(
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
                    "Discover project files and URLs",
                    "--backend",
                    "http",
                    "--capabilities",
                    "browser,ocr,readSharedState,proposeSharedState",
                ],
                db_path=ws.db_path,
            ).json
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
                    "Write verified report.md and compile src/calc.py",
                    "--backend",
                    "http",
                    "--capabilities",
                    "codeExec,readSharedState,proposeSharedState",
                ],
                db_path=ws.db_path,
            ).json

            # Verify chat CLI exists before starting LLM loop
            run_helmctl_feature(
                ["chat", "list", "--project", proj["id"], "--channel", "crew"],
                db_path=ws.db_path,
                feature_name="chat list",
            )

            target_url = srv.url("/")
            verify_cmd = "test -s src/calc.py && grep -q 'def add' src/calc.py && printf 'CALC_VERIFIED_OK\\n'"

            def responder(req: Dict[str, Any]) -> str:
                transcript = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                exec_transcript = (
                    transcript.split("[Execution Transcript]", 1)[1]
                    if "[Execution Transcript]" in transcript
                    else ""
                )
                calc_verified = (
                    "-> exit 0" in exec_transcript
                    and any(line.strip() == "CALC_VERIFIED_OK" for line in exec_transcript.splitlines())
                )
                if "HARBOR READY" in exec_transcript.upper() and (ws.ws_path / "report.md").is_file() and calc_verified:
                    return json.dumps(
                        {
                            "thought": "finish after verification",
                            "tool_calls": [
                                {"id": "done1", "name": "complete_task", "arguments": {"summary": "Report verified against HARBOR READY and CALC_VERIFIED_OK"}}
                            ],
                        }
                    )
                if "HARBOR READY" in exec_transcript.upper():
                    return json.dumps(
                        {
                            "thought": "write report and verify calc.py",
                            "tool_calls": [
                                {
                                    "id": "w1",
                                    "name": "write_workspace_file",
                                    "arguments": {"path": "report.md", "content": "# Harbor Report\nStatus: HARBOR READY\n"},
                                },
                                {
                                    "id": "cmd1",
                                    "name": "run_command",
                                    "arguments": {"command": verify_cmd},
                                },
                            ],
                        }
                    )
                if target_url in exec_transcript:
                    return json.dumps(
                        {
                            "thought": "browse configured service_url",
                            "tool_calls": [
                                {"id": "b1", "name": "browser_act", "arguments": {"action": "observe", "url": target_url}}
                            ],
                        }
                    )
                if "config.json" in exec_transcript:
                    return json.dumps(
                        {
                            "thought": "read config.json",
                            "tool_calls": [
                                {"id": "r1", "name": "read_workspace_file", "arguments": {"path": "config.json"}}
                            ],
                        }
                    )
                return json.dumps(
                    {
                        "thought": "discover workspace files",
                        "tool_calls": [
                            {"id": "l1", "name": "list_workspace_files", "arguments": {}}
                        ],
                    }
                )

            with LocalLLMServer(responder) as llm, FocusGuard(interval_ms=50) as guard:
                run_helmctl_feature(
                    [
                        "chat",
                        "send",
                        "--project",
                        proj["id"],
                        "--channel",
                        "crew",
                        "--content",
                        "Inspect the project folder, check the configured service, write report.md, and verify src/calc.py.",
                        "--wait",
                    ],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                    timeout=90.0,
                    feature_name="chat send",
                )
                self.assertGreaterEqual(len(llm.requests), 5)

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])

            excs = run_helmctl(["exceptions", "list", "--project", proj["id"], "--open-only"], db_path=ws.db_path).json
            self.assertEqual(excs, [])
            self.assertTrue((ws.ws_path / "report.md").is_file())
            self.assertIn("HARBOR READY", (ws.ws_path / "report.md").read_text(encoding="utf-8"))

            crew_msgs = run_helmctl_feature(
                ["chat", "list", "--project", proj["id"], "--channel", "crew"],
                db_path=ws.db_path,
                feature_name="chat list",
            ).json
            self.assertGreaterEqual(len(crew_msgs), 2)
            for m in crew_msgs:
                validate_chat_message(m)

            feed = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            self.assertGreaterEqual(len(feed), 5)
            for e in feed:
                validate_agent_work_entry(e)
            failed_entries = [e for e in feed if e.get("phase") == "failed"]
            self.assertEqual(failed_entries, [], f"Unexpected failed work-feed entries: {failed_entries!r}")
            observed_tools = {e.get("toolName") for e in feed if e.get("toolName")}
            expected_tools = {
                "list_workspace_files",
                "read_workspace_file",
                "browser_act",
                "write_workspace_file",
                "run_command",
            }
            self.assertTrue(
                expected_tools.issubset(observed_tools),
                f"Expected tools {expected_tools!r} in work-feed, got {observed_tools!r}",
            )

    def test_T4_E2E_08_direct_1on1_chat_with_live_system_prompt_edit(self) -> None:
        """T4-E2E-08 (R1+R4): 1-on-1 direct chat + editable systemPrompt + personality switch across restart."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl(
                ["project", "create", "--name", "E2E08DirectPrompt", "--goal", "Direct chat & prompt editing", "--workspace", str(ws.ws_path)],
                db_path=ws.db_path,
            ).json
            agent = run_helmctl(
                ["agent", "add", "--project", proj["id"], "--name", "Navigator", "--role", "researcher", "--goal", "Assist operator", "--backend", "http"],
                db_path=ws.db_path,
            ).json
            require_feature_field(agent, "systemPrompt", "Editable systemPrompt")

            def responder(req: Dict[str, Any]) -> str:
                sys_text = "\n".join(str(m.get("content", "")) for m in req.get("messages", []) if m.get("role") == "system")
                tag = "PROMPT_V2_ACTIVE" if "PROMPT_V2_ACTIVE" in sys_text else "PROMPT_V1_DEFAULT"
                return json.dumps(
                    {"thought": "reply", "tool_calls": [{"id": "c1", "name": "complete_task", "arguments": {"summary": f"ACK:{tag}"}}]}
                )

            with LocalLLMServer(responder) as llm, FocusGuard(interval_ms=50) as guard:
                run_helmctl_feature(
                    ["chat", "send", "--project", proj["id"], "--channel", f"direct:{agent['id']}", "--content", "First check-in", "--wait"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                    feature_name="chat send",
                )
                run_helmctl_feature(
                    ["agent", "update", "--id", agent["id"], "--system-prompt", "PROMPT_V2_ACTIVE: Always include exact verification files."],
                    db_path=ws.db_path,
                    feature_name="agent update",
                )
                upd = run_helmctl_feature(
                    ["agent", "update", "--id", agent["id"], "--personality", "methodicalArchitect"],
                    db_path=ws.db_path,
                    feature_name="agent update",
                ).json
                self.assertIn("PROMPT_V2_ACTIVE", upd["systemPrompt"])
                run_helmctl_feature(
                    ["chat", "send", "--project", proj["id"], "--channel", f"direct:{agent['id']}", "--content", "Second check-in", "--wait"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                    feature_name="chat send",
                )

                self.assertGreaterEqual(len(llm.requests), 2)
                last_sys = "\n".join(
                    str(m.get("content", "")) for m in llm.requests[-1].get("messages", []) if m.get("role") == "system"
                )
                self.assertIn("PROMPT_V2_ACTIVE", last_sys)

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])

            crew_msgs = run_helmctl_feature(
                ["chat", "list", "--project", proj["id"], "--channel", "crew"],
                db_path=ws.db_path,
                feature_name="chat list",
            ).json
            self.assertEqual(crew_msgs, [])

            expected_channel = f"agent:{agent['id']}"
            direct_msgs = run_helmctl_feature(
                ["chat", "list", "--project", proj["id"], "--channel", f"direct:{agent['id']}"],
                db_path=ws.db_path,
                feature_name="chat list",
            ).json
            self.assertEqual(len(direct_msgs), 4)
            for m in direct_msgs:
                validate_chat_message(m)
                self.assertEqual(m["channelKey"], expected_channel)
            user_contents = [m["content"] for m in direct_msgs if m["senderKind"] == "user"]
            agent_replies = [m for m in direct_msgs if m["senderKind"] == "agent"]
            self.assertEqual(user_contents, ["First check-in", "Second check-in"])
            self.assertEqual([r["content"] for r in agent_replies], ["ACK:PROMPT_V1_DEFAULT", "ACK:PROMPT_V2_ACTIVE"])
            self.assertTrue(all(r.get("senderAgentID") == agent["id"] for r in agent_replies))

            listed_agents = run_helmctl(["agent", "list", "--project", proj["id"]], db_path=ws.db_path).json
            self.assertEqual(len(listed_agents), 1)
            self.assertEqual(listed_agents[0]["id"], agent["id"])
            self.assertEqual(
                listed_agents[0]["systemPrompt"],
                "PROMPT_V2_ACTIVE: Always include exact verification files.",
            )
            self.assertEqual(listed_agents[0]["personality"], "methodicalArchitect")

            templated = run_helmctl_feature(
                ["agent", "update", "--id", agent["id"], "--personality", "rapidOperator", "--apply-template"],
                db_path=ws.db_path,
                feature_name="agent update --apply-template",
            ).json
            self.assertEqual(templated["personality"], "rapidOperator")
            self.assertNotIn("PROMPT_V2_ACTIVE", templated["systemPrompt"])
            self.assertIn("Rapid Operator", templated["systemPrompt"])

            custom_after = run_helmctl_feature(
                ["agent", "update", "--id", agent["id"], "--system-prompt", "PROMPT_V3_CUSTOM: Editable after template."],
                db_path=ws.db_path,
                feature_name="agent update",
            ).json
            self.assertEqual(custom_after["systemPrompt"], "PROMPT_V3_CUSTOM: Editable after template.")

            persisted_after = run_helmctl(["agent", "list", "--project", proj["id"]], db_path=ws.db_path).json
            self.assertEqual(persisted_after[0]["personality"], "rapidOperator")
            self.assertEqual(persisted_after[0]["systemPrompt"], "PROMPT_V3_CUSTOM: Editable after template.")

    def test_T4_E2E_09_multi_agent_work_feed_tasks_and_trust_policy_lifecycle(self) -> None:
        """T4-E2E-09 (R2+R3+R4): 4-agent DAG + transient malformed JSON self-correction + work-feed + tasks + SandboxTrustPolicy."""
        require_helmctl()
        with TempWorkspace() as ws:
            assert ws.root is not None and ws.ws_path is not None and ws.db_path is not None
            proj = run_helmctl_feature(
                [
                    "project",
                    "create",
                    "--name",
                    "E2E09MultiDAG",
                    "--goal",
                    "Execute 4-agent DAG and audit work-feed + trust policy",
                    "--workspace",
                    str(ws.ws_path),
                    "--trust-policy",
                    "sandboxed",
                ],
                db_path=ws.db_path,
                feature_name="project create --trust-policy",
            ).json
            require_feature_field(proj, "sandboxTrustPolicy", "Project sandboxTrustPolicy")
            if proj.get("sandboxTrustPolicy") != "sandboxed":
                # Probe M2 project update-trust CLI surface so pre-M2 skips cleanly while post-M2 verifies --trust-policy
                run_helmctl_feature(
                    ["project", "update-trust", "--id", proj["id"], "--trust-policy", "sandboxed"],
                    db_path=ws.db_path,
                    feature_name="project create --trust-policy",
                )
            validate_project_trust_policy(proj, expected="sandboxed")
            upd_std = run_helmctl_feature(
                ["project", "update-trust", "--id", proj["id"], "--trust-policy", "standardWorkspace"],
                db_path=ws.db_path,
                feature_name="project update-trust",
            ).json
            validate_project_trust_policy(upd_std, expected="standardWorkspace")

            a_compass = run_helmctl(
                ["agent", "add", "--project", proj["id"], "--name", "Compass", "--role", "researcher", "--goal", "Analyze", "--backend", "http"],
                db_path=ws.db_path,
            ).json
            a_chart = run_helmctl(
                ["agent", "add", "--project", proj["id"], "--name", "Chart", "--role", "specialist", "--goal", "Plan", "--backend", "http"],
                db_path=ws.db_path,
            ).json
            a_forge = run_helmctl(
                ["agent", "add", "--project", proj["id"], "--name", "Forge", "--role", "coder", "--goal", "Build", "--backend", "http", "--capabilities", "codeExec,readSharedState,proposeSharedState"],
                db_path=ws.db_path,
            ).json
            a_lookout = run_helmctl(
                ["agent", "add", "--project", proj["id"], "--name", "Lookout", "--role", "qa", "--goal", "Verify", "--backend", "http"],
                db_path=ws.db_path,
            ).json

            chart_fault_injected = {"done": False}

            def responder(req: Dict[str, Any]) -> str:
                joined = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                if "DECOMPOSE_GOAL" in joined:
                    return json.dumps(
                        {
                            "tasks": [
                                {"temp_id": "t1", "title": "CompassAnalyze", "instructions": "STEP_COMPASS", "assigned_agent_id": a_compass["id"], "waiting_on_temp_ids": []},
                                {"temp_id": "t2", "title": "ChartPlan", "instructions": "STEP_CHART", "assigned_agent_id": a_chart["id"], "waiting_on_temp_ids": []},
                                {"temp_id": "t3", "title": "ForgeBuild", "instructions": "STEP_FORGE", "assigned_agent_id": a_forge["id"], "waiting_on_temp_ids": ["t1", "t2"]},
                                {"temp_id": "t4", "title": "LookoutVerify", "instructions": "STEP_LOOKOUT", "assigned_agent_id": a_lookout["id"], "waiting_on_temp_ids": ["t3"]},
                            ]
                        }
                    )
                if "STEP_CHART" in joined and not chart_fault_injected["done"]:
                    chart_fault_injected["done"] = True
                    return "{broken json transient fault"
                if "STEP_FORGE" in joined and not (ws.ws_path / "built.txt").is_file():
                    return json.dumps(
                        {"thought": "write built.txt", "tool_calls": [{"id": "w1", "name": "write_workspace_file", "arguments": {"path": "built.txt", "content": "DAG_BUILT_OK"}}]}
                    )
                return json.dumps(
                    {"thought": "complete", "tool_calls": [{"id": "ok", "name": "complete_task", "arguments": {"summary": "STAGE_COMPLETE"}}]}
                )

            with LocalLLMServer(responder) as llm, FocusGuard(interval_ms=50) as guard:
                rep = run_helmctl(
                    ["run", "--project", proj["id"], "--max-steps", "20"],
                    db_path=ws.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                    timeout=60.0,
                ).json

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(rep["status"], "completed")
            self.assertTrue(chart_fault_injected["done"], "Expected transient malformed JSON fault to trigger")
            self.assertTrue((ws.ws_path / "built.txt").is_file())
            self.assertEqual((ws.ws_path / "built.txt").read_text(encoding="utf-8"), "DAG_BUILT_OK")

            tasks = run_helmctl_feature(
                ["tasks", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="tasks list",
            ).json
            self.assertEqual(len(tasks), 4)
            self.assertTrue(all(t["status"] == "done" for t in tasks))
            by_title = {t["title"]: t for t in tasks}
            self.assertEqual(set(by_title.keys()), {"CompassAnalyze", "ChartPlan", "ForgeBuild", "LookoutVerify"})
            t_compass = by_title["CompassAnalyze"]
            t_chart = by_title["ChartPlan"]
            t_forge = by_title["ForgeBuild"]
            t_lookout = by_title["LookoutVerify"]
            self.assertEqual(t_compass["assignedAgentID"], a_compass["id"])
            self.assertEqual(t_compass["waitingOn"], [])
            self.assertEqual(t_chart["assignedAgentID"], a_chart["id"])
            self.assertEqual(t_chart["waitingOn"], [])
            self.assertEqual(t_forge["assignedAgentID"], a_forge["id"])
            self.assertEqual(set(t_forge["waitingOn"]), {t_compass["id"], t_chart["id"]})
            self.assertEqual(t_lookout["assignedAgentID"], a_lookout["id"])
            self.assertEqual(t_lookout["waitingOn"], [t_forge["id"]])

            feed = run_helmctl_feature(
                ["work-feed", "list", "--project", proj["id"]],
                db_path=ws.db_path,
                feature_name="work-feed list",
            ).json
            for e in feed:
                validate_agent_work_entry(e)
            feed_agents = {e["agentID"] for e in feed}
            for ag in (a_compass, a_chart, a_forge, a_lookout):
                self.assertIn(ag["id"], feed_agents)
            chart_phases = [e["phase"] for e in feed if e["agentID"] == a_chart["id"]]
            self.assertIn("failed", chart_phases)
            self.assertIn("completed", chart_phases)
            forge_edits = [
                e for e in feed
                if e["agentID"] == a_forge["id"] and e.get("phase") == "fileEdit"
            ]
            self.assertTrue(
                any(e.get("touchedFiles") == ["built.txt"] for e in forge_edits),
                f"Expected Forge fileEdit touching built.txt in {forge_edits!r}",
            )

            # Switch to sandboxed and verify outside-workspace write fails
            upd = run_helmctl_feature(
                ["project", "update-trust", "--id", proj["id"], "--trust-policy", "sandboxed"],
                db_path=ws.db_path,
                feature_name="project update-trust",
            ).json
            validate_project_trust_policy(upd, expected="sandboxed")
            outside = ws.root / "blocked_e2e09.txt"
            sb = validate_execution_result(
                run_helmctl(
                    [
                        "sandbox",
                        "exec",
                        "--workspace",
                        str(ws.ws_path),
                        "--cmd",
                        f"echo fail > '{outside}'",
                        "--mode",
                        "seatbelt",
                        "--project",
                        proj["id"],
                    ]
                ).json
            )
            self.assertNotEqual(sb["exitCode"], 0)
            self.assertFalse(outside.exists())

        # Real helmctl run SandboxTrustPolicy enforcement:
        # .sandboxed blocks run_command for agent lacking codeExec (drift hold),
        # while .standardWorkspace executes it cleanly.
        with TempWorkspace() as ws_sb, TempWorkspace() as ws_std:
            assert ws_sb.ws_path is not None and ws_sb.db_path is not None
            assert ws_std.ws_path is not None and ws_std.db_path is not None
            p_sb = run_helmctl_feature(
                [
                    "project",
                    "create",
                    "--name",
                    "E2E09PolicySandboxed",
                    "--goal",
                    "Verify sandboxed blocks unauthorized run_command",
                    "--workspace",
                    str(ws_sb.ws_path),
                    "--trust-policy",
                    "sandboxed",
                ],
                db_path=ws_sb.db_path,
                feature_name="project create --trust-policy",
            ).json
            ag_sb = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    p_sb["id"],
                    "--name",
                    "NoExecSandboxed",
                    "--role",
                    "researcher",
                    "--goal",
                    "Probe run_command under sandboxed",
                    "--backend",
                    "http",
                    "--capabilities",
                    "readSharedState,proposeSharedState",
                ],
                db_path=ws_sb.db_path,
            ).json

            p_std = run_helmctl_feature(
                [
                    "project",
                    "create",
                    "--name",
                    "E2E09PolicyStandard",
                    "--goal",
                    "Verify standardWorkspace permits run_command without codeExec",
                    "--workspace",
                    str(ws_std.ws_path),
                    "--trust-policy",
                    "standardWorkspace",
                ],
                db_path=ws_std.db_path,
                feature_name="project create --trust-policy",
            ).json
            ag_std = run_helmctl(
                [
                    "agent",
                    "add",
                    "--project",
                    p_std["id"],
                    "--name",
                    "NoExecStandard",
                    "--role",
                    "researcher",
                    "--goal",
                    "Probe run_command under standardWorkspace",
                    "--backend",
                    "http",
                    "--capabilities",
                    "readSharedState,proposeSharedState",
                ],
                db_path=ws_std.db_path,
            ).json

            def policy_responder(req: Dict[str, Any]) -> str:
                joined = "\n".join(str(m.get("content", "")) for m in req.get("messages", []))
                if "DECOMPOSE_GOAL" in joined:
                    target_ag = ag_sb["id"] if ag_sb["id"] in joined else ag_std["id"]
                    return json.dumps(
                        {
                            "tasks": [
                                {
                                    "temp_id": "tp1",
                                    "title": "PolicyRunCmd",
                                    "instructions": "POLICY_PROBE_CMD",
                                    "assigned_agent_id": target_ag,
                                    "waiting_on_temp_ids": [],
                                }
                            ]
                        }
                    )
                exec_tail = (
                    joined.split("[Execution Transcript]", 1)[1]
                    if "[Execution Transcript]" in joined
                    else ""
                )
                if "-> exit 0" in exec_tail and any(line.strip() == "POLICY_RUN_OK" for line in exec_tail.splitlines()):
                    return json.dumps(
                        {"thought": "done", "tool_calls": [{"id": "pd1", "name": "complete_task", "arguments": {"summary": "POLICY_CMD_OK"}}]}
                    )
                return json.dumps(
                    {
                        "thought": "run command probe",
                        "tool_calls": [
                            {"id": "pc1", "name": "run_command", "arguments": {"command": "printf 'POLICY_RUN_OK' > policy_probe.txt && printf 'POLICY_RUN_OK\\n'"}}
                        ],
                    }
                )

            with LocalLLMServer(policy_responder) as llm, FocusGuard(interval_ms=50) as guard:
                rep_sb = run_helmctl(
                    ["run", "--project", p_sb["id"], "--max-steps", "4"],
                    db_path=ws_sb.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                    timeout=30.0,
                ).json
                rep_std = run_helmctl(
                    ["run", "--project", p_std["id"], "--max-steps", "6"],
                    db_path=ws_std.db_path,
                    env={"HELM_LLM_BASE_URL": llm.base_url},
                    timeout=60.0,
                ).json

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(rep_sb["status"], "held")
            self.assertTrue(
                any(exc.get("kind") == "drift" for exc in rep_sb.get("exceptions", [])),
                f"Expected drift exception under sandboxed policy, got {rep_sb.get('exceptions')!r}",
            )
            self.assertFalse((ws_sb.ws_path / "policy_probe.txt").exists())

            self.assertEqual(rep_std["status"], "completed")
            self.assertEqual(rep_std.get("exceptions", []), [])
            self.assertEqual((ws_std.ws_path / "policy_probe.txt").read_text(encoding="utf-8"), "POLICY_RUN_OK")

    def test_T4_E2E_10_repo_privacy_hygiene_and_tracked_tree_audit(self) -> None:
        """T4-E2E-10 (R5 Privacy): Full tracked-tree & git diff HEAD privacy, secret, and brand hygiene audit."""
        ls_proc = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=10.0,
            check=True,
        )
        tracked_files = [line.strip() for line in ls_proc.stdout.splitlines() if line.strip()]

        # 1. No .agents/ or secret key extensions tracked; .gitignore covers sensitive outputs
        self.assertEqual([f for f in tracked_files if f.startswith(".agents/")], [])
        self.assertEqual(
            [f for f in tracked_files if f.endswith((".p8", ".p12", ".mobileprovision", ".pem", ".key"))],
            [],
        )
        gi = (REPO_ROOT / ".gitignore").read_text(encoding="utf-8")
        for pat in (".agents/", "e2e/.reports/", "e2e/.tmp/", "*.sqlite", ".env"):
            self.assertIn(pat, gi)

        # 2. Scan all tracked text files (dynamically built patterns to avoid self-matching)
        local_user_re = re.compile(r"/" + "User" + r"s/[A-Za-z0-9._-]+/")
        secret_re = re.compile(
            "("
            + "sk-" + r"ant-[A-Za-z0-9_-]{10,}|"
            + "sk-" + r"proj-[A-Za-z0-9_-]{10,}|"
            + "sk-" + r"[A-Za-z0-9]{20,}|"
            + "AI" + r"za[0-9A-Za-z_-]{35}|"
            + "xox" + r"[baprs]-[A-Za-z0-9-]{10,}|"
            + "gh" + r"p_[A-Za-z0-9]{20,}|"
            + "gh" + r"o_[A-Za-z0-9]{20,}|"
            + "github_" + r"pat_[A-Za-z0-9_]{20,}|"
            + "AK" + r"IA[0-9A-Z]{16}|"
            + r"-----BEGIN (RSA |EC |OPENSSH |PGP |)PRIVATE KEY-----"
            + ")"
        )
        team_re = re.compile(
            r"(" + "DEVELOPMENT_" + r"TEAM\s*[:=]\s*[A-Z0-9]{10}|" + "Team" + r"Identifier[^A-Za-z0-9]*[A-Z0-9]{10})"
        )
        email_re = re.compile(
            r"[A-Za-z0-9._%+-]+@(" + "gm" + r"ail|" + "ic" + r"loud|" + "yah" + r"oo|" + "hot" + r"mail|" + "proton" + r"mail)\.[a-z]{2,}",
            re.IGNORECASE,
        )
        ref_re = re.compile(
            "(" + "uploaded_" + "media_" + "|" + "500c71c6-" + "19da-4f8b-a193-8e57bbffdf0a" + ")"
        )
        banned_re = re.compile(
            "(" + r"\.her" + "mes|" + "hermes" + r"-agent|" + "nous" + "research|" + r"(?<!an)tig" + "ravity)",
            re.IGNORECASE,
        )
        personal_id_re = re.compile("sushil" + r"k1991", re.IGNORECASE)
        allowed_updater_files = {
            "README.md",
            "Sources/HelmApp/App/AppUpdateManager.swift",
            "Tests/HelmAppTests/HelmAppTier5Tests.swift",
        }

        findings: List[str] = []
        for rel in tracked_files:
            p = REPO_ROOT / rel
            if not p.is_file() or p.suffix.lower() in {".png", ".icns", ".jpg", ".jpeg", ".pdf"}:
                continue
            text = p.read_text(encoding="utf-8", errors="ignore")
            for idx, line in enumerate(text.splitlines(), 1):
                if local_user_re.search(line):
                    findings.append(f"{rel}:{idx}:local_user_path")
                if secret_re.search(line):
                    findings.append(f"{rel}:{idx}:secret")
                if team_re.search(line):
                    findings.append(f"{rel}:{idx}:team_id")
                if email_re.search(line):
                    findings.append(f"{rel}:{idx}:personal_email")
                if ref_re.search(line):
                    findings.append(f"{rel}:{idx}:ref_screenshot_path")
                if banned_re.search(line):
                    findings.append(f"{rel}:{idx}:banned_third_party_name")
                if personal_id_re.search(line):
                    if not (
                        rel in allowed_updater_files
                        and ("github.com/" in line or "api.github.com/repos/" in line)
                    ):
                        findings.append(f"{rel}:{idx}:unexpected_personal_id")

        # 3. Scan uncommitted/staged git diff HEAD added lines strictly
        diff_proc = subprocess.run(
            ["git", "diff", "HEAD"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=10.0,
            check=True,
        )
        current_diff_file: Optional[str] = None
        for idx, line in enumerate(diff_proc.stdout.splitlines(), 1):
            if line.startswith("+++ "):
                path_part = line[4:].strip()
                current_diff_file = path_part[2:] if path_part.startswith("b/") else None
                continue
            if line.startswith("+"):
                added = line[1:]
                if (
                    local_user_re.search(added)
                    or secret_re.search(added)
                    or team_re.search(added)
                    or email_re.search(added)
                    or ref_re.search(added)
                    or banned_re.search(added)
                ):
                    findings.append(
                        f"git_diff_head:{current_diff_file or 'unknown'}:{idx}:privacy_violation"
                    )
                elif personal_id_re.search(added):
                    if not (
                        current_diff_file in allowed_updater_files
                        and ("github.com/" in added or "api.github.com/repos/" in added)
                    ):
                        findings.append(
                            f"git_diff_head:{current_diff_file or 'unknown'}:{idx}:unexpected_personal_id"
                        )

        self.assertEqual(findings, [], f"Privacy hygiene audit failed: {findings}")


if __name__ == "__main__":
    raise SystemExit(run_tier_module_cli("4"))
