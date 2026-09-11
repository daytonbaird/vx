import AppKit
import AVFoundation
import Carbon
import Combine
import Foundation
import SwiftUI

/// Carries the replay Audio Source's "out of audio" callback to the flow. Built before the
/// flow exists and pointed at it afterwards; the reference is weak so the flow → source →
/// closure → relay chain never closes into a cycle.
private final class ReplayDrainRelay {
    weak var flow: DictationFlow?

    func fire() {
        DispatchQueue.main.async { [weak self] in
            self?.flow?.audioSourceDidDrain()
        }
    }
}

@MainActor
public final class AppCoordinator: NSObject {
    private let appState: AppState
    /// Dictation Flow: owns the recording → transcript → inserted text path and reports
    /// back through `DictationFlowDelegate`. Everything AppKit stays on this side.
    private let flow: DictationFlow
    private lazy var overlay = OverlayWindow(idleMessage: idleMessage)
    private let hud = DictationHUDController()
    private let preferencesController = PreferencesController()
    private let debugLogController = DebugLogController()
    private let historyController = TranscriptionHistoryController()
    private let volumeController = SystemVolumeController()

    private let updateChecker = UpdateChecker()
    private let soundPlayer = SoundPlayer()
    private let contextDebugController = ContextDebugController()

    private var statusItem: NSStatusItem?
    private var updateMenuView: UpdateMenuItemView?
    private var historyMenuItem: NSMenuItem?

    private var autoDetectModeMenuItem: NSMenuItem?
    private var detectionStatusMenuItem: NSMenuItem?
    private var modeParentMenuItem: NSMenuItem?
    private var modeMenuItems: [DictationMode: NSMenuItem] = [:]
    private var profileMenuItem: NSMenuItem?
    private var profileMenuItems: [CodeProfile: NSMenuItem] = [:]
    private var shortcutMonitor: GlobalShortcutMonitor?
    private var doubleTapMonitor: DoubleTapMonitor?
    private var modifierMonitor: ModifierKeyMonitor?
    private var mouseButtonMonitor: MouseButtonMonitor?
    private var copyLastMonitor: GlobalShortcutMonitor?
    private var copyLastMouseButtonMonitor: MouseButtonMonitor?
    private var goModeShortcutMonitor: GlobalShortcutMonitor?
    private var goModeDoubleTapMonitor: DoubleTapMonitor?
    private var goModeModifierMonitor: ModifierKeyMonitor?
    private var goModeMouseButtonMonitor: MouseButtonMonitor?
    /// Output was Bluetooth when the current capture began, so the duck is deferred until
    /// `.recordingStarted` (see the ordering note in `flow(_:didEmit:)`).
    private var deferredBluetoothDuck = false
    private var cancellables = Set<AnyCancellable>()
    /// Live only when `VX_TEST_CONTROL` names a socket path.
    private var testControlServer: TestControlServer?
    private var accessibilityAlertShown = false
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    @MainActor
    private func logFailure(_ message: String, dismissAfter: TimeInterval = 2.5) {
        vxLog("[coordinator/error] \(message)")
        overlay.present(.failure(message))
        overlay.dismiss(after: dismissAfter)
        hud.flashStatus(.error, duration: dismissAfter + 0.75)
    }

    private var idleMessage: String {
        switch appState.activationMode {
        case .holdToTalk:
            return "Hold \(appState.shortcut.displayName) to dictate"
        case .toggle:
            return "Press \(appState.shortcut.displayName) to toggle dictation"
        }
    }

