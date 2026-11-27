# Helm

**Helm** is a native macOS, local-first control plane for running autonomous multi-agent workspaces in the background without touching your host cursor or active window focus.

Create a **Project**, deploy specialized agents governed by an **exception-only Orchestrator**, and let work run continuously inside isolated sandboxes and headless browsers—staying silent when healthy and alerting you only when execution stalls, drifts, hits a budget cap, or requires a human decision.

---

## Architecture Highlights

Helm is organized into five focused Swift targets (`Package.swift`):

- **`HelmCore`** — Exception-only `OrchestratorActor` (goal decomposition, 3-color DFS `waitingOn` cycle detection, event-driven `TaskGroup` delegation without polling, silent `STEADY_OK` heartbeats), SQLite3 WAL persistence (`HelmDatabase`), `SharedStateStore` (private/shared isolation, 4 SHA-256 prompt-channel digests, TF-IDF + recency ranking, server-side `deriveTrust` provenance verification), deterministic watchdogs (`StallDetector`, `DriftDetector`, `DeadMansSwitch`, `HumanDecisionGate`), and pluggable LLM providers (`ClaudeCLIProvider`, `CodexCLIProvider`, `DirectHTTPProvider`, `FoundationModelsProvider`, `MockLLMProvider`).
- **`HelmIsolation`** — Dual-lane headless execution engine implementing `SandboxExecutor`:
  - **Primary:** Apple `Virtualization.framework` (`VZLinuxBootLoader`) Alpine Linux ARM64 micro-VM (`512 MB` RAM, `virtiofs` `/workspace`, `/dev/hvc0` RPC).
  - **Fallback / macOS-native:** `sandbox-exec` (`/bin/zsh` + Seatbelt SBPL profile denying reads to sensitive home directories such as `.ssh`, `.aws`, and `Library/Keychains`).
- **`HelmBrowser`** — Disposable per-project headless Google Chrome (`--headless=new --remote-debugging-port=0`) driven over Swift `URLSessionWebSocketTask` CDP, paired with Apple **`Vision.framework`** (`VNRecognizeTextRequest`) OCR, bottom-left-to-CSS coordinate mapping, DOM `elementFromPoint` verification, 60s deadlines, WebAuthn passkey refusal, and unconditional `.untrustedData` observation tagging.
- **`HelmApp` (`Helm.app`)** — Native SwiftUI / AppKit **Harbor Chartroom** macOS application featuring a custom Compass-Helm logo, deterministic `SHA256(agent.id)` `5x5` dot-matrix animated agent characters, menu bar status (`MenuBarExtra`), `UNUserNotificationCenter` exception alerts, Light/Dark mode & Reduce Motion support, and headless snapshot/testing hooks (`--headless`, `--seed-demo`, `--snapshot-dir`, `--reduce-motion`).
- **`HelmCLI` (`helmctl`)** — Unattended CLI sharing `HelmCore`, `HelmIsolation`, and `HelmBrowser` for creating projects, adding agents, inspecting shared state/exceptions, running orchestrator loops, and invoking sandbox/browser tools directly.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full v1 architecture specification and design invariants.

---

## Download (macOS Apple Silicon)

