# vx-e2e

A black-box end-to-end harness for the vx menubar app.

It does not import a single line of vx's code. It launches the **built app bundle**
(`vx-ui/build/vx.app`) as a subprocess, drives it through a Unix-socket control
channel and the macOS Accessibility API, and asserts against the app's JSONL event
log, its UserDefaults, and — for the paste scenarios — the contents of a real
TextEdit document. If a scenario passes here, the shipped app really does that thing.

## Running it

```bash
cd app/Tools/vx-e2e
swift build && swift test          # the harness's own unit tests (pure, no TCC)

swift run vx-e2e preflight         # check the environment first
swift run vx-e2e list              # what scenarios exist
swift run vx-e2e run happy-path --kill-existing
swift run vx-e2e run all --kill-existing --hotkey
```

Usually you want the orchestrator instead, which packages the app first:

```bash
Scripts/verify.sh e2e              # from the workspace root
Scripts/verify.sh visual
Scripts/verify.sh all
```

### Options

| Flag | Meaning |
|---|---|
| `--kill-existing` | Quit the running `vx` first, relaunch the user's copy afterwards. Effectively required — see below. |
| `--hotkey` | Enable scenarios that post real ⌥Space `CGEvent`s. Needs Input Monitoring. |
| `--keep-app` | Leave the app under test running when the run ends (for poking at it). |
| `--out <dir>` | Artifact directory. Default: `vx-ui/build/verify/<yyyyMMdd-HHmmss>/`. |
| `--app <bundle>` | A different `vx.app` to drive. |
| `--fixtures <dir>` | A different audio fixtures directory. |
| `--baseline <dir>` | Baseline screenshots for `visual`. Diffs are advisory and never fail a run. |

## How it works

**One instance at a time.** vx installs a `CGEventTap` for its hotkey on launch. Two
instances fight over it and both behave erratically, so the harness quits any running
`vx` before it starts (`--kill-existing`), remembers the bundle path it displaced, and
`open -a`s it again on teardown. Without `--kill-existing` the run refuses to start
while another `vx` is up.

**Hermetic by construction.** Every run gets its own `VX_DEFAULTS_SUITE` (a throwaway
UserDefaults domain, deleted on teardown) and its own `VX_CONFIG_HOME` (a fresh `~`
substitute holding `.vx/`, `Library/Logs/vx-debug.log`, and the models directory). It
never reads or writes the user's real preferences or logs.

**Deterministic audio.** `VX_AUDIO_SOURCE` replaces the microphone with a real-time
WAV replay, so `short-phrase.wav` produces the same transcript every run and there is
no mic permission or ambient noise in the loop. The source stays "open" after the
file drains, so scenarios wait for `audioSourceDrained` and then stop the recording
themselves rather than racing playback.

**Launched directly, not with `open`.** All of the above is environment-based, and
`open` hands the launch to LaunchServices, which does not pass environment through.
So the harness runs `vx.app/Contents/MacOS/vx` itself.

**Observation, not screen-scraping.** Assertions read the JSONL event log
(`VX_EVENT_LOG`), which carries both flow events
(`{"event":{"textInserted":{"_0":"…"}},"t":"…"}`) and non-flow records
(`{"kind":"hudState","fields":{…},"t":"…"}`). Parsing is lenient: an unknown case or
kind is data, so the app can add events without breaking a scenario.

## Permissions

**macOS attaches privacy grants to the *responsible process* — the terminal, IDE, or
agent host that launched `vx-e2e` — not to the `vx-e2e` binary.** Re-signing or moving
the binary changes nothing. Grant the parent app and restart it.

| Grant | Needed for | Pane |
|---|---|---|
| Accessibility | menu and Preferences scenarios (`AXUIElement`) | Privacy & Security ▸ Accessibility |
| Input Monitoring | `hotkey` (`CGEvent.post`) | Privacy & Security ▸ Input Monitoring |
| Screen Recording | `visual` (`screencapture`) | Privacy & Security ▸ Screen Recording |
| Automation ▸ TextEdit | the TextEdit paste scenarios (osascript) | Privacy & Security ▸ Automation |

`vx-e2e preflight` prints exactly which of these are missing and which pane fixes
each; it exits non-zero only when a **hard** requirement is absent. Scenarios whose
grant is missing report as `skipped`, not `failed`.

One more preflight check worth understanding: if `vx.app` is **ad-hoc signed**
(`codesign -dv` says `Signature=adhoc`), macOS treats every rebuild as a new app and
drops its TCC grants — the app then silently loses Accessibility mid-suite and the
hotkey stops working. Install the `vx-local-dev` certificate
(`Scripts/create-signing-cert.sh`) or a Developer ID.