    /// Production wiring: builds the real Dictation Flow dependencies (microphone, vx-rs
    /// subprocess, pasteboard inserter, shared history) around `appState`.
    public convenience init(appState: AppState) {
        // The replay source has to tell the flow it ran out of audio, but the flow does not
        // exist until the dependencies are built — the relay closes that loop and holds the
        // flow weakly, so the flow's ownership of the source stays acyclic.
        let drainRelay = ReplayDrainRelay()
        let audioSource: AudioSource
        if let replayURL = RuntimeProfile.current.audioSourceURL {
            vxLog("[coordinator/init] audio source: replay \(replayURL.path)")
            audioSource = WAVFileAudioSource(
                url: replayURL,
                pacing: .realtime,
                onDrained: { drainRelay.fire() }
            )
        } else {
            audioSource = AudioCapture()
        }

        let dependencies = DictationFlow.Dependencies(
            audioSource: audioSource,
            transcriber: SubprocessTranscriber(),
            processor: DictationProcessor(),
            contextResolver: DictationContextResolver(),
            textInserter: PasteboardTextInserter(),
            history: TranscriptionHistory.shared,
            settings: {
                DictationSettings(
                    backendURL: appState.backendURL,
                    modelURL: appState.modelURL,
                    inputDeviceUID: appState.selectedInputDeviceUID,
                    autoDetectMode: appState.autoDetectMode,
                    manualMode: appState.currentMode,
                    manualProfile: appState.currentCodeProfile,
                    spokenSubmitPhrases: appState.spokenSubmitPhrases,
                    goModeSubmitDelay: appState.goModeSubmitDelay,
                    postProcessing: { ruleContext, goMode in
                        AppCoordinator.makePostProcessingConfig(
                            appState: appState,
                            ruleContext: ruleContext,
                            enabled: goMode ? appState.usePostProcessingInGoMode : true
                        )
                    }
                )
            },
            frontmostApp: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return TargetApp(
                    bundleID: app.bundleIdentifier,
                    name: app.localizedName,
                    pid: app.processIdentifier
                )
            },
            validateResources: { backendURL, modelURL in
                try FileValidator.validate(backendURL: backendURL, modelURL: modelURL)
            }
        )
        let flow = DictationFlow(dependencies: dependencies)
        drainRelay.flow = flow
        self.init(appState: appState, flow: flow)
    }

    init(appState: AppState, flow: DictationFlow) {
        self.appState = appState
        self.flow = flow
        super.init()
        flow.delegate = self
        setupStatusItem()
        setupShortcut()
        setupCopyLastShortcut()
        setupGoModeShortcut()
        observeAppState()
        hud.updateHint(idleMessage)
        hud.isDebugMode = appState.isDebugMode
        if appState.isDebugMode {
            debugLogController.show()
            contextDebugController.show(appState: appState)
        }
        hud.showHint()
        preflightResources()
        AppContextDetector.createDefaultFileIfNeeded()
        ContextPromptStore.createDefaultFilesIfNeeded()
        requestMicrophonePermission()
        vxLog("[coordinator/init] Debug log: \(DebugLogger.shared.logFileURL.path)")
        updateChecker.onUpdateAvailable = { [weak self] update in
            self?.promptToInstall(update)
        }
        updateChecker.onNoUpdateAvailable = { [weak self] in
            self?.updateMenuView?.setState(.result("No updates available."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.updateMenuView?.setState(.idle)
            }
        }
        updateChecker.onCheckFailed = { [weak self] in
            self?.updateMenuView?.setState(.result("Could not check for updates."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.updateMenuView?.setState(.idle)
            }
        }
        updateChecker.onProgress = { [weak self] fraction in
            let pct = Int(fraction * 100)
            self?.updateMenuView?.setState(.result("Downloading… \(pct)%"))
        }
        if RuntimeProfile.current.disableUpdateCheck {
            vxLog("[coordinator/init] update check disabled by runtime profile")
        } else {
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                updateChecker.checkForUpdates()
            }
        }
        startTestControlServerIfConfigured()
        EventLog.shared?.record(kind: EventLog.Kind.launched, [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "pid": String(getpid()),
        ])
    }

    /// Opens the Unix-domain command socket when `VX_TEST_CONTROL` names one. A failure here
    /// is never fatal — the app runs exactly as it would without the channel, and the log
    /// line is the only way a harness learns the socket will never appear.
    private func startTestControlServerIfConfigured() {
        guard let socketPath = RuntimeProfile.current.testControlSocketPath else { return }
        let server = TestControlServer(socketPath: socketPath, handler: self)
        do {
            try server.start()
            testControlServer = server
        } catch {
            vxLog("[test-control] could not listen at \(socketPath): \(error)")
        }
    }

    public func invalidate() {
        testControlServer?.stop()
        testControlServer = nil
        shortcutMonitor?.stop()
        doubleTapMonitor?.stop()
        modifierMonitor?.stop()
        mouseButtonMonitor?.stop()
        copyLastMonitor?.stop()
        copyLastMouseButtonMonitor?.stop()
        goModeShortcutMonitor?.stop()
        goModeDoubleTapMonitor?.stop()
        goModeModifierMonitor?.stop()
        goModeMouseButtonMonitor?.stop()
        flow.invalidate()
        FnKeyTap.shared.deactivate()
    }

    private func observeAppState() {
        let configPublisher = Publishers.CombineLatest(appState.$shortcut, appState.$activationMode)

        configPublisher
            .dropFirst()
            .sink { [weak self] _ in self?.restartShortcutMonitor() }
            .store(in: &cancellables)
        configPublisher
            .sink { [weak self] _ in
                guard let self else { return }
                self.overlay.updateIdleMessage(self.idleMessage)
                self.hud.updateHint(self.idleMessage)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .vxPauseShortcut)
            .sink { [weak self] _ in
                self?.shortcutMonitor?.stop()
                self?.shortcutMonitor = nil
                self?.doubleTapMonitor?.stop()
                self?.doubleTapMonitor = nil
                self?.modifierMonitor?.stop()
                self?.modifierMonitor = nil
                self?.mouseButtonMonitor?.stop()
                self?.mouseButtonMonitor = nil
                self?.copyLastMonitor?.stop()
                self?.copyLastMonitor = nil
                self?.copyLastMouseButtonMonitor?.stop()
                self?.copyLastMouseButtonMonitor = nil
                self?.goModeShortcutMonitor?.stop()
                self?.goModeShortcutMonitor = nil
                self?.goModeDoubleTapMonitor?.stop()
                self?.goModeDoubleTapMonitor = nil
                self?.goModeModifierMonitor?.stop()
                self?.goModeModifierMonitor = nil
                self?.goModeMouseButtonMonitor?.stop()
                self?.goModeMouseButtonMonitor = nil
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .vxResumeShortcut)
            .sink { [weak self] _ in
                self?.restartShortcutMonitor()
                // Always tear down and recreate the copy-last monitor so it picks up any
                // shortcut change that occurred while shortcuts were paused.
                self?.copyLastMonitor?.stop()
                self?.copyLastMonitor = nil
                self?.copyLastMouseButtonMonitor?.stop()
                self?.copyLastMouseButtonMonitor = nil
                self?.setupCopyLastShortcut()
                self?.restartGoModeShortcutMonitor()
            }
            .store(in: &cancellables)

        appState.$copyLastShortcut
            .dropFirst()
            .sink { [weak self] newShortcut in
                // @Published fires in willSet, so appState.copyLastShortcut still holds the old
                // value here. Use the publisher-supplied newShortcut directly so the monitor is
                // set up for the new binding, not the old one.
                guard let self else { return }
                self.copyLastMonitor?.stop()
                self.copyLastMonitor = nil
                self.copyLastMouseButtonMonitor?.stop()
                self.copyLastMouseButtonMonitor = nil
                self.setupCopyLastShortcut(newShortcut)
            }
            .store(in: &cancellables)

        appState.$goModeShortcut
            .dropFirst()
            .sink { [weak self] _ in
                self?.restartGoModeShortcutMonitor()
            }
            .store(in: &cancellables)

        appState.$isPostProcessingEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, !enabled else { return }
                self.appState.usePostProcessingInGoMode = false
            }
            .store(in: &cancellables)

        flow.audioSource.levelPublisher
            .sink { [weak self] in self?.hud.updateLevel($0) }
            .store(in: &cancellables)

        appState.$autoDetectMode
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.autoDetectModeMenuItem?.state = enabled ? .on : .off
                let currentMode = self.appState.currentMode
                for (mode, item) in self.modeMenuItems {
                    item.state = (!enabled && mode == currentMode) ? .on : .off
                }
                vxLog("[coordinator] Auto-detect mode: \(enabled)")
            }
            .store(in: &cancellables)

        appState.$currentMode
            .dropFirst()
            .sink { [weak self] newMode in
                guard let self else { return }
                for (mode, item) in self.modeMenuItems {
                    item.state = (!self.appState.autoDetectMode && mode == newMode) ? .on : .off
                }
                self.profileMenuItem?.isEnabled = newMode == .code
                RuleStore.shared.reload()
                vxLog("[coordinator] Dictation mode changed to: \(newMode.rawValue)")
            }
            .store(in: &cancellables)

        appState.$currentCodeProfile
            .dropFirst()
            .sink { [weak self] newProfile in
                guard let self else { return }
                for (profile, item) in self.profileMenuItems {
                    item.state = profile == newProfile ? .on : .off
                }
                RuleStore.shared.reload()
                vxLog("[coordinator] Code profile changed to: \(newProfile.rawValue)")
            }
            .store(in: &cancellables)

        appState.$isDebugMode
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.hud.isDebugMode = enabled
                if enabled {
                    self.debugLogController.show()
                    self.contextDebugController.show(appState: self.appState)
                } else {
                    self.debugLogController.close()
                    self.contextDebugController.close()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .vxShowDebugLog)
            .sink { [weak self] _ in self?.debugLogController.show() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .vxInstallVersion)
            .sink { [weak self] notification in
                guard let version = notification.userInfo?["version"] as? String,
                      let urlString = notification.userInfo?["url"] as? String,
                      let url = URL(string: urlString) else { return }
                let update = AvailableUpdate(version: version, downloadURL: url)
                self?.promptToInstall(update, isRollback: true)
            }
            .store(in: &cancellables)
    }

    private func restartShortcutMonitor() {
        shortcutMonitor?.stop()
        shortcutMonitor = nil
        doubleTapMonitor?.stop()
        doubleTapMonitor = nil
        modifierMonitor?.stop()
        modifierMonitor = nil
        mouseButtonMonitor?.stop()
        mouseButtonMonitor = nil
        FnKeyTap.shared.deactivate()
        setupShortcut()
    }

    private func setupCopyLastShortcut(_ shortcut: Shortcut? = nil) {
        guard copyLastMonitor == nil, copyLastMouseButtonMonitor == nil else { return }

        switch shortcut ?? appState.copyLastShortcut {
        case .combo(let keyCode, let modifiers):
            let monitor = GlobalShortcutMonitor(keyCode: keyCode, modifiers: modifiers) { [weak self] event in
                guard event == .keyDown else { return }
                DispatchQueue.main.async { self?.copyLastTranscription() }
            }
            monitor.start()
            copyLastMonitor = monitor

        case .mouseButton(let button):
            let monitor = MouseButtonMonitor(button: button) { [weak self] event in
                guard event == .keyDown else { return }
                DispatchQueue.main.async { self?.copyLastTranscription() }
            }
            monitor.start()
            copyLastMouseButtonMonitor = monitor

        case .doubleTap, .modifier:
            break
        }
    }

    private func restartGoModeShortcutMonitor() {
        goModeShortcutMonitor?.stop()
        goModeShortcutMonitor = nil
        goModeDoubleTapMonitor?.stop()
        goModeDoubleTapMonitor = nil
        goModeModifierMonitor?.stop()
        goModeModifierMonitor = nil
        goModeMouseButtonMonitor?.stop()
        goModeMouseButtonMonitor = nil
        setupGoModeShortcut()
    }

    private func setupGoModeShortcut() {
        guard goModeShortcutMonitor == nil,
              goModeDoubleTapMonitor == nil,
              goModeModifierMonitor == nil,
              goModeMouseButtonMonitor == nil else { return }

        switch appState.goModeShortcut {
        case .combo(let keyCode, let modifiers):
            let monitor = GlobalShortcutMonitor(keyCode: keyCode, modifiers: modifiers) { [weak self] event in
                guard event == .keyDown else { return }
                DispatchQueue.main.async { self?.flow.toggleGoMode() }
            }
            monitor.start()
            goModeShortcutMonitor = monitor

        case .doubleTap(let modifier):
            let monitor = DoubleTapMonitor(modifier: modifier) { [weak self] event in
                guard event == .keyDown else { return }
                DispatchQueue.main.async { self?.flow.toggleGoMode() }
            }
            monitor.start()
            goModeDoubleTapMonitor = monitor

        case .modifier(let modifier):
            let monitor = ModifierKeyMonitor(modifier: modifier) { [weak self] event in
                guard event == .keyDown else { return }
                DispatchQueue.main.async { self?.flow.toggleGoMode() }
            }
            monitor.start()
            goModeModifierMonitor = monitor

        case .mouseButton(let button):
            let monitor = MouseButtonMonitor(button: button) { [weak self] event in
                guard event == .keyDown else { return }
                DispatchQueue.main.async { self?.flow.toggleGoMode() }
            }
            monitor.start()
            goModeMouseButtonMonitor = monitor
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "vx")
        item.button?.imagePosition = .imageOnly
        item.button?.alphaValue = 0.55
        item.button?.setAccessibilityIdentifier(AXID.statusItem)

        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let versionItem = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem.separator())

        let detectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detectionItem.isEnabled = false
        detectionItem.isHidden = !appState.autoDetectMode
        menu.addItem(detectionItem)
        detectionStatusMenuItem = detectionItem

        menu.addItem(withTitle: "Preferences", action: #selector(openPreferences), keyEquivalent: "")
        menu.items.last?.target = self
        menu.items.last?.setAccessibilityIdentifier(AXID.menuPreferences)

        // Mode submenu
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.setAccessibilityIdentifier(AXID.menuMode)
        let modeSubmenu = NSMenu(title: "Mode")
        let autoItem = NSMenuItem(title: "Auto-detect", action: #selector(toggleAutoDetectMode), keyEquivalent: "")
        autoItem.target = self
        autoItem.setAccessibilityIdentifier(AXID.menuModeAuto)
        autoItem.state = appState.autoDetectMode ? .on : .off
        modeSubmenu.addItem(autoItem)
        autoDetectModeMenuItem = autoItem
        modeSubmenu.addItem(NSMenuItem.separator())
        for mode in DictationMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setDictationMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.setAccessibilityIdentifier(AXID.menuMode(mode))
            item.state = (!appState.autoDetectMode && appState.currentMode == mode) ? .on : .off
            modeSubmenu.addItem(item)
            modeMenuItems[mode] = item
        }
        modeItem.submenu = modeSubmenu
        menu.addItem(modeItem)
        modeParentMenuItem = modeItem

        // Code Profile submenu — visible always, enabled only in code mode
        let profileItem = NSMenuItem(title: "Code Profile", action: nil, keyEquivalent: "")
        profileItem.setAccessibilityIdentifier(AXID.menuProfile)
        let profileSubmenu = NSMenu(title: "Code Profile")
        for profile in CodeProfile.allCases {
            let item = NSMenuItem(title: profile.displayName, action: #selector(setCodeProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            item.setAccessibilityIdentifier(AXID.menuProfile(profile))
            item.state = appState.currentCodeProfile == profile ? .on : .off
            profileSubmenu.addItem(item)
            profileMenuItems[profile] = item
        }
        profileItem.submenu = profileSubmenu
        profileItem.isEnabled = appState.currentMode == .code
        menu.addItem(profileItem)
        profileMenuItem = profileItem

        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = NSMenu(title: "History")
        historyItem.setAccessibilityIdentifier(AXID.menuHistory)
        menu.addItem(historyItem)
        historyMenuItem = historyItem
        menu.addItem(NSMenuItem.separator())
        let updateItem = NSMenuItem()
        let updateView = UpdateMenuItemView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        updateView.onTrigger = { [weak self] in self?.triggerUpdateCheck() }
        updateItem.view = updateView
        // The row is a custom view, so the identifier goes on both: the item is what AppKit
        // menu queries see, the view is what the accessibility tree walks.
        updateItem.setAccessibilityIdentifier(AXID.menuUpdate)
        updateView.setAccessibilityIdentifier(AXID.menuUpdate)
        menu.addItem(updateItem)
        updateMenuView = updateView
        menu.addItem(withTitle: "Relaunch vx", action: #selector(relaunchApp), keyEquivalent: "")
        menu.items.last?.target = self
        menu.items.last?.setAccessibilityIdentifier(AXID.menuRelaunch)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit vx", action: #selector(quit), keyEquivalent: "")
        menu.items.last?.target = self
        menu.items.last?.setAccessibilityIdentifier(AXID.menuQuit)

        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func setupShortcut() {
        FnKeyTap.shared.deactivate()

        switch appState.shortcut {
        case .combo(let keyCode, _) where keyCode == CGKeyCode(kVK_Function):
            let success: Bool
            if appState.activationMode == .holdToTalk {
                success = FnKeyTap.shared.activate(
                    onPress: { [weak self] in self?.flow.beginRecording() },
                    onRelease: { [weak self] in self?.flow.finishRecording() }
                )
            } else {
                success = FnKeyTap.shared.activate(
                    onPress: { [weak self] in self?.flow.toggleRecording() },
                    onRelease: { }
                )
            }
            if !success { promptForAccessibilityPermission() }

        case .combo(let keyCode, let modifiers):
            let monitor = GlobalShortcutMonitor(keyCode: keyCode, modifiers: modifiers) { [weak self] event in
                guard let self else { return }
                switch (self.appState.activationMode, event) {
                case (.holdToTalk, .keyDown): DispatchQueue.main.async { self.flow.beginRecording() }
                case (.holdToTalk, .keyUp):   DispatchQueue.main.async { self.flow.finishRecording() }
                case (.toggle,     .keyDown): DispatchQueue.main.async { self.flow.toggleRecording() }
                case (.toggle,     .keyUp):   break
                }
            }
            monitor.start()
            shortcutMonitor = monitor

        case .doubleTap(let modifier):
            // Double-tap is toggle-only; AppState guarantees it never pairs with hold-to-talk.
            let monitor = DoubleTapMonitor(modifier: modifier) { [weak self] event in
                guard event == .keyDown else { return }
                DispatchQueue.main.async { self?.flow.toggleRecording() }
            }
            monitor.start()
            doubleTapMonitor = monitor

        case .modifier(let modifier):
            let monitor = ModifierKeyMonitor(modifier: modifier) { [weak self] event in
                guard let self else { return }
                switch (self.appState.activationMode, event) {
                case (.holdToTalk, .keyDown): DispatchQueue.main.async { self.flow.beginRecording() }
                case (.holdToTalk, .keyUp):   DispatchQueue.main.async { self.flow.finishRecording() }
                case (.toggle,     .keyDown): DispatchQueue.main.async { self.flow.toggleRecording() }
                case (.toggle,     .keyUp):   break
                }
            }
            monitor.start()
            modifierMonitor = monitor

        case .mouseButton(let button):
            let monitor = MouseButtonMonitor(button: button) { [weak self] event in
                guard let self else { return }
                switch (self.appState.activationMode, event) {
                case (.holdToTalk, .keyDown): DispatchQueue.main.async { self.flow.beginRecording() }
                case (.holdToTalk, .keyUp):   DispatchQueue.main.async { self.flow.finishRecording() }
                case (.toggle,     .keyDown): DispatchQueue.main.async { self.flow.toggleRecording() }
                case (.toggle,     .keyUp):   break
                }
            }
            monitor.start()
            mouseButtonMonitor = monitor
        }
    }

    /// One JSONL record per user-triggered action, so a harness can assert "the menu item
    /// did what it says" without scraping the human-readable log. `value` carries the raw
    /// value the action selected, and is empty for actions that select nothing.
    private func recordMenuAction(_ action: String, value: String = "") {
        EventLog.shared?.record(kind: EventLog.Kind.menuAction, ["action": action, "value": value])
    }

    @objc private func openPreferences() {
        recordMenuAction("openPreferences")
        preferencesController.show(appState: appState)
    }

    @objc private func openHistory() {
        recordMenuAction("openHistory")
        historyController.show()
    }

    private func triggerUpdateCheck() {
        if let update = updateChecker.availableUpdate {
            promptToInstall(update)
        } else {
            updateMenuView?.setState(.checking)
            updateChecker.checkForUpdates()
        }
    }

    private func promptToInstall(_ update: AvailableUpdate, isRollback: Bool = false) {
        let alert = NSAlert()
        if isRollback {
            alert.messageText = "Install vx \(update.version)?"
            alert.informativeText = "This will replace the current version (\(updateChecker.currentVersion)) and restart the app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Install and Relaunch")
        } else {
            alert.messageText = "vx \(update.version) is available"
            alert.informativeText = "Would you like to update now? The app will restart automatically."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Update Now")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            if !isRollback { updateMenuView?.setState(.idle) }
            return
        }
        if !isRollback { updateMenuView?.setState(.result("Downloading… 0%")) }
        updateChecker.installUpdate(update)
    }

    @objc private func relaunchApp() {
        recordMenuAction("relaunchApp")
        let bundlePath = Bundle.main.bundleURL.path
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.5 && open '\(bundlePath)'"]
        task.launch()
        NSApp.terminate(nil)
    }

    @objc private func copyLastTranscription() {
        recordMenuAction("copyLastTranscription")
        guard let text = TranscriptionHistory.shared.entries.first?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        vxLog("[coordinator] Copied last transcription to clipboard")
        hud.showHint("Copied to clipboard", after: 0.0, duration: 1.5)
    }

    /// Builds the optional LLM post-processing config from `AppState`. Static so the
    /// production `DictationSettings` snapshot can call it before `self` exists.
    private static func makePostProcessingConfig(
        appState: AppState,
        ruleContext: RuleContext,
        enabled: Bool
    ) -> PostProcessingConfig? {
        guard enabled,
              appState.isPostProcessingEnabled,
              !appState.postProcessingAPIKey.isEmpty else { return nil }
        let perContextPrompt = ContextPromptStore.load(contextID: ruleContext.mode.promptID)
        let combinedCustomPrompt = [perContextPrompt, appState.postProcessingCustomPrompt]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return PostProcessingConfig(
            provider: appState.postProcessingProvider,
            model: appState.postProcessingModel,
            apiKey: appState.postProcessingAPIKey,
            customBaseURL: appState.postProcessingCustomBaseURL,
            customPrompt: combinedCustomPrompt,
            customDictionary: appState.customDictionary,
            contextHint: ruleContext.mode.postProcessingHint,
            smoothDisfluencies: appState.smoothDisfluencies
        )
    }

    @objc private func toggleAutoDetectMode() {
        let enabled = !appState.autoDetectMode
        recordMenuAction("toggleAutoDetectMode", value: String(enabled))
        appState.autoDetectMode = enabled
    }

    @objc private func setDictationMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? DictationMode else { return }
        recordMenuAction("setDictationMode", value: mode.rawValue)
        // Selecting a mode manually turns off auto-detect.
        appState.autoDetectMode = false
        appState.currentMode = mode
    }

    @objc private func setCodeProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? CodeProfile else { return }
        recordMenuAction("setCodeProfile", value: profile.rawValue)
        appState.currentCodeProfile = profile
    }

    @objc private func toggleDebugMode() {
        let enabled = !appState.isDebugMode
        recordMenuAction("toggleDebugMode", value: String(enabled))
        appState.isDebugMode = enabled
    }

    @objc private func quit() {
        recordMenuAction("quit")
        NSApp.terminate(nil)
    }

    private func updateStatusItemAppearance(isActive: Bool) {
        guard let button = statusItem?.button else { return }
        button.alphaValue = isActive ? 1.0 : 0.55
    }

    private func promptForAccessibilityPermission() {
        guard !accessibilityAlertShown else { return }
        accessibilityAlertShown = true
        hud.showHint("Enable Accessibility in Settings to use fn hotkey", after: 0.0, duration: 4.0)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enable Accessibility Permissions"
        alert.informativeText = "vx needs Accessibility permission to capture the fn key for push-to-talk. Grant permission in System Settings → Privacy & Security → Accessibility."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func installEscapeMonitorIfNeeded() {
        guard appState.activationMode == .toggle, escapeGlobalMonitor == nil, escapeLocalMonitor == nil else { return }

        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return event }
            DispatchQueue.main.async {
                guard let self, self.flow.isRecording else { return }
                self.flow.cancelRecording()
            }
            return nil
        }

        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return }
            DispatchQueue.main.async {
                guard let self, self.flow.isRecording else { return }
                self.flow.cancelRecording()
            }
        }
    }

    private func installGoModeEscapeMonitor() {
        guard escapeGlobalMonitor == nil, escapeLocalMonitor == nil else { return }

        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return event }
            DispatchQueue.main.async {
                guard let self, self.flow.isGoModeActive else { return }
                self.flow.stopGoMode(finishActive: false)
            }
            return nil
        }

        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return }
            DispatchQueue.main.async {
                guard let self, self.flow.isGoModeActive else { return }
                self.flow.stopGoMode(finishActive: false)
            }
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeLocalMonitor = nil
        }
        if let monitor = escapeGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeGlobalMonitor = nil
        }
    }

    /// Installs an escape key monitor for the processing phase (works regardless of activation mode).
    /// Call this after recording stops and transcriptionTask is about to start.
    private func installProcessingEscapeMonitor() {
        guard escapeGlobalMonitor == nil, escapeLocalMonitor == nil else { return }

        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return event }
            DispatchQueue.main.async {
                guard let self, self.flow.isTranscribing else { return }
                self.flow.cancelTranscription()
            }
            return nil
        }

        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return }
            DispatchQueue.main.async {
                guard let self, self.flow.isTranscribing else { return }
                self.flow.cancelTranscription()
            }
        }
    }

    private func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            vxLog("[coordinator/permission] Already determined: \(status.rawValue)")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            vxLog("[coordinator/permission] Granted: \(granted)")
        }
    }

    private func preflightResources() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let backendURL = self.appState.backendURL
            let modelURL = self.appState.modelURL
            do {
                try FileValidator.validate(backendURL: backendURL, modelURL: modelURL)
            } catch {
                DispatchQueue.main.async {
                    self.logFailure(error.localizedDescription, dismissAfter: 4.0)
                }
            }
        }
    }
}

