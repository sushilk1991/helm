# Helm v1 — First-Principles Research Synthesis & Architecture Specification

**Target Workspace:** `.` (repository root)  
**Platform Baseline:** macOS 27.2 (arm64), Swift 6.4, XcodeGen + SwiftPM, `Apple Development` / ad-hoc signing with `com.apple.security.virtualization`

---

## 1. Architectural Synthesis

Helm is a native macOS local-first control plane for running unattended autonomous multi-agent workspaces without touching the host desktop cursor or active window focus. It synthesizes durable orchestration, strict isolation boundaries, and verifiable provenance into five focused Swift targets:

1. **`HelmCore`** — Domain models, SQLite3 WAL persistence (`projects`, `agents`, `tasks`, `shared_state`, `events`, `exceptions`, `artifacts`, `prompt_channel_digests`), pluggable `LLMProvider` (`ClaudeCLIProvider`, `CodexCLIProvider`, `DirectHTTPProvider`, `FoundationModelsProvider`, `MockLLMProvider`), `SharedStateStore` (private/shared isolation, 4 SHA-256 prompt-channel digests, model-free TF-IDF + 90-day half-life recency + `+100` pinned boost ranking, server-side `deriveTrust` provenance verification), `OrchestratorActor` (goal decomposition, 3-color DFS `waitingOn` cycle check, two-phase async `TaskGroup` delegation without polling, silent `STEADY_OK` heartbeats, self-correction), deterministic `ExceptionWatchdog` (`StallDetector`, `DriftDetector`, `DeadMansSwitch` via independent `DispatchSourceTimer`, `HumanDecisionGate`), `BatonPreflight`, `HelmControlPlane`, and locked protocols (`SandboxExecutor`, `BrowserOCRService`).
2. **`HelmIsolation`** — Dual-lane headless execution engine implementing `SandboxExecutor`: primary **Apple `Virtualization.framework` (`VZLinuxBootLoader`)** Alpine ARM64 micro-VM (`512 MB` RAM, `virtiofs` `/workspace`, `/dev/hvc0` RPC) plus **`sandbox-exec` (`/bin/zsh` + SBPL)** fallback/macOS-native lane, and `IOPMAssertion` keep-awake checks. *(M2 target; compilable stub in M1.)*
3. **`HelmBrowser`** — Disposable per-project **Chrome `--headless=new --remote-debugging-port=0`** via Swift `URLSessionWebSocketTask` CDP (never touching port `9222`), paired with **Apple `Vision.framework` (`VNRecognizeTextRequest`)** + ANE pre-warm, bottom-left-to-CSS coordinate mapping, DOM `elementFromPoint` verification, 60s deadlines, WebAuthn passkey refusal, and unconditional `.untrustedData` observation tagging. *(M3 target; compilable stub in M1.)*
4. **`HelmApp`** (`Helm.app`) — Native SwiftUI/AppKit Harbor Chartroom control-plane UI with Compass-Helm logo, deterministic `SHA256(agent.id)` `5x5` dot-matrix animated agent characters, `MenuBarExtra`, `UNUserNotificationCenter`, Light/Dark & Reduce Motion support, and `--headless` / `--seed-demo` / `--snapshot-dir` hooks. *(M4 target; minimal placeholder in M1.)*
5. **`HelmCLI`** (`helmctl`) — Opaque-box Swift CLI target sharing `HelmCore` / `HelmIsolation` / `HelmBrowser` for unattended automation and E2E verification without touching GUI focus.

---

## 2. Core Design Invariants

- **Exception-Only Discipline:** Healthy runs and `STEADY_OK` checks emit **zero** notifications, banners, or exceptions. Only deterministic conditions (`stall`, `loop`, `drift`, `budget`, `humanDecision`, `coordinatorStalled`, `providerFailure`) surface durable `ExceptionAlert` rows and transition the Project to `.held`.
- **Anti-Polling & Crash Recovery:** `OrchestratorActor` dispatches tasks via `withThrowingTaskGroup` event-driven completion (no `Task.sleep` polling). SQLite3 WAL transactions (`BEGIN IMMEDIATE ... COMMIT`) and `reconcileOrphanedRunsOnBoot()` safely recover interrupted `.running` tasks on restart.
- **Untrusted Data Provenance:** External web, OCR, and sandbox outputs carry `TrustLevel.untrustedData` (`BrowserObservation.init` forces `.untrustedData`, and `SharedStateStore.deriveTrust` re-queries SQLite rather than trusting caller claims). Untrusted content is blocked from modifying `.rule` or authoritative shared state entries, logging `.sharedStateRejected` and raising a `.drift` exception on tamper attempts.
- **Host Cursor & Focus Invariance:** Background execution and browser automation never touch the host cursor or foreground window focus. Sandboxed `/bin/zsh` avoids nix-darwin shell restrictions inside `sandbox-exec`.
- **LLM Auth Safety:** `ClaudeCLIProvider` invokes `claude -p ... --output-format json --no-session-persistence` and **never** passes `--bare` (preserving Keychain/OAuth auth). `CodexCLIProvider` invokes `codex exec - --json --ephemeral --skip-git-repo-check`. `FoundationModelsProvider` enforces the 4,096-token ceiling and creates a fresh `LanguageModelSession` per request.
