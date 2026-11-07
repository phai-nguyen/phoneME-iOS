import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
@MainActor
final class PhoneMEAppDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientationMask: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientationMask
    }
}
#endif

@main
struct PhoneMEApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(PhoneMEAppDelegate.self) private var appDelegate
#endif
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.preferenceKey) private var appLanguage =
        AppLanguage.defaultLanguage.rawValue

    @StateObject private var storage: PhoneMEStorageController
    @StateObject private var manicSkinStore: ManicSkinStore
    @StateObject private var library: GameLibrary
    @StateObject private var profiles: GameProfileStore
    @StateObject private var profileTemplates: ProfileTemplateStore
    @StateObject private var workspaceStore: WorkspaceStore
    @StateObject private var workspaceRuntime: WorkspaceRuntimeStore
    @StateObject private var session: EmulatorSession
    @StateObject private var backgroundExecution: BackgroundExecutionController

    init() {
        let storage = PhoneMEStorageController()
        PhoneMERuntimeResources.configure(storageRootURL: storage.rootURL)
        _storage = StateObject(wrappedValue: storage)
        _manicSkinStore = StateObject(
            wrappedValue: ManicSkinStore(storageRootURL: storage.rootURL)
        )
        _library = StateObject(wrappedValue: GameLibrary(storage: storage))
        _profiles = StateObject(wrappedValue: GameProfileStore(storage: storage))
        _profileTemplates = StateObject(
            wrappedValue: ProfileTemplateStore(storage: storage)
        )
        _workspaceStore = StateObject(
            wrappedValue: WorkspaceStore(storage: storage)
        )
        _workspaceRuntime = StateObject(
            wrappedValue: WorkspaceRuntimeStore()
        )
        _session = StateObject(wrappedValue: EmulatorSession())
        _backgroundExecution = StateObject(
            wrappedValue: BackgroundExecutionController()
        )
#if os(iOS)
        PhoneMEFrameRendererPrewarmer.prewarm()
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(storage)
                .environmentObject(manicSkinStore)
                .environmentObject(library)
                .environmentObject(profiles)
                .environmentObject(profileTemplates)
                .environmentObject(workspaceStore)
                .environmentObject(workspaceRuntime)
                .environmentObject(session)
                .environmentObject(backgroundExecution)
                .environment(
                    \.locale,
                    AppLanguage(rawValue: appLanguage)?.locale
                        ?? AppLanguage.defaultLanguage.locale
                )
                .onAppear {
                    updateRunningApplicationCount()
                    updateLifecycle(for: scenePhase)
                    session.refreshJITStatus()
                    workspaceRuntime.refreshJITStatus()
#if DEBUG
                    debugLaunchIfRequested()
#endif
                }
                .onChange(of: session.runningApplications.count) { _ in
                    updateRunningApplicationCount()
                }
                .onChange(of: workspaceRuntime.runningApplicationCount) { _ in
                    updateRunningApplicationCount()
                }
                .onChange(of: scenePhase) { newPhase in
                    updateLifecycle(for: newPhase)
                }
#if os(iOS)
                // iOS may jetsam the process shortly after a memory warning;
                // persist deferred RMS (game saves) before that can happen.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    session.flushRecordStores()
                    workspaceRuntime.flushAllRecordStores()
                }
#endif
                .alert("Save Error", isPresented: saveErrorBinding) {
                } message: {
                    Text(activeSaveError ?? "")
                }
        }

#if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(storage)
                .environmentObject(manicSkinStore)
                .environmentObject(library)
                .environmentObject(profiles)
                .environmentObject(profileTemplates)
                .environmentObject(workspaceRuntime)
                .environmentObject(session)
                .environmentObject(backgroundExecution)
                .environment(
                    \.locale,
                    AppLanguage(rawValue: appLanguage)?.locale
                        ?? AppLanguage.defaultLanguage.locale
                )
                .frame(width: 420)
        }
#endif
    }

