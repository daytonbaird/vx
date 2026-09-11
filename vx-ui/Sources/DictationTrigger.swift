import Foundation

/// Translates raw shortcut press/release into dictation intent, so every binding kind — mouse
/// button, fn, modifier, key combo — behaves identically. All state is main-queue-only: public
/// entry points immediately hop there because shortcut monitors deliver events on their own queues.
/// In hold-to-talk mode it also recognises the latch gesture: a second press arriving soon after a
/// short press keeps recording after the button is released, until the next press ends it.
final class DictationTrigger {
    private let doubleTapWindow: TimeInterval
    private let mode: () -> ActivationMode
    private let onBegin: () -> Void
    private let onFinish: () -> Void
    private let onToggle: () -> Void
    private let onLatch: () -> Void

    private var pressTime: Date?
    private var pendingStop: DispatchWorkItem?
    /// Invalidates delayed work that Dispatch may invoke after cancellation.
    private var pendingStopToken = 0
    private var isLatched = false

    init(
        doubleTapWindow: TimeInterval = 0.4,
        mode: @escaping () -> ActivationMode,
        onBegin: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onLatch: @escaping () -> Void
    ) {
        self.doubleTapWindow = doubleTapWindow
        self.mode = mode
        self.onBegin = onBegin
        self.onFinish = onFinish
        self.onToggle = onToggle
        self.onLatch = onLatch
    }

    func press() {
        DispatchQueue.main.async { [weak self] in
            self?.handlePress()
        }
    }

    func release() {
        DispatchQueue.main.async { [weak self] in
            self?.handleRelease()
        }
    }

    /// Drops any pending stop and ends a latched recording. Call when the binding changes or
    /// shortcuts are paused, so a latch cannot outlive the monitor that created it.
    func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.handleReset()
        }
    }

    private func handlePress() {
        guard mode() == .holdToTalk else {
            onToggle()
            return
        }

        if isLatched {
            isLatched = false
            cancelPendingStop()
            onFinish()
            return
        }

        if pendingStop != nil {
            cancelPendingStop()
            isLatched = true
            onLatch()
            return
        }

        pressTime = Date()
        onBegin()
    }

    private func handleRelease() {
        guard mode() == .holdToTalk, !isLatched else { return }

        guard let pressTime else { return }
        self.pressTime = nil
        if Date().timeIntervalSince(pressTime) < doubleTapWindow {
            // Only short presses defer their finish, preserving immediate release behavior for
            // ordinary holds while leaving time for a second press to latch the recording.
            pendingStopToken += 1
            let token = pendingStopToken
            let stop = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingStopToken == token else { return }
                self.pendingStop = nil
                self.onFinish()
            }
            pendingStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: stop)
        } else {
            onFinish()
        }
    }

    private func handleReset() {
        // Anything this trigger started and has not yet ended has to end here: a latch, a
        // deferred stop still waiting on a possible second press, or a press still held.
        // Dropping any of those would leave a recording running with no monitor left to
        // stop it. Finishing when nothing is recording is harmless — the flow ignores it.
        let hasUnfinishedRecording = isLatched || pendingStop != nil || pressTime != nil
        cancelPendingStop()
        pressTime = nil
        isLatched = false
        if hasUnfinishedRecording { onFinish() }
    }

    private func cancelPendingStop() {
        pendingStop?.cancel()
        pendingStop = nil
        pendingStopToken += 1
    }
}