// MARK: - DictationFlowDelegate

/// Turns Flow Events into everything AppKit: ducking, sounds, the HUD, the status item,
/// escape monitors, and the context inspector. The flow itself touches none of these.
extension AppCoordinator: DictationFlowDelegate {
    func flow(_ flow: DictationFlow, didEmit event: DictationFlowEvent) {
        vxLog("[flow/event] \(event.name)")
        EventLog.shared?.record(event)

        switch event {
        case .captureWillStart(let goMode):
            handleCaptureWillStart(goMode: goMode)

        case .recordingStarted:
            // Capture is running and the tap is installed — safe to duck Bluetooth now.
            if deferredBluetoothDuck {
                deferredBluetoothDuck = false
                let t0 = Date()
                volumeController.duck(to: Float(appState.duckVolume))
                vxLog("[coordinator/beginRecording] duck (BT, post-engine): \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))ms")
            }
            if appState.soundEffectsEnabled { soundPlayer.play("start.mp3") }
            updateStatusItemAppearance(isActive: true)
            installEscapeMonitorIfNeeded()
            hud.showListening(
                onCancel: { [weak self] in self?.flow.cancelRecording() },
                onStop: { [weak self] in self?.flow.finishRecording() }
            )

        case .recordingWillStop:
            // Play before the source stops — on Bluetooth devices (AirPods) the device
            // transitions from SCO/HFP back to A2DP after teardown, and during that
            // handoff the device reports as muted, silencing any sound played after stop.
            if appState.soundEffectsEnabled { soundPlayer.play("transcribe.mp3") }

        case .transcribing:
            removeEscapeMonitor()
            updateStatusItemAppearance(isActive: false)
            if appState.duckAudioWhileRecording {
                let t0 = Date()
                volumeController.restore()
                vxLog("[coordinator/finishRecording] restore: \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))ms")
            }
            hud.flashStatus(.processing, duration: 1.5, autoHide: false)
            // Install the escape monitor for the processing phase so the user can bail
            // while transcription is running (works for both hold-to-talk and toggle).
            installProcessingEscapeMonitor()

        case .transcriptReceived:
            break

        case .processed(let mode, _, _, let ruleCount, _):
            guard !flow.eventContext.goMode else { break }
            let context = flow.eventContext
            contextDebugController.model.updateLastRecording(
                bundleID: context.target?.bundleID,
                appName: context.target?.name,
                context: context.detectedContext,
                mode: DictationMode(rawValue: mode) ?? appState.currentMode,
                ruleCount: ruleCount
            )

        case .textInserted, .submittedWithoutText:
            guard !flow.eventContext.goMode else { break }
            removeEscapeMonitor()
            hud.completeProcessing()

        case .noSpeech:
            guard !flow.eventContext.goMode else { break }
            removeEscapeMonitor()
            logFailure("No speech detected.", dismissAfter: 2.0)

        case .failed(let message):
            deferredBluetoothDuck = false
            if !flow.eventContext.goMode {
                removeEscapeMonitor()
                if appState.duckAudioWhileRecording { volumeController.restore() }
            }
            logFailure(message, dismissAfter: flow.lastFailureDismissAfter)

        case .cancelled:
            deferredBluetoothDuck = false
            removeEscapeMonitor()
            updateStatusItemAppearance(isActive: false)
            if appState.duckAudioWhileRecording { volumeController.restore() }
            hud.flashStatus(.cancelled, duration: 1.0)

        case .goModeStarted:
            updateStatusItemAppearance(isActive: true)
            installGoModeEscapeMonitor()
            if appState.soundEffectsEnabled { soundPlayer.play("start.mp3") }
            hud.showListening(
                style: .goMode,
                onCancel: { [weak self] in self?.flow.stopGoMode(finishActive: false) },
                onStop: { [weak self] in self?.flow.stopGoMode(finishActive: true) }
            )

        case .goModeStopped(let cancelled):
            removeEscapeMonitor()
            updateStatusItemAppearance(isActive: flow.isRecording)
            if cancelled {
                hud.flashStatus(.cancelled, duration: 1.0)
            } else {
                hud.hide()
            }

        case .audioSourceDrained:
            break
        }
    }

