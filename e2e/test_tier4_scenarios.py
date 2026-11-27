#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List, Set

from e2e_common import (
    E2ETestCase,
    FocusGuard,
    REPORTS_DIR,
    TempWorkspace,
    find_helm_app_bundle,
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
    if reduce_motion:
        env["HELM_REDUCE_MOTION"] = "1"

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

            with FocusGuard(interval_ms=50) as guard:
                rc1, _, err1 = _run_headless_app(app_exe, std_dir, reduce_motion=False)
                rc2, _, err2 = _run_headless_app(app_exe, rm_dir, reduce_motion=True)

            assert guard.result is not None
            self.assertFalse(guard.result["focusChanged"])
            self.assertFalse(guard.result["cursorMoved"])
            self.assertEqual(rc1, 0, err1)
            self.assertEqual(rc2, 0, err2)

            std_pngs = sorted(std_dir.rglob("*.png"))
            rm_pngs = sorted(rm_dir.rglob("*.png"))
            light = [p for p in std_pngs if "light" in p.name.lower()]
            dark = [p for p in std_pngs if "dark" in p.name.lower()]
            steady = [p for p in std_pngs if any(k in p.name.lower() for k in ("steady", "calm", "normal"))]
            exc = [p for p in std_pngs if any(k in p.name.lower() for k in ("exception", "alert", "held"))]

            self.assertGreaterEqual(len(light), 1)
            self.assertGreaterEqual(len(dark), 1)
            self.assertGreaterEqual(len(steady), 1)
            self.assertGreaterEqual(len(exc), 1)
            self.assertGreaterEqual(len(rm_pngs), 1)

            light_info = inspect_png(light[0])
            dark_info = inspect_png(dark[0])
            steady_info = inspect_png(steady[0])
            exc_info = inspect_png(exc[0])

            for info in (light_info, dark_info, steady_info, exc_info):
                self.assertGreaterEqual(info["width"], 900)
                self.assertGreaterEqual(info["height"], 600)
                self.assertFalse(info["is_uniform"])

            self.assertGreater(light_info["mean_luminance"], dark_info["mean_luminance"])
            self.assertNotEqual(steady_info["pixel_sha256"], exc_info["pixel_sha256"])

            # Export snapshot bundle for M5 impeccable visual rubric inspection
            export_dir = REPORTS_DIR / "impeccable_snapshots"
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


if __name__ == "__main__":
    raise SystemExit(run_tier_module_cli("4"))
