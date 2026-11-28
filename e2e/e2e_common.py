#!/usr/bin/env python3
from __future__ import annotations

import argparse
import binascii
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zlib
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple, Union

E2E_DIR = Path(__file__).resolve().parent
REPO_ROOT = E2E_DIR.parent
BIN_DIR = E2E_DIR / ".bin"
REPORTS_DIR = E2E_DIR / ".reports"
TMP_ROOT = E2E_DIR / ".tmp"
FOCUS_PROBE_BIN = BIN_DIR / "focus_probe"

UUID_OR_NONEMPTY_STR = (str,)
STATEFUL_SUBCOMMANDS = frozenset(
    {"project", "agent", "run", "exceptions", "state", "chat", "work-feed", "tasks"}
)
VALID_ISOLATION_MODES = frozenset({"virtualizationVM", "seatbeltSandbox"})
VALID_TRUST_POLICIES = frozenset({"sandboxed", "standardWorkspace", "trustedFullAccess"})
VALID_CHAT_SENDER_KINDS = frozenset({"user", "agent", "orchestrator", "system"})
VALID_WORK_PHASES = frozenset(
    {"planning", "reasoning", "toolCall", "fileEdit", "completed", "failed"}
)
PENDING_FEATURE_SUBCOMMANDS = frozenset({"chat", "work-feed", "tasks"})
PENDING_FEATURE_FLAGS = frozenset(
    {"--trust-policy", "--system-prompt", "--personality", "--apply-template"}
)

TIER_MODULES: Dict[str, str] = {
    "0": "test_tier0_harness",
    "1": "test_tier1_features",
    "2": "test_tier2_boundaries",
    "3": "test_tier3_pairwise",
    "4": "test_tier4_scenarios",
    "5": "test_tier5_adversarial",
}


class UnbuiltTargetSkip(unittest.SkipTest):
    """Distinct skip exception for unbuilt product binaries or VM assets."""

    def __init__(self, reason: str) -> None:
        if not reason.startswith("[SKIP_UNBUILT]"):
            reason = f"[SKIP_UNBUILT] {reason}"
        super().__init__(reason)


class HelmCLIError(RuntimeError):
    """Raised when a helmctl subprocess fails or emits invalid JSON."""

    def __init__(
        self,
        message: str,
        *,
        returncode: Optional[int] = None,
        stdout: str = "",
        stderr: str = "",
        command: Optional[Sequence[str]] = None,
    ) -> None:
        super().__init__(message)
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.command = list(command) if command else []


@dataclass
class CLIResult:
    returncode: int
    stdout: str
    stderr: str
    json: Any
    duration_ms: float
    command: List[str]