#if DEBUG
    private func debugLaunchIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["PHONEME_DEBUG_JAR"],
              !path.isEmpty else {
            return
        }

        let sourceURL = URL(fileURLWithPath: path)
        let environment = ProcessInfo.processInfo.environment
        let reopenCount = Int(environment["PHONEME_DEBUG_REOPEN_COUNT"] ?? "")
            ?? (environment["PHONEME_DEBUG_REOPEN"] == "1" ? 1 : 0)
        let debugKeys = (environment["PHONEME_DEBUG_KEYS"] ?? "")
            .split(separator: ",")
            .compactMap { token -> J2MEKey? in
                switch token.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() {
                case "up": return .up
                case "down": return .down
                case "left": return .left
                case "right": return .right
                case "fire", "ok": return .fire
                case "softleft", "soft1": return .softLeft
                case "softright", "soft2": return .softRight
                case "0": return .zero
                case "1": return .one
                case "2": return .two
                case "3": return .three
                case "4": return .four
                case "5": return .five
                case "6": return .six
                case "7": return .seven
                case "8": return .eight
                case "9": return .nine
                case "*", "star": return .star
                case "#", "pound": return .pound
                default: return nil
                }
            }
        let keyStartDelayMilliseconds = max(
            Int(environment["PHONEME_DEBUG_KEY_START_DELAY_MS"] ?? "") ?? 0,
            0
        )
        let keyDelayMilliseconds = max(
            Int(environment["PHONEME_DEBUG_KEY_DELAY_MS"] ?? "") ?? 350,
            50
        )
        let observeMilliseconds = max(
            Int(environment["PHONEME_DEBUG_OBSERVE_MS"] ?? "") ?? 8_000,
            500
        )
        let listSelectionIndex = Int(
            environment["PHONEME_DEBUG_LIST_INDEX"] ?? ""
        )
        var debugProfile = GameProfile.default
        if let debugFPS = Int(environment["PHONEME_DEBUG_FPS"] ?? ""),
           debugFPS > 0 {
            debugProfile.frameRateLimit = debugFPS
        }
        if environment["PHONEME_DEBUG_FPS_OVERRIDE"] == "1" {
            debugProfile.effectiveFramePacingMode = .overrideGameLoop
        }
        let debugTaps: [(x: Int32, y: Int32)] =
            (environment["PHONEME_DEBUG_TAPS"] ?? "")
                .split(separator: ";")
                .compactMap { token in
                    let parts = token.split(separator: ",")
                    guard parts.count == 2,
                          let x = Int32(parts[0].trimmingCharacters(
                            in: .whitespacesAndNewlines
                          )),
                          let y = Int32(parts[1].trimmingCharacters(
                            in: .whitespacesAndNewlines
                          )) else {
                        return nil
                    }
                    return (x, y)
                }
        Task { @MainActor in
            let reportURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("phoneme-debug-report.txt")
            do {
                let game = try library.importJar(from: sourceURL)
                let jarURL = try library.prepareJarForLaunch(game)
                session.launch(
                    game: game,
                    jarURL: jarURL,
                    artworkURL: library.iconURL(for: game),
                    profile: debugProfile
                )

                for _ in 0..<400 where session.state != .running {
                    if case .failed = session.state { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }

                for _ in 0..<max(reopenCount, 0) {
                    guard session.state == .running else { break }

                    session.hideCurrent()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    session.launch(
                        game: game,
                        jarURL: jarURL,
                        artworkURL: library.iconURL(for: game),
                        profile: debugProfile
                    )
                }

                if session.state == .running,
                   let listSelectionIndex {
                    for _ in 0..<100 {
                        guard session.lcdUI.screenKind != .list else { break }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if let item = session.lcdUI.visibleItems.first(where: {
                        !$0.choices.isEmpty
                    }),
                       item.choices.indices.contains(listSelectionIndex) {
                        session.focusLCDUIItem(item.id)
                        session.setLCDUIChoice(
                            componentID: item.id,
                            index: item.choices[listSelectionIndex].index,
                            selected: true
                        )
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }

                if session.state == .running,
                   !debugTaps.isEmpty || !debugKeys.isEmpty {
                    try? await Task.sleep(
                        nanoseconds: UInt64(keyStartDelayMilliseconds) * 1_000_000
                    )
                }

                if session.state == .running {
                    for tap in debugTaps {
                        session.sendPointer(x: tap.x, y: tap.y, action: 1)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        session.sendPointer(x: tap.x, y: tap.y, action: 2)
                        try? await Task.sleep(
                            nanoseconds: UInt64(keyDelayMilliseconds) * 1_000_000
                        )
                    }
                    for key in debugKeys {
                        session.send(key, pressed: true)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        session.send(key, pressed: false)
                        try? await Task.sleep(
                            nanoseconds: UInt64(keyDelayMilliseconds) * 1_000_000
                        )
                    }
                }

                try? await Task.sleep(
                    nanoseconds: UInt64(observeMilliseconds) * 1_000_000
                )
                let appState = session.runningApplications[game.id]
                    .map { String(describing: $0.state) } ?? "missing"
#if os(iOS)
                if let frame = session.frame,
                   let image = frame.makeCGImage(),
                   let data = UIImage(cgImage: image).pngData() {
                    let frameURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("phoneme-debug-frame.png")
                    try? data.write(to: frameURL, options: .atomic)
                }
#endif
                let visibleChoices = session.lcdUI.visibleItems
                    .flatMap(\.orderedChoices)
                    .map(\.text)
                    .joined(separator: " | ")
                let report = [
                    "source=\(sourceURL.lastPathComponent)",
                    "mainClass=\(game.mainClass)",
                    "reopenCount=\(reopenCount)",
                    "debugKeys=\(debugKeys.map(\.mappingID).joined(separator: ","))",
                    "debugTaps=\(debugTaps.map { "\($0.x),\($0.y)" }.joined(separator: ";"))",
                    "keyStartDelayMilliseconds=\(keyStartDelayMilliseconds)",
                    "listSelectionIndex=\(listSelectionIndex.map(String.init) ?? "")",
                    "observeMilliseconds=\(observeMilliseconds)",
                    "framePacingMode=\(debugProfile.effectiveFramePacingMode.rawValue)",
                    "frameRateLimit=\(debugProfile.frameRateLimit)",
                    "state=\(String(describing: session.state))",
                    "application=\(appState)",
                    "frame=\(session.frame != nil)",
                    "fps=\(session.fpsStore.value)",
                    "presentation=\(String(describing: session.presentationMode))",
                    "nativeLCDUI=\(session.isPresentingNativeLCDUI)",
                    "screenTitle=\(session.lcdUI.screen?.title ?? "")",
                    "visibleChoices=\(visibleChoices)"
                ].joined(separator: "\n")
                try report.write(to: reportURL, atomically: true, encoding: .utf8)
                print("[phoneMEDebug] \(report.replacingOccurrences(of: "\n", with: " "))")
            } catch {
                let report = "source=\(sourceURL.lastPathComponent)\nsetupError=\(String(describing: error))\nlocalized=\(error.localizedDescription)"
                try? report.write(to: reportURL, atomically: true, encoding: .utf8)
                print("[phoneMEDebug] \(report.replacingOccurrences(of: "\n", with: " "))")
            }
        }
    }
#endif

    private func updateRunningApplicationCount() {
        backgroundExecution.setRunningApplicationCount(
            session.runningApplications.count
                + workspaceRuntime.runningApplicationCount
        )
    }

    private var activeSaveError: String? {
        profiles.lastSaveError
            ?? profileTemplates.lastSaveError
            ?? workspaceStore.lastSaveError
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { activeSaveError != nil },
            set: { shown in
                if !shown {
                    profiles.lastSaveError = nil
                    profileTemplates.lastSaveError = nil
                    workspaceStore.lastSaveError = nil
                }
            }
        )
    }

    private func updateLifecycle(for phase: ScenePhase) {
        switch phase {
        case .active:
            backgroundExecution.setApplicationPhase(.active)
            session.refreshJITStatus()
            workspaceRuntime.refreshJITStatus()
            session.resume()
            workspaceRuntime.resumeVisibleWorkspaces()
        case .inactive:
            // Arm low-accuracy Location while iOS is beginning the transition
            // out of the foreground. It remains stopped while the app is active.
            backgroundExecution.setApplicationPhase(.inactive)
        case .background:
            backgroundExecution.setApplicationPhase(.background)
            session.suspend()
            workspaceRuntime.suspendAll()
        @unknown default:
            break
        }
    }
}