## Scenarios

| Name | What it proves |
|---|---|
| `happy-path` | begin → drain → finish → transcript → insertion, and the flow event ordering |
| `happy-path-textedit` | the same, landing real text in a real TextEdit document |
| `hotkey` | a real ⌥Space hold-to-talk drives the whole flow (`--hotkey`) |
| `cancel` | `cancel` emits `cancelled` and never pastes |
| `menu-mode` | Mode ▸ Code persists `vx.dictation-mode` and shows a checkmark |
| `menu-history` | a transcript reaches History ▸ entry 0; Show All opens the window |
| `prefs` | a Preferences toggle writes through to UserDefaults, then restores |
| `error-backend` | a broken `VX_BACKEND_PATH` surfaces `failed`, an error HUD, and a log line |
| `go-mode` | Go Mode segments `two-utterances.wav` into two insertions |
| `visual` | screenshots every HUD style, Preferences tab, and auxiliary window |


### Every dictation needs a paste target

vx inserts by posting Cmd+V to **whatever app is frontmost**. A scenario that starts a
dictation without a target therefore types the transcript into whatever the user is
looking at — their terminal, their editor. So `PasteTarget.acquire()` opens a scratch
TextEdit document and holds it frontmost, and the guard is not optional:
`ctx.control` is a `GuardedControl` that refuses `begin`, `toggle` and `go start`
unless a target is held, and `Keys.optionSpaceDown()` throws for the same reason.
Release with `defer { target.release() }`; the runner also releases any straggler
after every scenario. Only `visual` is exempt — it drives the HUD and never dictates.

That is also why every scenario that can paste declares `requiresAutomation`: with no
Automation ▸ TextEdit grant there is nowhere safe to paste, so those scenarios report
`skipped` rather than running and leaking text.

## Artifacts

Each run writes to `--out` (default `vx-ui/build/verify/<timestamp>/`):

```
report.md          human-readable results
summary.json       machine-readable results
events.jsonl       the app's raw event log
app-stdout.log     the app's stdout/stderr
home/              the hermetic VX_CONFIG_HOME (including vx-debug.log)
<scenario>/        per-scenario artifacts: events.txt, screenshots, diagnostics.txt
```

`visual/index.md` is a browsable catalogue of every captured surface.

## Adding a scenario

1. Add a `struct` conforming to `Scenario` in `Sources/vx-e2e/Scenarios/`:

```swift
struct MyScenario: Scenario {
    static let name = "my-scenario"
    static let summary = "One line for `vx-e2e list`"

    // Override only what applies:
    // static var requiresHotkey: Bool { true }            // needs --hotkey
    // static var requiresScreenCapture: Bool { true }     // needs Screen Recording
    // static var requiresAutomation: Bool { true }        // drives TextEdit
    // static var mutatesLaunchEnvironment: Bool { true }  // relaunches the app

    func run(_ ctx: ScenarioContext) throws {
        // Required before any command that starts a dictation — see the paste-target
        // section above. Omit it for a scenario that never records.
        let target = try ctx.acquirePasteTarget()
        defer { target.release() }

        let mark = ctx.events.mark()
        try ctx.control.require("begin")
        try ctx.events.waitForFlow("recordingStarted", since: mark, timeout: 8)
        try Expect.contains(/* … */, "quick brown fox", "transcript")
        ctx.write(ctx.events.transcript(since: mark), to: "events.txt")
    }
}
```

2. Register it in `Registry.all` in `Runner.swift` — cheap control-driven scenarios
   go before slow AX/screenshot ones so a broken build fails fast.

3. Add its name to `testEveryScenarioMentionedInThePlanIsRegistered` if it is part of
   the contract you want defended.

### Guidelines

- **Scope every assertion with `ctx.events.mark()`.** Scenarios share one app process
  and one append-only log; without a mark you will match a previous scenario's event.
- **Throw `ScenarioSkipped` for a missing grant, `ScenarioFailure` for a real defect.**
  Skips do not fail the run; failures do.
- **Never touch `NSPasteboard`.** vx restores the user's clipboard about a second
  after pasting, so reading or writing it races the restore and can clobber real user
  data. Assert on the target app's document text instead.
- **Acquire a `PasteTarget` before any `begin`/`go start`/hotkey press**, and set
  `requiresAutomation`. Without one the transcript is pasted into whatever the user is
  looking at; the guard turns that into a scenario failure rather than a surprise.
- **Set `mutatesLaunchEnvironment`** if you call `ctx.relaunchApp(…)`; the runner then
  restores the default launch before the next scenario.
- **Compare transcripts with `Normalize.text`** (via `Expect.contains`) — Whisper's
  punctuation and casing are not stable enough for an exact match.
