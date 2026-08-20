// zaatarbar - Zaatar native menu bar app (replaces the SwiftBar rec.5s.sh plugin)
//
// States (title): idle "◎" / recording "● Nm" red / stray "●!" orange /
//                 transcribing "◎…" / transcription FAILED "◎!" red.
// Menu shells out to the existing `rec` CLI. Failure detection: a
// transcribe-<base>.log with no running transcribe.sh process and no "Done:"
// line means the pipeline died mid-flight -> alert once via zaatarprompt,
// keep a Retry/Dismiss entry in the menu.
//
// Build: swiftc -O main.swift -o zaatarbar -framework AppKit -framework ServiceManagement

import AppKit
import AVFoundation
import Darwin
import ServiceManagement

let fm = FileManager.default
let home = NSHomeDirectory()

// Config: plain KEY="value" lines in ~/.config/zaatar/config (same file the
// shell scripts source). $HOME is the only substitution supported.
func zaatarConfig() -> [String: String] {
    var cfg: [String: String] = [:]
    let path = ProcessInfo.processInfo.environment["ZAATAR_CONFIG"]
        ?? "\(home)/.config/zaatar/config"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return cfg }
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq])
        let value = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "$HOME", with: home)
        cfg[key] = value
    }
    return cfg
}
let zcfg = zaatarConfig()

let stateDir = zcfg["ZAATAR_STATE_DIR"] ?? "\(home)/.local/state/zaatar"
let recDir = zcfg["ZAATAR_REC_DIR"] ?? "\(home)/Recordings/meetings"
// Zaatar repo root: from config (needed when running as an .app bundle),
// falling back to argv[0] at <root>/native/zaatarbar/zaatarbar.
let toolDir: String = {
    if let d = zcfg["ZAATAR_DIR"], fm.fileExists(atPath: d + "/bin/zaatar") { return d }
    // argv[0] walkup: works when running from the repo tree directly
    let fromArgv = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    if fm.fileExists(atPath: fromArgv + "/bin/zaatar") { return fromArgv }
    // Common install location (install.sh default)
    let local = "\(home)/.local/share/zaatar"
    if fm.fileExists(atPath: local + "/bin/zaatar") { return local }
    // Homebrew
    if let brew = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? (fm.fileExists(atPath: "/opt/homebrew/opt/zaatar/libexec") ? "/opt/homebrew" : nil) {
        let hb = "\(brew)/opt/zaatar/libexec"
        if fm.fileExists(atPath: hb + "/bin/zaatar") { return hb }
    }
    return fromArgv  // best effort
}()
let recCmd = "\(toolDir)/bin/rec"
let transcribeCmd = "\(toolDir)/bin/transcribe.sh"
let viewerCmd = "\(toolDir)/native/zaatarviewer/zaatarviewer"
let zpromptCmd = "\(toolDir)/native/zaatarprompt/zaatarprompt"

