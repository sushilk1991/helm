import AppKit
import Foundation
import HelmAppCore
import HelmBrowser
import HelmCore
import HelmIsolation
import SwiftUI

struct HelmSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: HelmWorkspaceStore

    init() {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment
        let dbPath = Self.resolveDBPath(arguments: args, environment: env)

        do {
            let created = try HelmWorkspaceStore.makeLive(
                databasePath: dbPath,
                arguments: args,
                environment: env
            )
            _store = State(initialValue: created)
        } catch {
            fatalError("Failed to initialize Helm workspace store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("Helm", id: "main") {
            HarborInteractiveShellView(store: store)
                .task {
                    appDelegate.store = store
                    await store.bootstrapInteractive()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    store.showNewProjectSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("Watch") {
                Button("Start Watch") {
                    Task { await store.startSelectedProject() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.selectedProject == nil || store.selectedProject?.status == .running)

                Button("Pause Watch") {
                    Task { await store.pauseSelectedProject() }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(store.selectedProject?.status != .running)

                Divider()

                Button("Add Specialized Agent…") {
                    store.showAddAgentSheet = true
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(store.selectedProject == nil)

                Button("Toggle Inspector") {
                    store.isInspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarStatusView(store: store)
        } label: {
            CompassHelmLogo(
                size: 18,
                style: .monochromeTemplate,
                hasOpenException: store.totalOpenExceptionCount > 0,
                settleTrigger: store.settleHelmCounter
            )
        }
        .menuBarExtraStyle(.window)
    }

    private static func resolveDBPath(arguments: [String], environment: [String: String]) -> String {
        if let idx = arguments.firstIndex(of: "--db"), idx + 1 < arguments.count {
            return arguments[idx + 1]
        }
        if let envPath = environment["HELM_DB_PATH"], !envPath.isEmpty {
            return envPath
        }
        return HelmDatabase.defaultDatabasePath()
    }
}