    /// AudioObjectSetPropertyData on a Bluetooth output device races with AVAudioEngine's
    /// installTap and causes an uncatchable NSException. Duck non-BT devices before engine
    /// setup (so the fade starts immediately on key press); for BT, defer until after
    /// capture is running, when the tap is already installed and the race window is closed.
    /// Go mode never ducks.
    private func handleCaptureWillStart(goMode: Bool) {
        deferredBluetoothDuck = false
        guard !goMode, appState.duckAudioWhileRecording else { return }
        if AudioCapture.isBluetoothDefaultOutput() {
            deferredBluetoothDuck = true
        } else {
            let t0 = Date()
            volumeController.duck(to: Float(appState.duckVolume))
            vxLog("[coordinator/beginRecording] duck: \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))ms")
        }
    }
}

// MARK: - TestControlHandler

extension AppCoordinator: TestControlHandler {

    /// Snapshot returned by the `state` command. Encoded with sorted keys so a harness can
    /// diff two replies byte for byte.
    private struct ControlState: Encodable {
        struct HUD: Encodable {
            let state: String
            let style: String
        }

        let isRecording: Bool
        let isGoModeActive: Bool
        let isTranscribing: Bool
        let hud: HUD
        let mode: String
        let profile: String
        let autoDetect: Bool
    }