@discardableResult
func sh(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func shAsync(_ cmd: String) {
    DispatchQueue.global().async { sh(cmd) }
}

func readFile(_ path: String) -> String? {
    (try? String(contentsOfFile: path, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func hhmm(_ seconds: Int) -> String {
    String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60)
}

// MARK: - State scan

struct Snapshot {
    var recording: (name: String, elapsed: Int)? = nil
    var strays: [(pid: String, wav: String)] = []
    var transcribing: [(base: String, elapsed: Int)] = []
    var failed: [String] = []
    var calFails = 0
}

func scan() -> Snapshot {
    var s = Snapshot()
    var knownPid = ""

    // Active recording: rec.pid alive
    if let pidStr = readFile("\(stateDir)/rec.pid"), let pid = Int32(pidStr), kill(pid, 0) == 0 {
        knownPid = pidStr
        var name = ((readFile("\(stateDir)/rec.meta") ?? "") as NSString).lastPathComponent
        if name.hasSuffix(".wav") { name.removeLast(4) }
        name = name.replacingOccurrences(of: "^[0-9-]+-[0-9]{4}-", with: "", options: .regularExpression)
        let mtime = (try? fm.attributesOfItem(atPath: "\(stateDir)/rec.pid")[.modificationDate] as? Date)
            .flatMap { $0 } ?? Date()
        s.recording = (name.isEmpty ? "meeting" : name, Int(Date().timeIntervalSince(mtime)))
    }

    // Stray recorders: capture processes not matching the known pid
    for line in sh("pgrep -f '(ffmpeg|zaatarcap) .*\(recDir)'").split(separator: "\n") {
        let p = String(line)
        if p.isEmpty || p == knownPid { continue }
        let cmd = sh("ps -p \(p) -o command=")
        let wav = cmd.range(of: "\(recDir)/[^ ]*\\.wav", options: .regularExpression)
            .map { (String(cmd[$0]) as NSString).lastPathComponent } ?? "unknown.wav"
        s.strays.append((p, wav))
    }

    // Running transcriptions
    var runningBases = Set<String>()
    for line in sh("ps ax -o command= | grep '[t]ranscribe.sh'").split(separator: "\n") {
        if let r = line.range(of: "/[^/ ]+\\.wav", options: .regularExpression) {
            var b = (String(line[r]) as NSString).lastPathComponent
            b.removeLast(4)
            runningBases.insert(b)
        }
    }

    // Per-recording logs (last 7 days): running / done / FAILED
    let cutoff = Date().addingTimeInterval(-7 * 86400)
    for f in (try? fm.contentsOfDirectory(atPath: stateDir)) ?? [] {
        guard f.hasPrefix("transcribe-"), f.hasSuffix(".log") else { continue }
        let base = String(f.dropFirst("transcribe-".count).dropLast(4))
        let logPath = "\(stateDir)/\(f)"
        let attrs = try? fm.attributesOfItem(atPath: logPath)
        let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
        guard mtime > cutoff else { continue }
        if runningBases.contains(base) {
            let birth = attrs?[.creationDate] as? Date ?? mtime
            s.transcribing.append((base, Int(Date().timeIntervalSince(birth))))
            continue
        }
        if fm.fileExists(atPath: "\(stateDir)/failed-dismissed-\(base)") { continue }
        let content = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        if !content.hasPrefix("Done:") && !content.contains("\nDone:") {
            s.failed.append(base)
        }
    }
    s.failed.sort()

    // Consecutive calendar-fetch failures (meet-watch writes the counter);
    // >=3 means prompts are running on a stale events cache
    s.calFails = Int(readFile("\(stateDir)/cal-fail-count") ?? "0") ?? 0
    return s
}

// MARK: - App

// Today's calendar events (from meet-watch's events cache) for the manual
// start picker: every timed event, past and upcoming, sorted by start.
struct CalEvent {
    let start: Date
    let end: Date
    let title: String
    var slug: String {
        let s = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "meeting" : String(s.prefix(40))
    }
}

func todayEvents() -> [CalEvent] {
    guard let data = fm.contents(atPath: "\(stateDir)/events-cache.json"),
          let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    let iso = ISO8601DateFormatter()
    var out: [CalEvent] = []
    for ev in events {
        guard let startStr = (ev["start"] as? [String: Any])?["dateTime"] as? String,
              let endStr = (ev["end"] as? [String: Any])?["dateTime"] as? String,
              let s = iso.date(from: startStr), let e = iso.date(from: endStr) else { continue }
        out.append(CalEvent(start: s, end: e, title: ev["summary"] as? String ?? "meeting"))
    }
    return out.sorted { $0.start < $1.start }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var snap = Snapshot()

    func applicationDidFinishLaunching(_ note: Notification) {
        // First-launch check: if config or key deps are missing, guide setup.
        // The .dmg distribution bundles scripts inside the .app; a git-checkout
        // install has them alongside the binary. Either way, setup.sh handles it.
        if !fm.fileExists(atPath: "\(home)/.config/zaatar/config") || !depsPresent() {
            showFirstLaunchSetup()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setTitle("", nil)
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        try? SMAppService.mainApp.register() // login item; visible in System Settings
    }

    func depsPresent() -> Bool {
        for dep in ["ffmpeg", "jq", "whisper-cli"] {
            if sh("command -v \(dep)").isEmpty { return false }
        }
        let models = "\(home)/.local/share/whisper-models"
        return fm.fileExists(atPath: "\(models)/ggml-large-v3.bin")
    }

    func showFirstLaunchSetup() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Welcome to Zaatar"
        alert.informativeText = """
        Zaatar needs a quick one-time setup: install a few dependencies \
        (ffmpeg, whisper), download transcription models (~3 GB), and \
        pick your LLM provider.

        This takes about 5 minutes and opens a Terminal window.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set Up Now")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            // Find setup.sh: bundled inside .app/Contents/Resources/zaatar/scripts/,
            // or relative to the binary in a git checkout
            var setupPath = "\(toolDir)/scripts/setup.sh"
            if let bundled = Bundle.main.resourcePath {
                let candidate = "\(bundled)/zaatar/scripts/setup.sh"
                if fm.fileExists(atPath: candidate) { setupPath = candidate }
            }
            // Open Terminal with the setup script (no osascript, avoids TCC prompt)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", "Terminal", setupPath]
            try? proc.run()
        }

        NSApp.setActivationPolicy(.accessory)
    }

    func refresh() {
        DispatchQueue.global().async {
            let s = scan()
            DispatchQueue.main.async {
                self.snap = s
                self.updateTitle()
                self.alertNewFailures()
            }
        }
    }

    func setTitle(_ text: String, _ color: NSColor?) {
        guard let button = statusItem.button else { return }
        if button.image == nil,
           let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "Zaatar") {
            leaf.isTemplate = true
            button.image = leaf
            button.imagePosition = .imageLeading
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        ]
        if let color { attrs[.foregroundColor] = color }
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    func updateTitle() {
        if let r = snap.recording { setTitle("● \(r.elapsed / 60)m", .systemRed) }
        else if !snap.strays.isEmpty { setTitle("●!", .systemOrange) }
        else if !snap.transcribing.isEmpty { setTitle("…", nil) }
        else if !snap.failed.isEmpty { setTitle("!", .systemRed) }
        else if snap.calFails >= 3 { setTitle("cal!", .systemOrange) }
        else { setTitle("", nil) }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, repr: Any? = nil, indent: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.representedObject = repr
            item.indentationLevel = indent
            menu.addItem(item)
        }
        func sep() { menu.addItem(.separator()) }

        if let r = snap.recording {
            add("Recording: \(r.name) (\(hhmm(r.elapsed)))")
            add("Stop (fast, no diarization)", #selector(stopFast))
            add("Stop (full)", #selector(stopFull))
        } else {
            add("Not recording")
            add("Start recording...", #selector(startRecording))
        }

        if !snap.strays.isEmpty {
            sep()
            add("STRAY recorder (pid file lost)")
            for st in snap.strays { add("\(st.wav) (pid \(st.pid))", indent: 1) }
            add("Stop stray + transcribe", #selector(stopStrays))
        }

        if !snap.transcribing.isEmpty {
            sep()
            for t in snap.transcribing { add("Transcribing: \(t.base) (\(hhmm(t.elapsed)))") }
        }

        if snap.calFails >= 3 {
            sep()
            add("CALENDAR fetch failing (\(snap.calFails)x in a row)")
            add("Meeting prompts run on a stale cache", indent: 1)
        }

        if !snap.failed.isEmpty {
            sep()
            for base in snap.failed {
                add("FAILED: \(base)")
                add("Retry (full)", #selector(retryFull(_:)), repr: base, indent: 1)
                add("Retry (fast, no diarization)", #selector(retryFast(_:)), repr: base, indent: 1)
                add("Dismiss", #selector(dismissFailure(_:)), repr: base, indent: 1)
            }
        }

        sep()
        add(snap.recording != nil ? "Transcripts (live)..." : "Transcripts...", #selector(openViewer))
        sep()
        add("Preferences...", #selector(openPrefs))
        add("Run Setup...", #selector(runSetup))
        add("Quit Zaatar", #selector(quit))
    }

    // MARK: Actions

    @objc func stopFast() { shAsync("'\(recCmd)' stop --fast") }
    @objc func stopFull() { shAsync("'\(recCmd)' stop") }
    @objc func openPrefs() {
        // Launch the viewer with --prefs flag to open the preferences window
        let task = Process()
        task.executableURL = URL(fileURLWithPath: viewerCmd)
        task.arguments = ["--prefs"]
        try? task.run()
    }
    @objc func runSetup() { showFirstLaunchSetup() }
    @objc func quit() { NSApp.terminate(nil) }

    var startField: NSTextField?
    var startEvents: [CalEvent] = []

    @objc func startRecording() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Meeting name"
        alert.informativeText = "Pick a meeting from today or type a name. Recording starts immediately."

        startEvents = todayEvents()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        startField = field

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        let now = Date()
        for ev in startEvents {
            let flag = now >= ev.start.addingTimeInterval(-60) && now < ev.end.addingTimeInterval(600)
                ? "now" : (ev.start > now ? "upcoming" : "past")
            popup.addItem(withTitle: "\(df.string(from: ev.start))  \(ev.title)  (\(flag))")
        }
        popup.addItem(withTitle: "Custom name...")
        popup.target = self
        popup.action = #selector(startPopupChanged(_:))

        // Default: the event active now, else the next upcoming, else custom
        var defIdx = startEvents.firstIndex {
            now >= $0.start.addingTimeInterval(-60) && now < $0.end.addingTimeInterval(600)
        } ?? startEvents.firstIndex { $0.start > now } ?? startEvents.count
        if startEvents.isEmpty { defIdx = 0 }
        popup.selectItem(at: defIdx)
        field.stringValue = defIdx < startEvents.count ? startEvents[defIdx].slug : "meeting"

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: 58))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(popup)
        stack.addArrangedSubview(field)
        popup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        alert.accessoryView = stack

        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let result = alert.runModal()
        startField = nil
        guard result == .alertFirstButtonReturn else { return }
        var slug = field.stringValue.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "meeting" }
        shAsync("'\(recCmd)' start '\(slug)'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    @objc func startPopupChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard let field = startField else { return }
        if i >= 0 && i < startEvents.count {
            field.stringValue = startEvents[i].slug
        } else {
            field.stringValue = ""
            field.window?.makeFirstResponder(field)
        }
    }

    @objc func stopStrays() {
        // Kill stray recorders only (never the known pid), then transcribe their wavs
        shAsync("""
        KNOWN="$(cat '\(stateDir)/rec.pid' 2>/dev/null || true)"
        for P in $(pgrep -f "(ffmpeg|zaatarcap) .*\(recDir)" || true); do
          [ "$P" = "$KNOWN" ] && continue
          WAV="$(ps -p "$P" -o command= | grep -o "\(recDir)/[^ ]*\\.wav" || true)"
          kill -INT "$P" 2>/dev/null
          for _ in $(seq 1 20); do kill -0 "$P" 2>/dev/null || break; sleep 0.5; done
          kill -0 "$P" 2>/dev/null && kill -KILL "$P" 2>/dev/null
          if [ -n "$WAV" ] && [ -f "$WAV" ]; then
            TLOG="\(stateDir)/transcribe-$(basename "$WAV" .wav).log"
            nohup '\(transcribeCmd)' --fast "$WAV" >"$TLOG" 2>&1 &
          fi
        done
        """)
    }

    @objc func openViewer() {
        // Bring viewer to front using NSRunningApplication (no TCC prompt)
        let viewers = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "zaatarviewer" }
        if let viewer = viewers.first {
            viewer.activate()
        } else {
            shAsync("nohup '\(viewerCmd)' >/dev/null 2>&1 &")
        }
    }

    @objc func retryFull(_ sender: NSMenuItem) { retry(sender.representedObject as? String, fast: false) }
    @objc func retryFast(_ sender: NSMenuItem) { retry(sender.representedObject as? String, fast: true) }

    func retry(_ base: String?, fast: Bool) {
        guard let base else { return }
        try? fm.removeItem(atPath: "\(stateDir)/failed-alerted-\(base)")
        try? fm.removeItem(atPath: "\(stateDir)/failed-dismissed-\(base)")
        let wav = "\(recDir)/\(base).wav"
        guard fm.fileExists(atPath: wav) else {
            fm.createFile(atPath: "\(stateDir)/failed-dismissed-\(base)", contents: nil)
            shAsync("'\(zpromptCmd)' --title 'Cannot retry' --subtitle 'WAV missing: \(base)' --button 'OK' --timeout 30")
            refresh()
            return
        }
        let log = "\(stateDir)/transcribe-\(base).log"
        shAsync("nohup '\(transcribeCmd)' \(fast ? "--fast " : "")'\(wav)' >'\(log)' 2>&1 &")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    @objc func dismissFailure(_ sender: NSMenuItem) {
        guard let base = sender.representedObject as? String else { return }
        fm.createFile(atPath: "\(stateDir)/failed-dismissed-\(base)", contents: nil)
        refresh()
    }

    // MARK: Failure alerts (once per failure, via zaatarprompt panel)

    func alertNewFailures() {
        for base in snap.failed {
            let marker = "\(stateDir)/failed-alerted-\(base)"
            guard !fm.fileExists(atPath: marker) else { continue }
            fm.createFile(atPath: marker, contents: nil)
            DispatchQueue.global().async {
                let btn = sh("'\(zpromptCmd)' --title 'Transcription failed' --subtitle '\(base)' --primary 'Retry' --button 'Dismiss' --timeout 120")
                DispatchQueue.main.async {
                    switch btn {
                    case "Retry": self.retry(base, fast: false)
                    case "Dismiss":
                        fm.createFile(atPath: "\(stateDir)/failed-dismissed-\(base)", contents: nil)
                        self.refresh()
                    default: break // timeout: stays visible in the menu as FAILED
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