Download the **Developer ID signed & Apple-notarized** **`Helm-0.1.1-arm64.dmg`** installer from [GitHub Releases](https://github.com/sushilk1991/helm/releases/latest):

1. Open `Helm-0.1.1-arm64.dmg` and drag **Helm.app** into **Applications**.
2. Launch **Helm** from Applications (macOS 15.0+ on Apple Silicon `arm64`). Built-in auto-update checks GitHub Releases automatically and lets you update in one click from the sidebar.

To build (and optionally sign & notarize) the DMG locally from source:
```bash
bash scripts/build_dmg.sh
# Optional Developer ID signing + notarization:
# HELM_SIGN_IDENTITY="Developer ID Application: ..." \
#   HELM_NOTARY_KEY=/path/to/AuthKey.p8 HELM_NOTARY_KEY_ID=... HELM_NOTARY_ISSUER=... \
#   bash scripts/build_dmg.sh
# Output: dist/Helm-0.1.0-arm64.dmg (+ .sha256)
```

---

## Requirements

- **OS & Toolchain:** macOS 15.0+ (Apple Silicon `arm64` recommended for `Virtualization.framework`; on-device Apple `FoundationModels` available on macOS 26+), Swift 6.4 / Xcode
- **App Bundle Generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen`) for generating `Helm.xcodeproj` from `project.yml`
- **Headless Browser (optional, required for live browser E2E):** Google Chrome installed at `/Applications/Google Chrome.app` (or set `HELM_CHROME_PATH`)
- **Python 3:** Required for running the E2E test harness (`e2e/run_e2e.sh`)
- **LLM Backends (optional):**
  - `mock` — built-in deterministic provider (works offline with zero configuration)
  - `claude` — local `claude` CLI authenticated via Keychain/OAuth
  - `codex` — local `codex` CLI
  - `http` — OpenAI-compatible HTTP endpoint (`HELM_LLM_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`, `HELM_LLM_BASE_URL` or `HELM_DIRECT_HTTP_URL`)
  - `foundation` — Apple `FoundationModels` on-device model (when available)

---

## Quickstart

### 1. Build & Sign `helmctl`

Build with SwiftPM and ad-hoc sign `helmctl` with `Helm.entitlements` (`com.apple.security.virtualization`):

```bash
swift build
# Or build and apply com.apple.security.virtualization entitlement automatically:
bash scripts/build_and_sign.sh
```

*(Optional)* Pre-cache Alpine Linux `v3.21` `aarch64` netboot assets (`vmlinuz-virt`, `initramfs-virt`) with SHA-256 verification for `Virtualization.framework` micro-VMs:

```bash
bash scripts/bootstrap_vm_assets.sh
```

### 2. Build `Helm.app`

Generate the Xcode project and build the native macOS app:

```bash
xcodegen generate
xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug -derivedDataPath .build/DerivedDataXcode build
open .build/DerivedDataXcode/Build/Products/Debug/Helm.app
```

### 3. Run Unit & Integration Tests

```bash
swift test
```

### 4. Run End-to-End Verification

```bash
./e2e/run_e2e.sh
```

Useful options:
- `--tier <0|1|2|3|4|5|all>` — run a specific verification tier
- `--allow-unbuilt` — exit `0` when `Helm.app` is not yet built (`SKIP_UNBUILT > 0`, `FAIL == 0`)
- `--strict` — fail if any unbuilt target skips occur

### 5. CLI (`helmctl`) Usage

```bash
# Create a project workspace
.build/debug/helmctl project create \
  --name "Research" \
  --goal "Verify documentation and build status" \
  --workspace ./workspace

# Add a specialized agent
.build/debug/helmctl agent add \
  --project <project-uuid> \
  --name "Forge" \
  --role coder \
  --goal "Run verification checks in sandbox" \
  --backend mock \
  --capabilities codeExec,readSharedState,proposeSharedState

# Run the exception-only Orchestrator
.build/debug/helmctl run --project <project-uuid> --max-steps 8

# Inspect or resolve any surfaced exceptions
.build/debug/helmctl exceptions list --project <project-uuid> --open-only
.build/debug/helmctl exceptions resolve --id <exception-uuid> --action approve --note "Proceed"

# Direct sandbox or browser invocation
.build/debug/helmctl sandbox exec --workspace ./workspace --cmd "uname -a"
.build/debug/helmctl browser act --url "https://example.com" --click-ocr "More information"
```

---

## Project Layout

```text
.
├── Package.swift                 # SwiftPM targets (HelmCore, HelmIsolation, HelmBrowser, HelmAppCore, HelmCLI)
├── project.yml                   # XcodeGen spec for Helm.app
├── Helm.entitlements             # com.apple.security.virtualization entitlement
├── docs/
│   └── ARCHITECTURE.md           # First-principles v1 architecture & invariants
├── Sources/
│   ├── HelmCore/                 # Orchestrator, SQLite WAL store, SharedState, Watchdogs, LLM providers, ControlPlane
│   ├── HelmIsolation/            # Virtualization.framework VM & Seatbelt sandbox-exec runners
│   ├── HelmBrowser/              # Headless Chrome CDP + Apple Vision OCR + CoordinateMapper
│   ├── HelmApp/                  # SwiftUI Harbor Chartroom UI, Compass-Helm logo, dot-matrix agent characters
│   └── HelmCLI/                  # helmctl entrypoint & sandbox/browser subcommands
├── Tests/                        # Swift Testing suites (Core, Isolation, Browser, App)
├── e2e/                          # 6-tier Python + Swift focus-probe E2E suite & HTML fixtures
├── Resources/                    # AppIcon.icns and Assets.xcassets
└── scripts/                      # Signing, Alpine VM asset bootstrap, and app icon generator
```