    /// Performs one Test Control Channel command. Always on the main thread, and never
    /// reachable unless `VX_TEST_CONTROL` opened the socket in the first place.
    public func handle(_ command: TestControlCommand) -> TestControlReply {
        switch command {
        case .ping:
            return .ok

        case .state:
            return stateReply()

        case .begin:
            flow.beginRecording()
            return .ok

        case .finish:
            flow.finishRecording()
            return .ok

        case .cancel:
            flow.cancelRecording()
            return .ok

        case .toggle:
            flow.toggleRecording()
            return .ok

        case .goStart:
            flow.startGoMode()
            return .ok

        case .goStop:
            flow.stopGoMode(finishActive: true)
            return .ok

        case .goCancel:
            flow.stopGoMode(finishActive: false)
            return .ok

        case .hud(let argument):
            guard hud.applyHUDTestCommand(argument) else {
                return .error("unknown hud style '\(argument)'")
            }
            return .ok

        case .open(let surface, let tab):
            return openSurface(surface, tab: tab)

        case .quit:
            // Reply first: terminating inside the handler would tear the socket down before
            // the client ever reads the "ok".
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return .ok
        }
    }

    private func stateReply() -> TestControlReply {
        let snapshot = ControlState(
            isRecording: flow.isRecording,
            isGoModeActive: flow.isGoModeActive,
            isTranscribing: flow.isTranscribing,
            hud: ControlState.HUD(
                state: hud.currentState.rawValue,
                style: hud.currentVisualStyle.rawValue
            ),
            mode: appState.currentMode.rawValue,
            profile: appState.currentCodeProfile.rawValue,
            autoDetect: appState.autoDetectMode
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else {
            return .error("could not encode state")
        }
        return .okJSON(json)
    }

    private func openSurface(_ surface: String, tab: String?) -> TestControlReply {
        switch surface {
        case "preferences":
            if let tab {
                guard PreferencesView.allTabIDs.contains(tab) else {
                    return .error("unknown preferences tab '\(tab)'")
                }
                // Set before showing so a first open picks the tab up in `onAppear`, and an
                // already-open window picks it up through the publisher.
                appState.requestedPreferencesTab = tab
            }
            openPreferences()
            return .ok

        case "history":
            openHistory()
            return .ok

        case "debugLog":
            NotificationCenter.default.post(name: .vxShowDebugLog, object: nil)
            return .ok

        case "contextInspector":
            contextDebugController.show(appState: appState)
            return .ok

        default:
            return .error("unknown window '\(surface)'")
        }
    }
}

enum FileValidator {
    static func validate(backendURL: URL, modelURL: URL) throws {
        let fm = FileManager.default
        let backendPath = backendURL.path
        let modelPath = modelURL.path

        if !fm.fileExists(atPath: backendPath) || !fm.isExecutableFile(atPath: backendPath) {
            throw TranscriberError.missingBinary
        }

        if !fm.fileExists(atPath: modelPath) {
            throw TranscriberError.missingModel
        }
    }
}

private final class PreferencesController {
    private weak var window: NSWindow?