def _is_executable_file(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def find_helmctl() -> Optional[Path]:
    env_bin = os.environ.get("HELMCTL_BIN")
    if env_bin is not None and env_bin.strip() != "":
        candidate = Path(env_bin).expanduser()
        if _is_executable_file(candidate):
            return candidate
        return None
    candidates = [
        REPO_ROOT / ".build" / "arm64-apple-macosx" / "debug" / "helmctl",
        REPO_ROOT / ".build" / "debug" / "helmctl",
        REPO_ROOT / ".build" / "arm64-apple-macosx" / "release" / "helmctl",
        REPO_ROOT / ".build" / "release" / "helmctl",
    ]
    for candidate in candidates:
        if _is_executable_file(candidate):
            return candidate
    return None


def _normalize_app_executable(candidate: Path) -> Optional[Path]:
    if candidate.is_dir() and candidate.name.endswith(".app"):
        exe = candidate / "Contents" / "MacOS" / "Helm"
        if _is_executable_file(exe):
            return exe
        macos_dir = candidate / "Contents" / "MacOS"
        if macos_dir.is_dir():
            for child in macos_dir.iterdir():
                if _is_executable_file(child):
                    return child
        return None
    if _is_executable_file(candidate):
        return candidate
    return None


def find_helm_app() -> Optional[Path]:
    env_app = os.environ.get("HELM_APP_PATH")
    if env_app is not None and env_app.strip() != "":
        return _normalize_app_executable(Path(env_app).expanduser())

    candidates = [
        REPO_ROOT / "build" / "Helm.app",
        REPO_ROOT / "build" / "Build" / "Products" / "Debug" / "Helm.app",
        REPO_ROOT / "build" / "Build" / "Products" / "Release" / "Helm.app",
        REPO_ROOT / ".build" / "DerivedDataXcode" / "Build" / "Products" / "Debug" / "Helm.app",
        REPO_ROOT / ".build" / "DerivedDataXcode" / "Build" / "Products" / "Release" / "Helm.app",
        REPO_ROOT / ".build" / "Helm.app",
    ]
    for candidate in candidates:
        resolved = _normalize_app_executable(candidate)
        if resolved is not None:
            return resolved
    return None


def find_helm_app_bundle() -> Optional[Path]:
    exe = find_helm_app()
    if exe is None:
        return None
    for parent in exe.parents:
        if parent.name.endswith(".app"):
            return parent
    return None


def find_vm_assets() -> Optional[Dict[str, Path]]:
    env_kernel = os.environ.get("HELM_VM_KERNEL")
    env_initrd = os.environ.get("HELM_VM_INITRAMFS")
    kernel_set = env_kernel is not None and env_kernel.strip() != ""
    initrd_set = env_initrd is not None and env_initrd.strip() != ""
    if kernel_set or initrd_set:
        if not (kernel_set and initrd_set):
            return None
        assert env_kernel is not None and env_initrd is not None
        kp = Path(env_kernel).expanduser()
        ip = Path(env_initrd).expanduser()
        if kp.is_file() and ip.is_file():
            return {"kernel": kp, "initramfs": ip}
        return None

    search_dirs = [
        Path.home() / "Library" / "Caches" / "Helm" / "vm",
        Path.home() / "Library" / "Application Support" / "Helm" / "vm",
        REPO_ROOT / "Resources" / "vm",
        REPO_ROOT / ".cache" / "vm",
    ]
    for base in search_dirs:
        for k_name, i_name in (
            ("vmlinuz-virt", "initramfs-virt"),
            ("vmlinuz", "initramfs"),
        ):
            kp = base / k_name
            ip = base / i_name
            if kp.is_file() and ip.is_file():
                return {"kernel": kp, "initramfs": ip}

    if os.environ.get("HELM_E2E_VM_READY") == "1":
        return {"env_flag": Path("HELM_E2E_VM_READY")}
    return None


def require_helmctl() -> Path:
    path = find_helmctl()
    if path is None:
        raise UnbuiltTargetSkip("helmctl binary not built yet")
    return path


def require_helm_app() -> Path:
    path = find_helm_app()
    if path is None:
        raise UnbuiltTargetSkip("Helm.app bundle not built yet")
    return path


def require_vm_assets() -> Dict[str, Path]:
    assets = find_vm_assets()
    if assets is None:
        raise UnbuiltTargetSkip(
            "Alpine ARM64 VM kernel/initramfs assets not present (set HELM_E2E_VM_READY=1 or cache vmlinuz-virt/initramfs-virt)"
        )
    return assets


def require_focus_probe() -> Path:
    if not _is_executable_file(FOCUS_PROBE_BIN):
        raise RuntimeError(
            f"focus_probe binary missing or not executable at {FOCUS_PROBE_BIN}. "
            "Compile with: swiftc -O e2e/focus_probe.swift -o e2e/.bin/focus_probe"
        )
    return FOCUS_PROBE_BIN


def _ensure_tmp_root() -> Path:
    TMP_ROOT.mkdir(parents=True, exist_ok=True)
    return TMP_ROOT


class TempWorkspace:
    """Isolated per-test temporary directory, workspace, and SQLite DB path."""

    def __init__(self, prefix: str = "helm_ws_") -> None:
        self.prefix = prefix
        self.root: Optional[Path] = None
        self.ws_path: Optional[Path] = None
        self.db_path: Optional[Path] = None
        self.artifacts_dir: Optional[Path] = None

    def __enter__(self) -> "TempWorkspace":
        base = _ensure_tmp_root()
        self.root = Path(tempfile.mkdtemp(prefix=self.prefix, dir=str(base)))
        self.ws_path = self.root / "workspace"
        self.ws_path.mkdir(parents=True, exist_ok=True)
        self.artifacts_dir = self.root / "artifacts"
        self.artifacts_dir.mkdir(parents=True, exist_ok=True)
        self.db_path = self.root / "helm_test.sqlite"
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        if self.root is not None and self.root.exists():
            shutil.rmtree(self.root, ignore_errors=True)


def validate_probe_report(
    report: Dict[str, Any], *, strict_cursor: bool = True
) -> List[str]:
    """Validate a focus_probe JSON report and return any invariance violations."""
    violations: List[str] = []
    required_keys = (
        "sampleCount",
        "initial",
        "final",
        "cursorDeltaCG",
        "cursorDeltaNS",
        "maxCursorDeltaCG",
        "maxCursorDeltaNS",
        "cursorMoved",
        "focusChanged",
        "activationEvents",
    )
    for key in required_keys:
        if key not in report:
            violations.append(f"focus_probe report missing key '{key}'")
    if violations:
        return violations

    if int(report["sampleCount"]) < 2:
        violations.append(
            f"focus_probe sampleCount={report['sampleCount']} < 2 (insufficient sampling)"
        )

    initial = report["initial"]
    final = report["final"]
    activations = report.get("activationEvents") or []

    if (
        bool(report["focusChanged"])
        or final.get("processIdentifier") != initial.get("processIdentifier")
        or final.get("bundleIdentifier") != initial.get("bundleIdentifier")
        or len(activations) > 0
    ):
        violations.append(
            "Host window focus changed during headless operation: "
            f"initial={initial.get('bundleIdentifier')}(pid={initial.get('processIdentifier')}), "
            f"final={final.get('bundleIdentifier')}(pid={final.get('processIdentifier')}), "
            f"activations={activations}"
        )

    if strict_cursor:
        max_cg = report["maxCursorDeltaCG"]
        max_ns = report["maxCursorDeltaNS"]
        cg_moved = (
            abs(float(max_cg.get("dx", 0.0))) > 0.0
            or abs(float(max_cg.get("dy", 0.0))) > 0.0
        )
        ns_moved = (
            abs(float(max_ns.get("dx", 0.0))) > 0.0
            or abs(float(max_ns.get("dy", 0.0))) > 0.0
        )
        if bool(report["cursorMoved"]) or cg_moved or ns_moved:
            violations.append(
                "Host cursor moved during headless operation: "
                f"maxCursorDeltaCG={max_cg}, maxCursorDeltaNS={max_ns}, "
                f"cursorDeltaCG={report['cursorDeltaCG']}, cursorDeltaNS={report['cursorDeltaNS']}"
            )

    if report.get("invarianceBroken") is True and (
        strict_cursor or not bool(report.get("cursorMoved"))
    ):
        violations.append(
            "focus_probe reported invarianceBroken=true "
            f"(cursorMoved={report.get('cursorMoved')}, focusChanged={report.get('focusChanged')})"
        )

    return violations


class FocusGuard:
    """Context manager running focus_probe continuously around a test block."""

    def __init__(
        self,
        interval_ms: int = 50,
        strict_cursor: Optional[bool] = None,
        ready_timeout: float = 3.0,
        stop_timeout: float = 5.0,
    ) -> None:
        self.interval_ms = interval_ms
        if strict_cursor is None:
            env_cursor = os.environ.get("HELM_STRICT_CURSOR")
            if env_cursor is not None:
                self.strict_cursor = env_cursor.strip().lower() not in {"0", "false", "no"}
            else:
                self.strict_cursor = True
        else:
            self.strict_cursor = strict_cursor
        self.ready_timeout = ready_timeout
        self.stop_timeout = stop_timeout
        self._tmp_dir: Optional[Path] = None
        self._proc: Optional[subprocess.Popen[str]] = None
        self._out_path: Optional[Path] = None
        self._ready_path: Optional[Path] = None
        self.result: Optional[Dict[str, Any]] = None

    def __enter__(self) -> "FocusGuard":
        probe_bin = require_focus_probe()
        base = _ensure_tmp_root()
        self._tmp_dir = Path(tempfile.mkdtemp(prefix="focus_guard_", dir=str(base)))
        self._out_path = self._tmp_dir / "probe_report.json"
        self._ready_path = self._tmp_dir / "probe.ready"

        cmd = [
            str(probe_bin),
            "--watch",
            "--interval-ms",
            str(self.interval_ms),
            "--out",
            str(self._out_path),
            "--ready-file",
            str(self._ready_path),
        ]
        self._proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        deadline = time.monotonic() + self.ready_timeout
        while time.monotonic() < deadline:
            if self._ready_path.is_file():
                return self
            if self._proc.poll() is not None:
                stdout, stderr = self._proc.communicate(timeout=1.0)
                shutil.rmtree(self._tmp_dir, ignore_errors=True)
                self._tmp_dir = None
                raise RuntimeError(
                    f"focus_probe exited prematurely ({self._proc.returncode}): "
                    f"stdout={stdout!r} stderr={stderr!r}"
                )
            time.sleep(0.02)

        self._terminate_proc()
        shutil.rmtree(self._tmp_dir, ignore_errors=True)
        self._tmp_dir = None
        raise TimeoutError("Timed out waiting for focus_probe --ready-file")

    def _terminate_proc(self) -> Tuple[Optional[int], str, str]:
        if self._proc is None:
            return None, "", ""
        if self._proc.poll() is None:
            self._proc.send_signal(signal.SIGTERM)
            try:
                stdout, stderr = self._proc.communicate(timeout=self.stop_timeout)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                stdout, stderr = self._proc.communicate(timeout=2.0)
        else:
            stdout, stderr = self._proc.communicate(timeout=1.0)
        return self._proc.returncode, stdout, stderr

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        try:
            rc, stdout, stderr = self._terminate_proc()
            if self._out_path is not None and self._out_path.is_file():
                self.result = json.loads(self._out_path.read_text(encoding="utf-8"))
            elif exc_type is None:
                raise RuntimeError(
                    f"focus_probe failed to emit output JSON (rc={rc}): "
                    f"stdout={stdout!r} stderr={stderr!r}"
                )
        finally:
            if self._tmp_dir is not None and self._tmp_dir.exists():
                shutil.rmtree(self._tmp_dir, ignore_errors=True)
                self._tmp_dir = None

        if self.result is not None and exc_type is None:
            violations = validate_probe_report(
                self.result, strict_cursor=self.strict_cursor
            )
            if violations:
                raise AssertionError(
                    "Host invariance violation(s):\n- " + "\n- ".join(violations)
                )


def run_helmctl(
    args: Sequence[str],
    *,
    db_path: Optional[Union[Path, str]] = None,
    timeout: float = 60.0,
    expect_json: bool = True,
    env: Optional[Dict[str, str]] = None,
    check: bool = True,
) -> CLIResult:
    helmctl = require_helmctl()
    arg_list = [str(a) for a in args]

    if (
        db_path is not None
        and "--db" not in arg_list
        and len(arg_list) > 0
        and arg_list[0] in STATEFUL_SUBCOMMANDS
    ):
        arg_list.extend(["--db", str(db_path)])

    cmd = [str(helmctl)] + arg_list
    run_env = os.environ.copy()
    if db_path is not None:
        run_env["HELM_DB_PATH"] = str(db_path)
    if env:
        run_env.update(env)

    start = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=run_env,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = (time.monotonic() - start) * 1000.0
        raise HelmCLIError(
            f"helmctl timed out after {timeout}s: {' '.join(cmd)}",
            returncode=None,
            stdout=exc.stdout or "" if isinstance(exc.stdout, str) else "",
            stderr=exc.stderr or "" if isinstance(exc.stderr, str) else "",
            command=cmd,
        ) from exc

    elapsed_ms = (time.monotonic() - start) * 1000.0
    if proc.returncode == 69 and proc.stdout.strip():
        try:
            stub_json = json.loads(proc.stdout)
        except json.JSONDecodeError:
            stub_json = None
        if isinstance(stub_json, dict) and stub_json.get("status") == "not_implemented":
            subcmd = arg_list[0] if arg_list else "helmctl"
            milestone = stub_json.get("milestone", "pending")
            raise UnbuiltTargetSkip(
                f"{subcmd} subcommand not implemented yet ({milestone})"
            )

    parsed: Any = None
    if expect_json and proc.stdout.strip():
        try:
            parsed = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            if check and proc.returncode == 0:
                raise HelmCLIError(
                    f"helmctl emitted invalid JSON on stdout: {exc}\nstdout={proc.stdout!r}\nstderr={proc.stderr!r}",
                    returncode=proc.returncode,
                    stdout=proc.stdout,
                    stderr=proc.stderr,
                    command=cmd,
                ) from exc

    if check and proc.returncode != 0:
        raise HelmCLIError(
            f"helmctl exited with {proc.returncode}: {' '.join(cmd)}\nstdout={proc.stdout!r}\nstderr={proc.stderr!r}",
            returncode=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            command=cmd,
        )

    if check and expect_json and parsed is None:
        raise HelmCLIError(
            f"helmctl produced empty stdout when JSON was expected: {' '.join(cmd)}\nstderr={proc.stderr!r}",
            returncode=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            command=cmd,
        )

    return CLIResult(
        returncode=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
        json=parsed,
        duration_ms=elapsed_ms,
        command=cmd,
    )


def _is_pending_feature_error(arg_list: Sequence[str], combined_output: str) -> bool:
    lower = combined_output.lower()

    top_cmd = arg_list[0] if arg_list else ""
    sub_cmd = arg_list[1] if len(arg_list) > 1 else ""

    if top_cmd in PENDING_FEATURE_SUBCOMMANDS and (
        f"unknown command '{top_cmd}'" in lower
        or f"unknown subcommand '{top_cmd}'" in lower
    ):
        return True

    if (top_cmd == "agent" and sub_cmd == "update") and (
        "unknown agent subcommand 'update'" in lower
        or "unknown subcommand 'update'" in lower
    ):
        return True

    if (top_cmd == "project" and sub_cmd in {"update-trust", "update"}) and (
        f"unknown project subcommand '{sub_cmd}'" in lower
        or f"unknown subcommand '{sub_cmd}'" in lower
    ):
        return True

    if any(flag in arg_list for flag in PENDING_FEATURE_FLAGS) and (
        "unknown flag" in lower
        or "unknown option" in lower
        or "unrecognized flag" in lower
        or "unrecognized option" in lower
        or "unsupported option" in lower
    ):
        return True

    return False


def run_helmctl_feature(
    args: Sequence[str],
    *,
    db_path: Optional[Union[Path, str]] = None,
    timeout: float = 60.0,
    expect_json: bool = True,
    env: Optional[Dict[str, str]] = None,
    check: bool = True,
    feature_name: Optional[str] = None,
) -> CLIResult:
    """Invoke a helmctl M1-M3 feature surface, mapping pending stubs/unknown subcommands to UnbuiltTargetSkip."""
    arg_list = [str(a) for a in args]
    res = run_helmctl(
        arg_list,
        db_path=db_path,
        timeout=timeout,
        expect_json=False,
        env=env,
        check=False,
    )
    if res.returncode == 69 and res.stdout.strip():
        try:
            stub_json = json.loads(res.stdout)
        except json.JSONDecodeError:
            stub_json = None
        if isinstance(stub_json, dict) and stub_json.get("status") == "not_implemented":
            label = feature_name or " ".join(arg_list[:2]) or "helmctl feature"
            milestone = stub_json.get("milestone", "pending")
            raise UnbuiltTargetSkip(
                f"{label} CLI surface not implemented yet (rc=69, {milestone})"
            )

    combined = f"{res.stdout}\n{res.stderr}"
    if res.returncode != 0 and _is_pending_feature_error(arg_list, combined):
        label = feature_name or " ".join(arg_list[:2]) or "helmctl feature"
        raise UnbuiltTargetSkip(f"{label} CLI surface not implemented yet (rc={res.returncode})")

    parsed: Any = None
    if expect_json and res.stdout.strip():
        try:
            parsed = json.loads(res.stdout)
        except json.JSONDecodeError as exc:
            if check and res.returncode == 0:
                raise HelmCLIError(
                    f"helmctl emitted invalid JSON on stdout: {exc}\nstdout={res.stdout!r}\nstderr={res.stderr!r}",
                    returncode=res.returncode,
                    stdout=res.stdout,
                    stderr=res.stderr,
                    command=res.command,
                ) from exc

    if check and res.returncode != 0:
        raise HelmCLIError(
            f"helmctl exited with {res.returncode}: {' '.join(res.command)}\nstdout={res.stdout!r}\nstderr={res.stderr!r}",
            returncode=res.returncode,
            stdout=res.stdout,
            stderr=res.stderr,
            command=res.command,
        )

    if check and expect_json and parsed is None:
        raise HelmCLIError(
            f"helmctl produced empty stdout when JSON was expected: {' '.join(res.command)}\nstderr={res.stderr!r}",
            returncode=res.returncode,
            stdout=res.stdout,
            stderr=res.stderr,
            command=res.command,
        )

    return CLIResult(
        returncode=res.returncode,
        stdout=res.stdout,
        stderr=res.stderr,
        json=parsed,
        duration_ms=res.duration_ms,
        command=res.command,
    )


def require_feature_field(obj: Dict[str, Any], field: str, description: str) -> Any:
    """Require a newly introduced M1-M3 JSON field, skipping cleanly if not built yet."""
    if not isinstance(obj, dict) or field not in obj:
        raise UnbuiltTargetSkip(f"{description} ({field} missing in CLI JSON output)")
    return obj[field]


class _LocalIPv6HTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6


class LocalLLMServer:
    """Deterministic OpenAI-compatible local HTTP server for opaque-box multi-turn E2E tests."""

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
        self._lock = threading.Lock()
        self.requests: List[Dict[str, Any]] = []

    def __enter__(self) -> "LocalLLMServer":
        parent = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(length) if length > 0 else b"{}"
                try:
                    req_json = json.loads(raw_body.decode("utf-8"))
                except json.JSONDecodeError:
                    req_json = {}

                with parent._lock:
                    parent.requests.append(req_json)

                content = parent.responder(req_json)
                payload = json.dumps(
                    {
                        "id": "chatcmpl-helm-e2e",
                        "object": "chat.completion",
                        "choices": [
                            {
                                "index": 0,
                                "message": {"role": "assistant", "content": content},
                                "finish_reason": "stop",
                            }
                        ],
                        "usage": {"prompt_tokens": 12, "completion_tokens": 12},
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
            self._server = _LocalIPv6HTTPServer(("::1", 0), Handler)
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


def _assert_bool(val: Any, name: str) -> None:
    if not isinstance(val, bool):
        raise AssertionError(f"Field '{name}' must be bool, got {type(val).__name__}: {val!r}")


def _assert_int(val: Any, name: str) -> None:
    if isinstance(val, bool) or not isinstance(val, int):
        raise AssertionError(f"Field '{name}' must be int, got {type(val).__name__}: {val!r}")


def _assert_number(val: Any, name: str) -> None:
    if isinstance(val, bool) or not isinstance(val, (int, float)):
        raise AssertionError(f"Field '{name}' must be number, got {type(val).__name__}: {val!r}")


def _assert_nonempty_str(val: Any, name: str) -> None:
    if not isinstance(val, str) or not val.strip():
        raise AssertionError(f"Field '{name}' must be non-empty str, got {val!r}")


def _parse_size_field(val: Any, name: str) -> Tuple[float, float]:
    if isinstance(val, dict):
        w = val.get("width")
        h = val.get("height")
        _assert_number(w, f"{name}.width")
        _assert_number(h, f"{name}.height")
        return float(w), float(h)
    if isinstance(val, (list, tuple)) and len(val) == 2:
        _assert_number(val[0], f"{name}[0]")
        _assert_number(val[1], f"{name}[1]")
        return float(val[0]), float(val[1])
    raise AssertionError(f"Field '{name}' must be {{width,height}} or [w,h], got {val!r}")


def _parse_rect_field(val: Any, name: str) -> Tuple[float, float, float, float]:
    if isinstance(val, dict):
        if "origin" in val and "size" in val:
            origin = val["origin"]
            size = val["size"]
            x, y = float(origin["x"]), float(origin["y"])
            w, h = float(size["width"]), float(size["height"])
            return x, y, w, h
        for k in ("x", "y", "width", "height"):
            _assert_number(val.get(k), f"{name}.{k}")
        return float(val["x"]), float(val["y"]), float(val["width"]), float(val["height"])
    if (
        isinstance(val, (list, tuple))
        and len(val) == 2
        and isinstance(val[0], (list, tuple))
        and isinstance(val[1], (list, tuple))
        and len(val[0]) == 2
        and len(val[1]) == 2
    ):
        return float(val[0][0]), float(val[0][1]), float(val[1][0]), float(val[1][1])
    raise AssertionError(f"Field '{name}' must be rect dict or [[x,y],[w,h]], got {val!r}")


def validate_execution_result(data: Any) -> Dict[str, Any]:
    if not isinstance(data, dict):
        raise AssertionError(f"ExecutionResult must be JSON object, got {type(data).__name__}")
    _assert_nonempty_str(data.get("requestID"), "requestID")
    mode = data.get("modeUsed")
    if mode not in VALID_ISOLATION_MODES:
        raise AssertionError(
            f"Field 'modeUsed' must be one of {sorted(VALID_ISOLATION_MODES)}, got {mode!r}"
        )
    _assert_int(data.get("exitCode"), "exitCode")
    if not isinstance(data.get("stdout"), str):
        raise AssertionError("Field 'stdout' must be str")
    if not isinstance(data.get("stderr"), str):
        raise AssertionError("Field 'stderr' must be str")
    _assert_bool(data.get("timedOut"), "timedOut")
    _assert_bool(data.get("truncatedOutput"), "truncatedOutput")
    _assert_number(data.get("durationMs"), "durationMs")
    if float(data["durationMs"]) < 0:
        raise AssertionError(f"Field 'durationMs' must be >= 0, got {data['durationMs']}")
    return data


def validate_browser_observation(
    data: Any, *, require_untrusted: bool = True
) -> Dict[str, Any]:
    if not isinstance(data, dict):
        raise AssertionError(f"BrowserObservation must be JSON object, got {type(data).__name__}")
    _assert_nonempty_str(data.get("url"), "url")
    if not isinstance(data.get("title"), str):
        raise AssertionError("Field 'title' must be str")
    vw, vh = _parse_size_field(data.get("viewportSize"), "viewportSize")
    if vw <= 0 or vh <= 0:
        raise AssertionError(f"viewportSize must have positive dimensions, got {(vw, vh)}")
    _assert_nonempty_str(data.get("screenshotPNGPath"), "screenshotPNGPath")

    ocr_lines = data.get("ocrLines")
    if not isinstance(ocr_lines, list):
        raise AssertionError("Field 'ocrLines' must be a list")
    for idx, line in enumerate(ocr_lines):
        if not isinstance(line, dict):
            raise AssertionError(f"ocrLines[{idx}] must be an object")
        if not isinstance(line.get("text"), str):
            raise AssertionError(f"ocrLines[{idx}].text must be str")
        _assert_number(line.get("confidence"), f"ocrLines[{idx}].confidence")
        _parse_rect_field(line.get("normalizedRect"), f"ocrLines[{idx}].normalizedRect")
        _parse_rect_field(line.get("cssRect"), f"ocrLines[{idx}].cssRect")

    if not isinstance(data.get("domElements"), list):
        raise AssertionError("Field 'domElements' must be a list")

    trust_tag = data.get("trustTag")
    _assert_nonempty_str(trust_tag, "trustTag")
    if require_untrusted and trust_tag != "untrustedData":
        raise AssertionError(
            f"BrowserObservation.trustTag must be 'untrustedData', got {trust_tag!r}"
        )

    _assert_number(data.get("latencyMs"), "latencyMs")
    if float(data["latencyMs"]) < 0:
        raise AssertionError(f"Field 'latencyMs' must be >= 0, got {data['latencyMs']}")
    return data


def validate_exception_alert(data: Any) -> Dict[str, Any]:
    if not isinstance(data, dict):
        raise AssertionError(f"ExceptionAlert must be JSON object, got {type(data).__name__}")
    _assert_nonempty_str(data.get("id"), "id")
    _assert_nonempty_str(data.get("projectID"), "projectID")
    _assert_nonempty_str(data.get("kind"), "kind")
    _assert_nonempty_str(data.get("status"), "status")
    _assert_nonempty_str(data.get("summary"), "summary")
    return data


def validate_chat_message(data: Any) -> Dict[str, Any]:
    if not isinstance(data, dict):
        raise AssertionError(f"ChatMessage must be JSON object, got {type(data).__name__}")
    _assert_nonempty_str(data.get("id"), "id")
    _assert_nonempty_str(data.get("projectID"), "projectID")
    channel_key = data.get("channelKey")
    _assert_nonempty_str(channel_key, "channelKey")
    if channel_key != "crew" and not str(channel_key).startswith("agent:"):
        raise AssertionError(
            f"Field 'channelKey' must be 'crew' or 'agent:<UUID>', got {channel_key!r}"
        )
    sender_kind = data.get("senderKind")
    if sender_kind not in VALID_CHAT_SENDER_KINDS:
        raise AssertionError(
            f"Field 'senderKind' must be one of {sorted(VALID_CHAT_SENDER_KINDS)}, got {sender_kind!r}"
        )
    _assert_nonempty_str(data.get("senderName"), "senderName")
    if not isinstance(data.get("content"), str) or not str(data.get("content")).strip():
        raise AssertionError(f"Field 'content' must be non-empty str, got {data.get('content')!r}")
    if "referencedFiles" in data and data["referencedFiles"] is not None:
        if not isinstance(data["referencedFiles"], list):
            raise AssertionError("Field 'referencedFiles' must be list")
    created_at = data.get("createdAt")
    if isinstance(created_at, bool) or created_at is None or (
        isinstance(created_at, str) and not created_at.strip()
    ):
        raise AssertionError(f"Field 'createdAt' must be non-empty timestamp, got {created_at!r}")
    return data


def validate_agent_work_entry(data: Any) -> Dict[str, Any]:
    if not isinstance(data, dict):
        raise AssertionError(f"AgentWorkEntry must be JSON object, got {type(data).__name__}")
    _assert_nonempty_str(data.get("id"), "id")
    _assert_nonempty_str(data.get("projectID"), "projectID")
    _assert_nonempty_str(data.get("agentID"), "agentID")
    _assert_nonempty_str(data.get("agentName"), "agentName")
    _assert_int(data.get("stepNumber"), "stepNumber")
    if int(data["stepNumber"]) < 0:
        raise AssertionError(f"Field 'stepNumber' must be >= 0, got {data['stepNumber']}")
    phase = data.get("phase")
    if phase not in VALID_WORK_PHASES:
        raise AssertionError(
            f"Field 'phase' must be one of {sorted(VALID_WORK_PHASES)}, got {phase!r}"
        )
    _assert_nonempty_str(data.get("summary"), "summary")
    if not isinstance(data.get("touchedFiles"), list):
        raise AssertionError("Field 'touchedFiles' must be list")
    if not isinstance(data.get("artifactPaths"), list):
        raise AssertionError("Field 'artifactPaths' must be list")
    return data


def validate_project_trust_policy(
    data: Any, *, expected: Optional[str] = None
) -> Dict[str, Any]:
    if not isinstance(data, dict):
        raise AssertionError(f"Project must be JSON object, got {type(data).__name__}")
    policy = data.get("sandboxTrustPolicy")
    if policy not in VALID_TRUST_POLICIES:
        raise AssertionError(
            f"Field 'sandboxTrustPolicy' must be one of {sorted(VALID_TRUST_POLICIES)}, got {policy!r}"
        )
    if expected is not None and policy != expected:
        raise AssertionError(
            f"Expected sandboxTrustPolicy={expected!r}, got {policy!r}"
        )
    return data


def _paeth_predictor(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter_scanlines(
    raw: bytes, width: int, height: int, channels: int, bit_depth: int
) -> bytearray:
    if bit_depth != 8:
        raise ValueError(f"Unsupported PNG bit depth {bit_depth} (expected 8)")
    bpp = channels
    stride = width * bpp
    expected_len = (stride + 1) * height
    if len(raw) < expected_len:
        raise ValueError(
            f"Decompressed PNG data too short: {len(raw)} < {expected_len}"
        )

    out = bytearray(height * stride)
    prev_row = bytearray(stride)

    for y in range(height):
        row_start = y * (stride + 1)
        ftype = raw[row_start]
        src_start = row_start + 1
        dst_start = y * stride

        if ftype == 0:
            cur = bytearray(raw[src_start : src_start + stride])
        elif ftype == 1:
            cur = bytearray(raw[src_start : src_start + stride])
            for i in range(bpp, stride):
                cur[i] = (cur[i] + cur[i - bpp]) & 0xFF
        elif ftype == 2:
            cur = bytearray(raw[src_start : src_start + stride])
            for i in range(stride):
                cur[i] = (cur[i] + prev_row[i]) & 0xFF
        elif ftype == 3:
            cur = bytearray(raw[src_start : src_start + stride])
            for i in range(stride):
                left = cur[i - bpp] if i >= bpp else 0
                up = prev_row[i]
                cur[i] = (cur[i] + ((left + up) >> 1)) & 0xFF
        elif ftype == 4:
            cur = bytearray(raw[src_start : src_start + stride])
            for i in range(stride):
                left = cur[i - bpp] if i >= bpp else 0
                up = prev_row[i]
                up_left = prev_row[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + _paeth_predictor(left, up, up_left)) & 0xFF
        else:
            raise ValueError(f"Unsupported PNG filter type: {ftype}")

        out[dst_start : dst_start + stride] = cur
        prev_row = cur

    return out


def inspect_png(path: Union[Path, str]) -> Dict[str, Any]:
    """Verify PNG signature, IHDR, chunks, and pixel/luminance properties via stdlib."""
    p = Path(path)
    if not p.is_file():
        raise AssertionError(f"PNG file does not exist: {p}")
    data = p.read_bytes()
    if len(data) < 8 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError(f"Invalid PNG signature in {p}")

    offset = 8
    ihdr: Optional[Tuple[int, int, int, int, int, int, int]] = None
    idat_chunks: List[bytes] = []
    saw_iend = False

    while offset + 8 <= len(data):
        length, ctype = struct.unpack(">I4s", data[offset : offset + 8])
        offset += 8
        if offset + length + 4 > len(data):
            raise AssertionError(f"Truncated PNG chunk {ctype!r} in {p}")
        chunk_data = data[offset : offset + length]
        offset += length
        (expected_crc,) = struct.unpack(">I", data[offset : offset + 4])
        offset += 4
        actual_crc = binascii.crc32(ctype + chunk_data) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise AssertionError(f"CRC mismatch in PNG chunk {ctype!r} in {p}")

        if ctype == b"IHDR":
            if len(chunk_data) != 13:
                raise AssertionError(f"Invalid IHDR length {len(chunk_data)} in {p}")
            ihdr = struct.unpack(">IIBBBBB", chunk_data)
        elif ctype == b"IDAT":
            idat_chunks.append(chunk_data)
        elif ctype == b"IEND":
            saw_iend = True
            break

    if ihdr is None:
        raise AssertionError(f"Missing IHDR chunk in {p}")
    if not idat_chunks:
        raise AssertionError(f"Missing IDAT chunk in {p}")
    if not saw_iend:
        raise AssertionError(f"Missing IEND chunk in {p}")

    width, height, bit_depth, color_type, compression, filter_method, interlace = ihdr
    if width <= 0 or height <= 0:
        raise AssertionError(f"Invalid PNG dimensions {width}x{height} in {p}")

    channels_map = {0: 1, 2: 3, 4: 2, 6: 4}
    info: Dict[str, Any] = {
        "path": str(p),
        "file_bytes": len(data),
        "width": width,
        "height": height,
        "bit_depth": bit_depth,
        "color_type": color_type,
        "interlace": interlace,
    }

    if interlace == 0 and bit_depth == 8 and color_type in channels_map:
        channels = channels_map[color_type]
        raw = zlib.decompress(b"".join(idat_chunks))
        pixels = _unfilter_scanlines(raw, width, height, channels, bit_depth)
        total_pixels = width * height
        step = max(1, total_pixels // 20000)

        lum_sum = 0.0
        lum_min = 255.0
        lum_max = 0.0
        sampled = 0
        first_px: Optional[bytes] = None
        is_uniform = True

        for px_idx in range(0, total_pixels, step):
            base = px_idx * channels
            px_slice = bytes(pixels[base : base + channels])
            if first_px is None:
                first_px = px_slice
            elif is_uniform and px_slice != first_px:
                is_uniform = False

            if channels >= 3:
                r, g, b = pixels[base], pixels[base + 1], pixels[base + 2]
                lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            else:
                lum = float(pixels[base])

            lum_sum += lum
            if lum < lum_min:
                lum_min = lum
            if lum > lum_max:
                lum_max = lum
            sampled += 1

        import hashlib

        info["mean_luminance"] = lum_sum / max(1, sampled)
        info["min_luminance"] = lum_min
        info["max_luminance"] = lum_max
        info["is_uniform"] = is_uniform
        info["pixel_sha256"] = hashlib.sha256(pixels).hexdigest()

    return info


def build_test_png(
    width: int, height: int, rgb_rows: Sequence[bytes]
) -> bytes:
    """Create a valid 8-bit RGB PNG from `height` rows of length `width * 3`."""
    if len(rgb_rows) != height:
        raise ValueError("rgb_rows length must equal height")
    raw_scanlines = bytearray()
    expected_row_len = width * 3
    for row in rgb_rows:
        if len(row) != expected_row_len:
            raise ValueError("Each row must have length width * 3")
        raw_scanlines.append(0)
        raw_scanlines.extend(row)

    def _chunk(ctype: bytes, payload: bytes) -> bytes:
        crc = binascii.crc32(ctype + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + ctype + payload + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    idat = zlib.compress(bytes(raw_scanlines), level=6)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", ihdr)
        + _chunk(b"IDAT", idat)
        + _chunk(b"IEND", b"")
    )


class E2ETestCase(unittest.TestCase):
    """Base TestCase for Helm opaque-box E2E tests."""

    pass


class E2ETestResult(unittest.TextTestResult):
    """Tracks PASS / FAIL / ERROR / SKIP_UNBUILT separately with strict mode."""

    def __init__(self, stream, descriptions, verbosity, *, strict: bool = False):
        super().__init__(stream, descriptions, verbosity)
        self.strict = strict
        self.passed_records: List[Dict[str, Any]] = []
        self.failed_records: List[Dict[str, Any]] = []
        self.errored_records: List[Dict[str, Any]] = []
        self.skipped_unbuilt_records: List[Dict[str, Any]] = []
        self.skipped_other_records: List[Dict[str, Any]] = []
        self._test_starts: Dict[str, float] = {}

    def startTest(self, test: unittest.TestCase) -> None:
        self._test_starts[test.id()] = time.monotonic()
        super().startTest(test)

    def _elapsed_ms(self, test: unittest.TestCase) -> float:
        t0 = self._test_starts.pop(test.id(), None)
        if t0 is None:
            return 0.0
        return round((time.monotonic() - t0) * 1000.0, 2)

    def _record_meta(
        self, test: unittest.TestCase, status: str, message: str = ""
    ) -> Dict[str, Any]:
        return {
            "id": test.id(),
            "description": test.shortDescription() or "",
            "status": status,
            "duration_ms": self._elapsed_ms(test),
            "message": message,
        }

    def addSuccess(self, test: unittest.TestCase) -> None:
        self.passed_records.append(self._record_meta(test, "PASS"))
        super().addSuccess(test)

    def addFailure(self, test: unittest.TestCase, err) -> None:
        msg = self._exc_info_to_string(err, test)
        self.failed_records.append(self._record_meta(test, "FAIL", msg))
        super().addFailure(test, err)

    def addError(self, test: unittest.TestCase, err) -> None:
        msg = self._exc_info_to_string(err, test)
        self.errored_records.append(self._record_meta(test, "ERROR", msg))
        super().addError(test, err)

    def addSkip(self, test: unittest.TestCase, reason: str) -> None:
        is_unbuilt = "[SKIP_UNBUILT]" in reason
        if is_unbuilt and self.strict:
            try:
                raise AssertionError(
                    f"Strict mode forbids unbuilt skip: {reason}"
                )
            except AssertionError:
                self.addFailure(test, sys.exc_info())
                return

        if is_unbuilt:
            self.skipped_unbuilt_records.append(
                self._record_meta(test, "SKIP_UNBUILT", reason)
            )
            unittest.TestResult.addSkip(self, test, reason)
            if self.showAll:
                self.stream.writeln(f"SKIP_UNBUILT ({reason})")
                self.stream.flush()
            elif self.dots:
                self.stream.write("U")
                self.stream.flush()
        else:
            self.skipped_other_records.append(
                self._record_meta(test, "SKIP", reason)
            )
            super().addSkip(test, reason)


def _resolve_tier_modules(tier_spec: str) -> List[str]:
    normalized = tier_spec.strip().lower()
    if normalized == "all":
        selected: List[str] = []
        for t in ("0", "1", "2", "3", "4", "5"):
            mod = TIER_MODULES[t]
            if (E2E_DIR / f"{mod}.py").is_file():
                selected.append(mod)
        return selected

    parts = [p.strip() for p in re.split(r"[,\s]+", normalized) if p.strip()]
    selected = []
    for p in parts:
        if p not in TIER_MODULES:
            raise ValueError(
                f"Invalid tier '{p}'. Valid values: 0, 1, 2, 3, 4, 5, all"
            )
        mod = TIER_MODULES[p]
        if not (E2E_DIR / f"{mod}.py").is_file():
            raise FileNotFoundError(
                f"Requested tier {p} test module not found: {E2E_DIR / (mod + '.py')}"
            )
        if mod not in selected:
            selected.append(mod)
    return selected


def _filter_suite(suite: unittest.TestSuite, pattern: Optional[str]) -> unittest.TestSuite:
    if not pattern:
        return suite
    filtered = unittest.TestSuite()
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            sub = _filter_suite(item, pattern)
            if sub.countTestCases() > 0:
                filtered.addTest(sub)
        else:
            if pattern.lower() in item.id().lower():
                filtered.addTest(item)
    return filtered


def run_tier_suite(
    *,
    tier: str = "all",
    allow_unbuilt: bool = False,
    strict: bool = False,
    json_out: Optional[Union[Path, str]] = None,
    verbosity: int = 2,
    pattern: Optional[str] = None,
) -> int:
    strict_mode = strict or (os.environ.get("HELM_E2E_STRICT") == "1")
    if strict_mode:
        allow_unbuilt = False

    if str(E2E_DIR) not in sys.path:
        sys.path.insert(0, str(E2E_DIR))

    modules = _resolve_tier_modules(tier)
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for mod in modules:
        suite.addTests(loader.loadTestsFromName(mod))
    suite = _filter_suite(suite, pattern)

    result_box: List[E2ETestResult] = []

    def _result_factory(stream, descriptions, verb):
        res = E2ETestResult(stream, descriptions, verb, strict=strict_mode)
        result_box.append(res)
        return res

    runner = unittest.TextTestRunner(
        stream=sys.stdout,
        verbosity=verbosity,
        resultclass=_result_factory,
    )
    runner.run(suite)
    res = result_box[0]

    pass_count = len(res.passed_records)
    fail_count = len(res.failed_records)
    error_count = len(res.errored_records)
    skip_unbuilt_count = len(res.skipped_unbuilt_records)
    skip_other_count = len(res.skipped_other_records)
    total_count = (
        pass_count + fail_count + error_count + skip_unbuilt_count + skip_other_count
    )

    if fail_count > 0 or error_count > 0:
        exit_code = 1
    elif skip_unbuilt_count > 0 and not allow_unbuilt:
        exit_code = 2
    else:
        exit_code = 0

    helmctl_path = find_helmctl()
    helm_app_path = find_helm_app()
    vm_assets = find_vm_assets()

    all_tests = (
        res.passed_records
        + res.failed_records
        + res.errored_records
        + res.skipped_unbuilt_records
        + res.skipped_other_records
    )
    tier_counts: Dict[str, Dict[str, int]] = {}
    for rec in all_tests:
        mod_prefix = str(rec.get("id", "")).split(".", 1)[0]
        tier_key = next((k for k, m in TIER_MODULES.items() if m == mod_prefix), mod_prefix)
        bucket = tier_counts.setdefault(
            tier_key,
            {"total": 0, "pass": 0, "fail": 0, "error": 0, "skip_unbuilt": 0, "skip_other": 0},
        )
        bucket["total"] += 1
        st = rec.get("status")
        if st == "PASS":
            bucket["pass"] += 1
        elif st == "FAIL":
            bucket["fail"] += 1
        elif st == "ERROR":
            bucket["error"] += 1
        elif st == "SKIP_UNBUILT":
            bucket["skip_unbuilt"] += 1
        else:
            bucket["skip_other"] += 1

    report_payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "tier": tier,
        "modules": modules,
        "strict": strict_mode,
        "allow_unbuilt": allow_unbuilt,
        "exit_code": exit_code,
        "counts": {
            "total": total_count,
            "pass": pass_count,
            "fail": fail_count,
            "error": error_count,
            "skip_unbuilt": skip_unbuilt_count,
            "skip_other": skip_other_count,
        },
        "tier_counts": tier_counts,
        "targets": {
            "focus_probe": str(FOCUS_PROBE_BIN) if _is_executable_file(FOCUS_PROBE_BIN) else None,
            "helmctl": str(helmctl_path) if helmctl_path else None,
            "helm_app": str(helm_app_path) if helm_app_path else None,
            "vm_assets": {k: str(v) for k, v in vm_assets.items()} if vm_assets else None,
        },
        "tests": all_tests,
    }

    report_path = Path(json_out) if json_out else (REPORTS_DIR / "latest.json")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_report = report_path.with_suffix(".json.tmp")
    tmp_report.write_text(json.dumps(report_payload, indent=2), encoding="utf-8")
    tmp_report.replace(report_path)

    print(
        "\n=== HELM E2E SUMMARY ===\n"
        f"Tier(s):      {tier}\n"
        f"PASS:         {pass_count}\n"
        f"FAIL:         {fail_count}\n"
        f"ERROR:        {error_count}\n"
        f"SKIP_UNBUILT: {skip_unbuilt_count}\n"
        f"SKIP_OTHER:   {skip_other_count}\n"
        f"TOTAL:        {total_count}\n"
        f"Report:       {report_path}\n"
        f"Exit Code:    {exit_code}\n",
        flush=True,
    )
    return exit_code


def run_tier_module_cli(tier: str, argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=f"Helm E2E tier {tier} test runner")
    parser.add_argument(
        "--allow-unbuilt",
        action="store_true",
        help="Exit 0 when SKIP_UNBUILT > 0 and FAIL == 0",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat SKIP_UNBUILT as FAIL (also HELM_E2E_STRICT=1)",
    )
    parser.add_argument("--json-out", default=None, help="JSON summary output path")
    parser.add_argument("-k", "--pattern", default=None, help="Filter test id substring")
    parser.add_argument("-v", "--verbose", action="count", default=2)
    parser.add_argument("selectors", nargs="*", help="Optional test name/pattern filter")
    args = parser.parse_args(argv)

    pattern = args.pattern
    if pattern is None and args.selectors:
        pattern = args.selectors[0].split(".")[-1]

    return run_tier_suite(
        tier=tier,
        allow_unbuilt=args.allow_unbuilt,
        strict=args.strict,
        json_out=args.json_out,
        verbosity=args.verbose,
        pattern=pattern,
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Helm E2E test suite runner")
    parser.add_argument("--tier", default="all", help="Tier 0..5 or all")
    parser.add_argument(
        "--allow-unbuilt",
        action="store_true",
        help="Exit 0 when SKIP_UNBUILT > 0 and FAIL == 0",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat SKIP_UNBUILT as FAIL (also HELM_E2E_STRICT=1)",
    )
    parser.add_argument("--json-out", default=None, help="JSON summary output path")
    parser.add_argument("-v", "--verbose", action="count", default=2)
    parser.add_argument("-k", "--pattern", default=None, help="Filter test id substring")
    args = parser.parse_args(argv)
    return run_tier_suite(
        tier=args.tier,
        allow_unbuilt=args.allow_unbuilt,
        strict=args.strict,
        json_out=args.json_out,
        verbosity=args.verbose,
        pattern=args.pattern,
    )


if __name__ == "__main__":
    raise SystemExit(main())