    func show(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: PreferencesView(appState: appState))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "vx Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 480, height: 460)
        window.setContentSize(NSSize(width: 480, height: 600))
        window.center()
        window.applyAXID(AXID.prefsWindow)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        EventLog.shared?.record(kind: EventLog.Kind.window, ["title": window.title, "event": "opened"])
    }
}

extension Notification.Name {
    static let vxPauseShortcut = Notification.Name("voice.vx.pauseShortcut")
    static let vxResumeShortcut = Notification.Name("voice.vx.resumeShortcut")
    static let vxShowDebugLog = Notification.Name("voice.vx.showDebugLog")
    static let vxInstallVersion = Notification.Name("voice.vx.installVersion")
}

extension AppCoordinator: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
        rebuildHistorySubmenu()
        updateDynamicMenuLabels()
    }

    private func updateDynamicMenuLabels() {
        // Detection status item: show frontmost app and detected context.
        detectionStatusMenuItem?.isHidden = !appState.autoDetectMode
        if appState.autoDetectMode {
            let appName = contextDebugController.model.frontmostAppName
            let detectedCtxForStatus = contextDebugController.model.detectedContext
            if case .general = detectedCtxForStatus {
                detectionStatusMenuItem?.title = "\(appName) — no match"
            } else {
                detectionStatusMenuItem?.title = "\(appName) — \(detectedCtxForStatus.displayName)"
            }
        }

        // Auto-detect item: show the currently detected mode in parens.
        let detectedCtx = contextDebugController.model.detectedContext
        if case .general = detectedCtx {
            autoDetectModeMenuItem?.title = "Auto-detect (no match)"
        } else {
            autoDetectModeMenuItem?.title = "Auto-detect (\(detectedCtx.dictationMode.displayName))"
        }

        // Mode parent: show the effective mode — auto-detected or manually selected.
        let effectiveMode: DictationMode
        if appState.autoDetectMode, case .general = detectedCtx {
            effectiveMode = appState.currentMode
        } else if appState.autoDetectMode {
            effectiveMode = detectedCtx.dictationMode
        } else {
            effectiveMode = appState.currentMode
        }
        if effectiveMode == .code {
            let profile = appState.currentCodeProfile
            modeParentMenuItem?.title = "Mode (\(effectiveMode.displayName) / \(profile.displayName))"
        } else {
            modeParentMenuItem?.title = "Mode (\(effectiveMode.displayName))"
        }

        // Code Profile parent: always show the current profile.
        profileMenuItem?.title = "Code Profile (\(appState.currentCodeProfile.displayName))"
    }

    private func rebuildHistorySubmenu() {
        guard let submenu = historyMenuItem?.submenu else { return }
        submenu.removeAllItems()

        let entries = Array(TranscriptionHistory.shared.entries.prefix(5))
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for (index, entry) in entries.enumerated() {
                let maxLen = 40
                let preview = entry.text.count > maxLen ? String(entry.text.prefix(maxLen)) + "…" : entry.text
                let item = NSMenuItem(title: preview, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.setAccessibilityIdentifier(AXID.menuHistoryEntry(index))
                submenu.addItem(item)
            }
        }

        submenu.addItem(NSMenuItem.separator())
        let showAll = NSMenuItem(title: "Show All", action: #selector(openHistory), keyEquivalent: "")
        showAll.target = self
        showAll.setAccessibilityIdentifier(AXID.menuHistoryShowAll)
        submenu.addItem(showAll)
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        recordMenuAction("copyHistoryEntry")
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        vxLog("[coordinator] Copied history entry to clipboard")
        hud.showHint("Copied to clipboard", after: 0.0, duration: 1.5)
    }
}

// MARK: - UpdateMenuItemView

/// Custom NSMenuItem view for "Check for Updates…". Keeps the status bar menu open while
/// a check is in progress so the user gets inline feedback without a separate window.
final class UpdateMenuItemView: NSView {
    enum State {
        case idle
        case checking
        case result(String)
    }

    var onTrigger: (() -> Void)?

    private let label: NSTextField
    private let highlight: NSVisualEffectView
    private var spinnerTimer: Timer?
    private var spinnerPhase = 0
    private var state: State = .idle

    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    override init(frame: NSRect) {
        label = NSTextField(labelWithString: "Check for Updates…")
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.drawsBackground = false

        highlight = NSVisualEffectView()
        highlight.material = .selection
        highlight.state = .active
        highlight.isHidden = true
        highlight.autoresizingMask = [.width, .height]

        super.init(frame: frame)
        autoresizingMask = .width
        addSubview(highlight)
        addSubview(label)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    func setState(_ newState: State) {
        state = newState
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        switch newState {
        case .idle:
            label.stringValue = "Check for Updates…"
        case .checking:
            spinnerPhase = 0
            label.stringValue = "\(Self.spinnerFrames[0])  Checking…"
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.spinnerPhase = (self.spinnerPhase + 1) % Self.spinnerFrames.count
                self.label.stringValue = "\(Self.spinnerFrames[self.spinnerPhase])  Checking…"
            }
            RunLoop.main.add(timer, forMode: .common)
            spinnerTimer = timer
        case .result(let message):
            label.stringValue = message
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        highlight.frame = bounds
        let padding: CGFloat = 14
        label.sizeToFit()
        label.frame = NSRect(
            x: padding,
            y: (bounds.height - label.frame.height) / 2,
            width: bounds.width - padding * 2,
            height: label.frame.height
        )
    }

    override func mouseEntered(with event: NSEvent) {
        highlight.isHidden = false
        label.textColor = .selectedMenuItemTextColor
    }

    override func mouseExited(with event: NSEvent) {
        highlight.isHidden = true
        label.textColor = .labelColor
    }

    override func mouseUp(with event: NSEvent) {
        // Only trigger when idle — ignore clicks during an in-progress check or result display.
        guard case .idle = state else { return }
        onTrigger?()
    }
}
