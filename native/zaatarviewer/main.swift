// zaatarviewer - Zaatar transcript browser
// Left: searchable list of past meeting transcripts (Outputs/transcripts/*.md,
// -raw files excluded) plus a LIVE row while a recording is in progress.
// Right: styled transcript view. Live view tails the rough live transcript
// (live-transcribe.sh) and auto-refreshes every 5s.

import AppKit

// --- Design System: Premium Utilitarian Minimalism ---
struct DS {
    // Canvas & surfaces
    static let canvas      = NSColor(calibratedRed: 0.969, green: 0.965, blue: 0.953, alpha: 1) // #F7F6F3
    static let surface     = NSColor(calibratedRed: 0.984, green: 0.984, blue: 0.976, alpha: 1) // #FBFBFA
    static let cardWhite   = NSColor.white

    // Text hierarchy (never pure black)
    static let textPrimary   = NSColor(calibratedRed: 0.184, green: 0.204, blue: 0.216, alpha: 1) // #2F3437
    static let textSecondary = NSColor(calibratedRed: 0.471, green: 0.467, blue: 0.455, alpha: 1) // #787774
    static let textTertiary  = NSColor(calibratedRed: 0.639, green: 0.635, blue: 0.620, alpha: 1) // #A3A29E

    // Structural
    static let border   = NSColor(calibratedRed: 0.918, green: 0.918, blue: 0.918, alpha: 1) // #EAEAEA
    static let divider  = NSColor(calibratedWhite: 0, alpha: 0.06)

    // Accent pastels (bg, text pairs)
    static let paleRedBg     = NSColor(calibratedRed: 0.992, green: 0.922, blue: 0.925, alpha: 1) // #FDEBEC
    static let paleRedText   = NSColor(calibratedRed: 0.624, green: 0.184, blue: 0.176, alpha: 1) // #9F2F2D
    static let paleYellowBg  = NSColor(calibratedRed: 0.984, green: 0.953, blue: 0.859, alpha: 1) // #FBF3DB
    static let paleYellowText = NSColor(calibratedRed: 0.584, green: 0.392, blue: 0.0, alpha: 1)  // #956400
    static let paleBlueBg    = NSColor(calibratedRed: 0.882, green: 0.953, blue: 0.996, alpha: 1) // #E1F3FE
    static let paleBlueText  = NSColor(calibratedRed: 0.122, green: 0.424, blue: 0.624, alpha: 1) // #1F6C9F
    static let paleGreenBg   = NSColor(calibratedRed: 0.929, green: 0.953, blue: 0.925, alpha: 1) // #EDF3EC
    static let paleGreenText = NSColor(calibratedRed: 0.204, green: 0.396, blue: 0.220, alpha: 1) // #346538

    // Brand green (Zaatar leaf)
    static let brandGreen     = NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.36, alpha: 1)
    static let brandGreenDark = NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.24, alpha: 1)

    // Sidebar
    static let sidebarBg       = canvas
    static let sidebarSelected = NSColor(calibratedWhite: 0, alpha: 0.06)

    // Typography helpers
    static func serif(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return base
    }

    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func body(size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}

// Config: plain KEY="value" lines in ~/.config/zaatar/config (same file the
// shell scripts source). $HOME is the only substitution supported.
func zaatarConfig() -> [String: String] {
    var cfg: [String: String] = [:]
    let path = ProcessInfo.processInfo.environment["ZAATAR_CONFIG"]
        ?? "\(NSHomeDirectory())/.config/zaatar/config"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return cfg }
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq])
        let value = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
        cfg[key] = value
    }
    return cfg
}
let zcfg = zaatarConfig()

let transcriptsDir = URL(fileURLWithPath: zcfg["ZAATAR_TRANSCRIPTS_DIR"]
    ?? "\(NSHomeDirectory())/Documents/zaatar/transcripts")
let stateDir = URL(fileURLWithPath: zcfg["ZAATAR_STATE_DIR"]
    ?? "\(NSHomeDirectory())/.local/state/zaatar")
let recordingsDir = URL(fileURLWithPath: zcfg["ZAATAR_REC_DIR"]
    ?? "\(NSHomeDirectory())/Recordings/meetings")

// --- Preferences ---
struct Prefs {
    private static let d = UserDefaults.standard
    private static func bool(_ key: String, default val: Bool = true) -> Bool {
        d.object(forKey: key) == nil ? val : d.bool(forKey: key)
    }

    static var behavioralRead: Bool {
        get { bool("pref_behavioralRead", default: false) }
        set { d.set(newValue, forKey: "pref_behavioralRead") }
    }
    static var emotionalEval: Bool {
        get { bool("pref_emotionalEval") }
        set { d.set(newValue, forKey: "pref_emotionalEval") }
    }
    static var upcomingMeetings: Bool {
        get { bool("pref_upcomingMeetings") }
        set { d.set(newValue, forKey: "pref_upcomingMeetings") }
    }
    static var preMeetingBriefs: Bool {
        get { bool("pref_preMeetingBriefs") }
        set { d.set(newValue, forKey: "pref_preMeetingBriefs") }
    }
    static var actionItems: Bool {
        get { bool("pref_actionItems") }
        set { d.set(newValue, forKey: "pref_actionItems") }
    }
    static var liveQuestions: Bool {
        get { bool("pref_liveQuestions") }
        set { d.set(newValue, forKey: "pref_liveQuestions") }
    }
    static var timestamps: Bool {
        get { bool("pref_timestamps") }
        set { d.set(newValue, forKey: "pref_timestamps") }
    }
}

// --- Preferences Window ---
final class PrefsController: NSObject {
    var window: NSWindow?
    var onClose: (() -> Void)?

    struct Toggle {
        let label: String
        let desc: String
        let get: () -> Bool
        let set: (Bool) -> Void
    }

    let toggles: [Toggle] = [
        Toggle(label: "Upcoming Meetings", desc: "Show today's remaining calendar events in the sidebar",
               get: { Prefs.upcomingMeetings }, set: { Prefs.upcomingMeetings = $0 }),
        Toggle(label: "Action Items", desc: "Show the commitment ledger pinned in the sidebar",
               get: { Prefs.actionItems }, set: { Prefs.actionItems = $0 }),
        Toggle(label: "Pre-meeting Briefs", desc: "Show AI-generated briefs before meetings",
               get: { Prefs.preMeetingBriefs }, set: { Prefs.preMeetingBriefs = $0 }),
        Toggle(label: "Behavioral Read", desc: "Show text-based speaker behavioral analysis in transcripts",
               get: { Prefs.behavioralRead }, set: { Prefs.behavioralRead = $0 }),
        Toggle(label: "Emotional Eval", desc: "Show prosody/acoustic emotional evaluation tabs (requires audio analysis)",
               get: { Prefs.emotionalEval }, set: { Prefs.emotionalEval = $0 }),
        Toggle(label: "Live Questions", desc: "Show AI question suggestions during live recordings",
               get: { Prefs.liveQuestions }, set: { Prefs.liveQuestions = $0 }),
        Toggle(label: "Timestamps", desc: "Show timestamp markers in transcripts",
               get: { Prefs.timestamps }, set: { Prefs.timestamps = $0 }),
    ]

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let w = window { w.makeKeyAndOrderFront(nil); return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 0),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Preferences"
        w.titlebarAppearsTransparent = true
        w.backgroundColor = DS.cardWhite
        w.isReleasedWhenClosed = false

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        container.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let title = NSTextField(labelWithString: "Preferences")
        title.font = DS.serif(size: 20)
        title.textColor = DS.textPrimary
        container.addArrangedSubview(title)
        container.setCustomSpacing(6, after: title)

        let subtitle = NSTextField(labelWithString: "Choose which features to show in the viewer.")
        subtitle.font = DS.body(size: 12)
        subtitle.textColor = DS.textSecondary
        container.addArrangedSubview(subtitle)
        container.setCustomSpacing(24, after: subtitle)

        // Divider
        let topDiv = NSBox(); topDiv.boxType = .separator
        topDiv.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(topDiv)
        topDiv.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -64).isActive = true
        container.setCustomSpacing(16, after: topDiv)

        for (i, toggle) in toggles.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false

            let labels = NSStackView()
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 2

            let name = NSTextField(labelWithString: toggle.label)
            name.font = DS.body(size: 13, weight: .medium)
            name.textColor = DS.textPrimary
            labels.addArrangedSubview(name)

            let desc = NSTextField(wrappingLabelWithString: toggle.desc)
            desc.font = DS.body(size: 11)
            desc.textColor = DS.textSecondary
            desc.preferredMaxLayoutWidth = 280
            labels.addArrangedSubview(desc)

            let sw = NSSwitch()
            sw.state = toggle.get() ? .on : .off
            sw.tag = i
            sw.target = self
            sw.action = #selector(toggleChanged(_:))
            sw.controlSize = .small

            row.addArrangedSubview(labels)
            row.addArrangedSubview(sw)
            labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -64).isActive = true
            container.setCustomSpacing(i < toggles.count - 1 ? 16 : 0, after: row)
        }

        w.contentView = container
        container.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor).isActive = true
        container.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor).isActive = true
        container.topAnchor.constraint(equalTo: w.contentView!.topAnchor).isActive = true
        container.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor).isActive = true

        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: w, queue: .main) { [weak self] _ in self?.onClose?() }
    }

    @objc func toggleChanged(_ sender: NSSwitch) {
        let i = sender.tag
        guard i >= 0, i < toggles.count else { return }
        toggles[i].set(sender.state == .on)
    }
}

struct CalendarEvent {
    let id: String
    let summary: String
    let startTime: Date
    let endTime: Date
    let meetLink: String
    let attendees: [String]

    var timeRange: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "\(f.string(from: startTime)) - \(f.string(from: endTime))"
    }

    var startsIn: String {
        let mins = Int(startTime.timeIntervalSinceNow / 60)
        if mins <= 0 { return "now" }
        if mins < 60 { return "in \(mins)m" }
        return "in \(mins / 60)h \(mins % 60)m"
    }
}

// global store for upcoming event details (keyed by event id)
var upcomingEvents: [String: CalendarEvent] = [:]

func loadUpcomingEvents() -> [CalendarEvent] {
    let cacheURL = stateDir.appendingPathComponent("events-cache.json")
    guard let data = try? Data(contentsOf: cacheURL),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    let now = Date()
    let cal = Calendar.current
    var events: [CalendarEvent] = []
    for obj in arr {
        let evType = obj["eventType"] as? String ?? "default"
        if evType != "default" { continue }
        guard let start = obj["start"] as? [String: Any],
              let dtStr = start["dateTime"] as? String else { continue }
        guard let startDate = parseISO(dtStr) else { continue }
        if !cal.isDateInToday(startDate) { continue }
        if startDate < now { continue }
        let end = obj["end"] as? [String: Any]
        let endDate = (end?["dateTime"] as? String).flatMap(parseISO) ?? startDate
        let summary = obj["summary"] as? String ?? "(no title)"
        let id = obj["id"] as? String ?? UUID().uuidString
        // meet link: hangoutLink or in conferenceData
        var meetLink = obj["hangoutLink"] as? String ?? ""
        if meetLink.isEmpty, let conf = obj["conferenceData"] as? [String: Any],
           let eps = conf["entryPoints"] as? [[String: Any]] {
            meetLink = eps.first { ($0["entryPointType"] as? String) == "video" }?["uri"] as? String ?? ""
        }
        // attendees
        var attendees: [String] = []
        if let atts = obj["attendees"] as? [[String: Any]] {
            for a in atts {
                if a["self"] as? Bool == true { continue }
                let name = a["displayName"] as? String ?? (a["email"] as? String ?? "")
                if !name.isEmpty { attendees.append(name) }
            }
        }
        events.append(CalendarEvent(id: id, summary: summary, startTime: startDate,
                                     endTime: endDate, meetLink: meetLink, attendees: attendees))
    }
    return events.sorted { $0.startTime < $1.startTime }
}

func parseISO(_ s: String) -> Date? {
    // handles "+05:30" offset format from Google Calendar
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    for fmt in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXX"] {
        f.dateFormat = fmt
        if let d = f.date(from: s) { return d }
    }
    return nil
}

struct Entry {
    let title: String
    let subtitle: String
    let url: URL
    let isLive: Bool
    let mtime: Date
    var pinned: Bool = false
    var processing: Bool = false
    var failed: Bool = false
    var upcoming: Bool = false
    var eventId: String = ""
}

// Bases with a transcribe.sh currently running (same scan zaatarbar uses)
func runningTranscribeBases() -> Set<String> {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "ps ax -o command= | grep '[t]ranscribe.sh'"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var bases = Set<String>()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        if let r = line.range(of: #"/[^/ ]+\.wav"#, options: .regularExpression) {
            var b = (String(line[r]) as NSString).lastPathComponent
            b.removeLast(4)
            bases.insert(b)
        }
    }
    return bases
}

func humanTitle(from filename: String) -> (String, String) {
    // "2026-07-29-1658-zcap-e2e" -> ("zcap e2e", "29 Jul 16:58")
    let base = filename.replacingOccurrences(of: ".md", with: "")
        .replacingOccurrences(of: ".txt", with: "")
    let pattern = #"^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})-(.*)$"#
    if let m = base.range(of: pattern, options: .regularExpression) {
        let s = String(base[m])
        let parts = s.split(separator: "-", maxSplits: 5).map(String.init)
        if parts.count == 6 {
            let name = parts[5].replacingOccurrences(of: "-", with: " ")
            let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            let mon = Int(parts[1]).map { months[$0] } ?? parts[1]
            let day = Int(parts[2]).map(String.init) ?? parts[2]
            return (name, "\(day) \(mon) \(parts[3]):\(parts[4])")
        }
    }
    return (base, "")
}

// Real event title embedded by transcribe.sh as "<!-- zaatar-title: ... -->"
// (the filename slug is lossy: lowercased, punctuation stripped, 40-char cut)
func storedTitle(of url: URL) -> String? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    guard let data = try? fh.read(upToCount: 512) else { return nil }
    let head = String(decoding: data, as: UTF8.self)
    guard let r = head.range(of: #"<!-- zaatar-title: .* -->"#, options: .regularExpression) else { return nil }
    let title = head[r].dropFirst("<!-- zaatar-title: ".count).dropLast(" -->".count)
        .trimmingCharacters(in: .whitespaces)
    return title.isEmpty ? nil : title
}

func loadEntries() -> [Entry] {
    var entries: [Entry] = []
    let fm = FileManager.default

    // LIVE entry: recording in progress + live transcript file present
    let recPidAlive: Bool = {
        guard let pidStr = try? String(contentsOf: stateDir.appendingPathComponent("rec.pid"), encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }()
    // Only show the live-*.txt that matches the CURRENT recording (rec.meta).
    // Stale live files from prior recordings used to create duplicate LIVE rows;
    // the viewer could select the wrong (empty/stale) one -> blank live view
    // (Roneel incident Aug 12).
    if recPidAlive,
       let liveFiles = try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil) {
        let metaBase: String? = {
            guard let p = try? String(contentsOf: stateDir.appendingPathComponent("rec.meta"), encoding: .utf8) else { return nil }
            let wav = (p.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
            return wav.hasSuffix(".wav") ? String(wav.dropLast(4)) : nil
        }()
        for f in liveFiles where f.lastPathComponent.hasPrefix("live-") && f.pathExtension == "txt" {
            let raw = f.lastPathComponent
                .replacingOccurrences(of: "live-", with: "")
            // If rec.meta tells us the current base, only show that live file
            let fileBase = (raw as NSString).deletingPathExtension
            if let mb = metaBase, fileBase != mb { continue }
            let (name, when) = humanTitle(from: raw)
            entries.append(Entry(title: "LIVE  \(name)", subtitle: when.isEmpty ? "recording now" : "\(when) - recording now",
                                 url: f, isLive: true, mtime: .distantFuture))
        }
    }

    // Recorded-but-unfinished meetings (last 7 days): a wav with no transcript
    // md gets a "Processing" row - a stopped recording mid-transcription must
    // never be invisible. No process + no "Done:" in the log = failure row.
    if let wavs = try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
        let activeWav = ((try? String(contentsOf: stateDir.appendingPathComponent("rec.meta"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        var running: Set<String>? = nil  // lazy: ps scan only when a candidate exists
        for f in wavs where f.pathExtension == "wav" {
            let base = f.deletingPathExtension().lastPathComponent
            if fm.fileExists(atPath: transcriptsDir.appendingPathComponent(base + ".md").path) { continue }
            if recPidAlive && f.path == activeWav { continue }  // still recording: LIVE row covers it
            if fm.fileExists(atPath: stateDir.appendingPathComponent("failed-dismissed-\(base)").path) { continue }
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mtime < cutoff { continue }
            if running == nil { running = runningTranscribeBases() }
            let log = (try? String(contentsOf: stateDir.appendingPathComponent("transcribe-\(base).log"), encoding: .utf8)) ?? ""
            let ok = (running ?? []).contains(base) || log.hasPrefix("Done:") || log.contains("\nDone:")
            let (name, when) = humanTitle(from: base)
            // Stage + elapsed: slow-but-healthy (CPU diarization runs 15-30
            // min per meeting hour) must not look identical to hung
            var stage = "queued"
            if log.contains("[3/3]") { stage = "cleaning up" }
            else if log.contains("[2/3] Speaker diarization") { stage = "diarizing" }
            else if log.contains("[1/3]") { stage = "transcribing" }
            let mins = max(0, Int(Date().timeIntervalSince(mtime)) / 60)
            let elapsed = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
            let state = ok ? "\(stage) \u{00b7} \(elapsed)" : "transcription failed"
            entries.append(Entry(title: name,
                                 subtitle: when.isEmpty ? state : "\(when) - \(state)",
                                 url: f, isLive: false, mtime: mtime,
                                 processing: ok, failed: !ok))
        }
    }

    // Pinned: commitment ledger (action items extracted from every meeting)
    let ledger = transcriptsDir.appendingPathComponent("ledger/commitments.md")
    if Prefs.actionItems, let content = try? String(contentsOf: ledger, encoding: .utf8) {
        let open = content.components(separatedBy: "\n").filter { $0.hasPrefix("- [ ]") }.count
        entries.append(Entry(title: "Action Items", subtitle: "\(open) open \u{00b7} commitment ledger",
                             url: ledger, isLive: false, mtime: .distantFuture, pinned: true))
    }

    // Upcoming calendar events for today
    upcomingEvents.removeAll()
    let upcoming = Prefs.upcomingMeetings ? loadUpcomingEvents() : []
    let dummyURL = stateDir.appendingPathComponent("events-cache.json")
    for ev in upcoming {
        upcomingEvents[ev.id] = ev
        entries.append(Entry(title: ev.summary,
                             subtitle: "\(ev.timeRange) \u{00b7} \(ev.startsIn)",
                             url: dummyURL, isLive: false,
                             mtime: Date(timeIntervalSince1970: ev.startTime.timeIntervalSince1970 + 2e9),
                             upcoming: true, eventId: ev.id))
    }

    // Pre-meeting briefs ("YYYY-MM-DD-slug-brief.md"), sorted in with transcripts
    let briefsDir = transcriptsDir.appendingPathComponent("briefs")
    if Prefs.preMeetingBriefs, let files = try? fm.contentsOfDirectory(at: briefsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
        for f in files where f.pathExtension == "md" {
            var base = f.deletingPathExtension().lastPathComponent
            if base.hasSuffix("-brief") { base = String(base.dropLast(6)) }
            var name = base
            var when = "pre-meeting brief"
            let parts = base.split(separator: "-").map(String.init)
            if parts.count > 3, parts[0].count == 4, Int(parts[0]) != nil {
                let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
                let mon = Int(parts[1]).map { months[$0] } ?? parts[1]
                let day = Int(parts[2]).map(String.init) ?? parts[2]
                name = parts[3...].joined(separator: " ")
                when = "\(day) \(mon) \u{00b7} pre-meeting brief"
            }
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            entries.append(Entry(title: "Brief: \(name)", subtitle: when, url: f, isLive: false, mtime: mtime))
        }
    }

    if let files = try? fm.contentsOfDirectory(at: transcriptsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
        for f in files where f.pathExtension == "md" && !f.lastPathComponent.hasSuffix("-raw.md") {
            // behavioral eval merges into its meeting's tabs; only list it
            // standalone when the meeting doc is missing (orphan)
            if f.lastPathComponent.hasSuffix("-behavioral.md") {
                let mainPath = String(f.path.dropLast("-behavioral.md".count)) + ".md"
                if fm.fileExists(atPath: mainPath) { continue }
            }
            let (fallback, when) = humanTitle(from: f.lastPathComponent)
            let name = storedTitle(of: f) ?? fallback
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            entries.append(Entry(title: name, subtitle: when, url: f, isLive: false, mtime: mtime))
        }
    }
    return entries.sorted {
        if $0.isLive != $1.isLive { return $0.isLive }
        if $0.pinned != $1.pinned { return $0.pinned }
        let a = $0.processing || $0.failed, b = $1.processing || $1.failed
        if a != b { return a }
        if $0.upcoming != $1.upcoming { return $0.upcoming }
        // upcoming: sort by start time ascending (earliest first)
        if $0.upcoming && $1.upcoming { return $0.mtime < $1.mtime }
        return $0.mtime > $1.mtime
    }
}

// --- markdown tables -> NSTextTable (real bordered layout in the text view) ---
func isTableRow(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    return t.count > 2 && t.hasPrefix("|") && t.hasSuffix("|")
}

func isTableSeparator(_ line: String) -> Bool {
    guard isTableRow(line) else { return false }
    let inner = line.trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
    return inner.contains("-") && inner.allSatisfy { "-:| ".contains($0) }
}

func tableCells(_ line: String) -> [String] {
    let inner = line.trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
    return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

// long table cells (Evidence etc.) collapse to one line; click "more" to expand.
// session-only state, keyed by cell-text hash.
var expandedTableCells = Set<String>()

// clickable checkbox lines (commitment ledger): key -> original file line,
// click toggles - [ ] / - [x] in the file itself
var checkboxLines: [String: String] = [:]

// Strip section headers (## ...) that have no items before the next header or EOF
func stripOrphanHeaders(_ text: String) -> String {
    var result: [String] = []
    var pendingHeader: String? = nil
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("## ") {
            pendingHeader = line // hold until we see an item
        } else if line.hasPrefix("- [") {
            if let h = pendingHeader { result.append(h); pendingHeader = nil }
            result.append(line)
        } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
            if pendingHeader == nil { result.append(line) }
        } else {
            if let h = pendingHeader { result.append(h); pendingHeader = nil }
            result.append(line)
        }
    }
    // collapse multiple blank lines
    var cleaned: [String] = []
    var lastBlank = false
    for line in result {
        let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
        if blank && lastBlank { continue }
        cleaned.append(line)
        lastBlank = blank
    }
    // trim trailing blanks
    while cleaned.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cleaned.removeLast() }
    return cleaned.joined(separator: "\n") + "\n"
}

// --- Structured ledger: parse, group, render with editable fields ---

struct ActionItem {
    let checked: Bool
    let date: String
    let owner: String
    let recipient: String
    let text: String
    let due: String
    let src: String
    let rawLine: String

    enum Group: Int, CaseIterable { case overdue = 0, dueSoon, upcoming, noDue, done }

    func group(today: String) -> Group {
        if checked { return .done }
        if due == "unspecified" || due.isEmpty { return .noDue }
        if due < today { return .overdue }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: due), let t = df.date(from: today) {
            let days = Calendar.current.dateComponents([.day], from: t, to: d).day ?? 0
            if days <= 7 { return .dueSoon }
        }
        return .upcoming
    }

    var duePretty: String {
        if due == "unspecified" || due.isEmpty { return "no due date" }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: due) else { return due }
        let pretty = DateFormatter(); pretty.dateFormat = "MMM d"
        let todayStr = df.string(from: Date())
        var s = pretty.string(from: d)
        if due < todayStr, let td = df.date(from: todayStr) {
            let days = Calendar.current.dateComponents([.day], from: d, to: td).day ?? 0
            s += " (\(days)d overdue)"
        }
        return s
    }

    var assigneeDisplay: String {
        recipient.isEmpty || recipient == "self" ? owner : "\(owner) \u{2192} \(recipient)"
    }

    var srcPretty: String {
        src.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}-\d{4}-"#, with: "", options: .regularExpression)
           .replacingOccurrences(of: "-", with: " ")
    }
}

var ledgerItems: [String: ActionItem] = [:]
var ledgerFilter: String = ""

func parseActionItems(_ content: String) -> [ActionItem] {
    var items: [ActionItem] = []
    for line in content.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- [") else { continue }
        let checked = t.hasPrefix("- [x]")
        let parts = t.components(separatedBy: " | ")
        guard parts.count >= 4 else { continue }
        let first = parts[0]
        let dateMatch = first.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression)
        let date = dateMatch.map { String(first[$0]) } ?? ""
        let ownerPart = parts[1]
        let ownerSplit = ownerPart.components(separatedBy: " -> ")
        let owner = ownerSplit[0].trimmingCharacters(in: .whitespaces)
        let recipient = ownerSplit.count > 1 ? ownerSplit[1].trimmingCharacters(in: .whitespaces) : ""
        let text = parts[2].trimmingCharacters(in: .whitespaces)
        var due = "unspecified"
        if let dp = parts.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("due:") }) {
            due = dp.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "due: ", with: "").replacingOccurrences(of: "due:", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        var src = ""
        if let sp = parts.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("src:") }) {
            src = sp.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "src: ", with: "").trimmingCharacters(in: .whitespaces)
        }
        items.append(ActionItem(checked: checked, date: date, owner: owner, recipient: recipient,
                                text: text, due: due, src: src, rawLine: t))
    }
    return items
}

func renderLedger(_ content: String, url: URL) -> NSMutableAttributedString {
    let doc = NSMutableAttributedString()
    ledgerItems = [:]
    let allItems = parseActionItems(content)
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let today = df.string(from: Date())

    let groupLabels: [ActionItem.Group: String] = [
        .overdue: "OVERDUE", .dueSoon: "DUE SOON", .upcoming: "UPCOMING",
        .noDue: "NO DUE DATE", .done: "DONE"]
    let groupColors: [ActionItem.Group: NSColor] = [
        .overdue: DS.paleRedText, .dueSoon: DS.paleYellowText, .upcoming: DS.paleBlueText,
        .noDue: DS.textTertiary, .done: DS.paleGreenText]
    let groupBadgeBg: [ActionItem.Group: NSColor] = [
        .overdue: DS.paleRedBg, .dueSoon: DS.paleYellowBg, .upcoming: DS.paleBlueBg,
        .noDue: DS.surface, .done: DS.paleGreenBg]

    // Title
    let titlePS = NSMutableParagraphStyle(); titlePS.paragraphSpacing = 4
    doc.append(NSAttributedString(string: "Action Items\n",
        attributes: [.font: DS.serif(size: 24),
                     .foregroundColor: DS.textPrimary, .kern: NSNumber(value: -0.6), .paragraphStyle: titlePS]))

    // Summary
    let openCount = allItems.filter { !$0.checked }.count
    let overdueCount = allItems.filter { $0.group(today: today) == .overdue }.count
    var summary = "\(openCount) open"
    if overdueCount > 0 { summary += " \u{00B7} \(overdueCount) overdue" }
    doc.append(NSAttributedString(string: summary + "  ",
        attributes: [.font: DS.body(size: 12), .foregroundColor: DS.textSecondary]))
    // "+ Add item" button
    let addPS = NSMutableParagraphStyle(); addPS.paragraphSpacing = 4
    let addAttrs: [NSAttributedString.Key: Any] = [
        .font: DS.body(size: 12, weight: .medium),
        .foregroundColor: DS.brandGreen,
        .link: URL(string: "zaatar-add://new")! as Any,
        .cursor: NSCursor.pointingHand,
        .paragraphStyle: addPS]
    doc.append(NSAttributedString(string: "+ Add item\n", attributes: addAttrs))

    // Assignee filter bar
    let assignees = Array(Set(allItems.flatMap { [$0.owner, $0.recipient] }
        .filter { !$0.isEmpty && $0 != "self" })).sorted()
    if !assignees.isEmpty {
        let fPS = NSMutableParagraphStyle(); fPS.paragraphSpacingBefore = 8; fPS.paragraphSpacing = 12
        doc.append(NSAttributedString(string: "Filter: ",
            attributes: [.font: DS.body(size: 11), .foregroundColor: DS.textTertiary, .paragraphStyle: fPS]))
        let allLink: [NSAttributedString.Key: Any] = [
            .font: DS.body(size: 11, weight: ledgerFilter.isEmpty ? .semibold : .regular),
            .foregroundColor: ledgerFilter.isEmpty ? DS.textPrimary : DS.textSecondary,
            .link: URL(string: "zaatar-filter://all")! as Any]
        doc.append(NSAttributedString(string: "All", attributes: allLink))
        for a in assignees {
            let enc = a.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? a
            let attrs: [NSAttributedString.Key: Any] = [
                .font: DS.body(size: 11, weight: ledgerFilter == a ? .semibold : .regular),
                .foregroundColor: ledgerFilter == a ? DS.textPrimary : DS.textSecondary,
                .link: URL(string: "zaatar-filter://\(enc)")! as Any]
            doc.append(NSAttributedString(string: "  \u{00B7}  ", attributes: [.font: DS.body(size: 11),
                .foregroundColor: DS.textTertiary]))
            doc.append(NSAttributedString(string: a, attributes: attrs))
        }
        doc.append(NSAttributedString(string: "\n", attributes: [:]))
    }

    let grouped = Dictionary(grouping: allItems) { $0.group(today: today) }

    for group in ActionItem.Group.allCases {
        guard var groupItems = grouped[group], !groupItems.isEmpty else { continue }
        if !ledgerFilter.isEmpty {
            groupItems = groupItems.filter { $0.owner == ledgerFilter || $0.recipient == ledgerFilter }
            if groupItems.isEmpty { continue }
        }
        let color = groupColors[group] ?? .labelColor
        let label = groupLabels[group] ?? ""

        // Group header - pill badge style
        let ghPS = NSMutableParagraphStyle(); ghPS.paragraphSpacingBefore = 24; ghPS.paragraphSpacing = 8
        doc.append(NSAttributedString(string: "\(label)  \(groupItems.count)\n",
            attributes: [.font: DS.body(size: 10, weight: .bold),
                         .foregroundColor: color,
                         .backgroundColor: groupBadgeBg[group] ?? DS.surface,
                         .kern: NSNumber(value: 0.8), .paragraphStyle: ghPS]))

        for item in groupItems {
            let key = String(UInt(bitPattern: item.rawLine.hashValue))
            ledgerItems[key] = item
            checkboxLines[key] = item.rawLine

            let bodyPS = NSMutableParagraphStyle(); bodyPS.lineHeightMultiple = 1.45; bodyPS.paragraphSpacing = 2
            let body: [NSAttributedString.Key: Any] = [
                .font: DS.body(size: 13), .foregroundColor: DS.textPrimary, .paragraphStyle: bodyPS]

            // Checkbox
            var cb = body; cb[.link] = URL(string: "zaatar-check://\(key)")!
            cb[.font] = DS.body(size: 14, weight: .medium)
            cb[.foregroundColor] = item.checked ? DS.textTertiary : DS.brandGreen
            doc.append(NSAttributedString(string: item.checked ? "\u{2611} " : "\u{2610} ", attributes: cb))

            // Text (clickable to edit)
            var ta = body; ta[.link] = URL(string: "zaatar-edittext://\(key)")!
            ta[.font] = DS.body(size: 13, weight: .medium)
            ta[.cursor] = NSCursor.pointingHand
            if item.checked { ta[.foregroundColor] = DS.textTertiary
                ta[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            doc.append(NSAttributedString(string: item.text, attributes: ta))

            // Delete
            var del = body; del[.link] = URL(string: "zaatar-delete://\(key)")!
            del[.font] = DS.body(size: 11); del[.foregroundColor] = DS.textTertiary
            doc.append(NSAttributedString(string: "  \u{00D7}\n", attributes: del))

            // Second line: assignee (clickable) + due (clickable) + source
            let metaPS = NSMutableParagraphStyle(); metaPS.firstLineHeadIndent = 22; metaPS.paragraphSpacing = 16
            let meta: [NSAttributedString.Key: Any] = [
                .font: DS.body(size: 11), .foregroundColor: DS.textSecondary, .paragraphStyle: metaPS]
            var oa = meta; oa[.link] = URL(string: "zaatar-editowner://\(key)")!
            doc.append(NSAttributedString(string: item.assigneeDisplay, attributes: oa))
            doc.append(NSAttributedString(string: "  \u{00B7}  ", attributes: meta))
            var da = meta; da[.link] = URL(string: "zaatar-editdue://\(key)")!
            if group == .overdue { da[.foregroundColor] = DS.paleRedText }
            doc.append(NSAttributedString(string: item.duePretty, attributes: da))
            doc.append(NSAttributedString(string: "  \u{00B7}  \(item.srcPretty)\n", attributes: meta))
        }
    }

    if allItems.isEmpty {
        doc.append(NSAttributedString(string: "\nNo action items yet. Items are extracted from meeting transcripts automatically.\n",
            attributes: [.font: DS.body(size: 13), .foregroundColor: DS.textSecondary]))
    }
    return doc
}

func appendTable(_ rowLines: [String], to out: NSMutableAttributedString) {
    let rows = rowLines.filter { !isTableSeparator($0) }.map(tableCells)
    guard let cols = rows.map({ $0.count }).max(), cols > 0 else { return }
    let table = NSTextTable()
    table.numberOfColumns = cols
    table.collapsesBorders = true
    table.hidesEmptyCells = false
    let lastRow = rows.count - 1
    for (r, row) in rows.enumerated() {
        for c in 0..<cols {
            let cell = c < row.count ? row[c] : ""
            let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                         startingColumn: c, columnSpan: 1)
            // editorial style: horizontal hairlines only, no grid, no header fill
            if r < lastRow {
                block.setBorderColor(r == 0
                    ? DS.border
                    : DS.divider, for: .maxY)
                block.setWidth(r == 0 ? 1 : 0.5, type: .absoluteValueType,
                               for: .border, edge: .maxY)
            }
            block.setWidth(0, type: .absoluteValueType, for: .padding)
            block.setWidth(c == 0 ? 0 : 12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(r == 0 ? 5 : 8, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(r == 0 ? 5 : 8, type: .absoluteValueType, for: .padding, edge: .maxY)
            let ps = NSMutableParagraphStyle()
            ps.textBlocks = [block]
            ps.lineHeightMultiple = 1.15
            if r == 0 {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: DS.body(size: 10.5, weight: .semibold),
                    .foregroundColor: DS.textSecondary,
                    .kern: 0.8,
                    .paragraphStyle: ps,
                ]
                out.append(NSAttributedString(string: cell.uppercased() + "\n", attributes: attrs))
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: DS.body(size: 12),
                    .foregroundColor: DS.textPrimary,
                    .paragraphStyle: ps,
                ]
                let key = String(UInt(bitPattern: cell.hashValue))
                let isLong = cell.count > 90
                var linkAttrs = attrs
                linkAttrs[.font] = DS.body(size: 11, weight: .medium)
                linkAttrs[.foregroundColor] = DS.paleBlueText
                linkAttrs[.link] = URL(string: "zaatar-toggle://\(key)")!
                if isLong && !expandedTableCells.contains(key) {
                    let cut = String(cell.prefix(88))
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "**", with: "")
                    out.append(NSAttributedString(string: cut + "\u{2026} ", attributes: attrs))
                    out.append(NSAttributedString(string: "more", attributes: linkAttrs))
                    out.append(NSAttributedString(string: "\n", attributes: attrs))
                } else {
                    out.append(inlineStyled(cell, base: attrs))
                    if isLong {
                        out.append(NSAttributedString(string: " ", attributes: attrs))
                        out.append(NSAttributedString(string: "less", attributes: linkAttrs))
                    }
                    out.append(NSAttributedString(string: "\n", attributes: attrs))
                }
            }
        }
    }
}

// --- section split for the tabbed reading pane ---
func splitSections(_ text: String) -> (preamble: String, sections: [(String, String)]) {
    var pre: [String] = []
    var sections: [(String, [String])] = []
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("## ") {
            let title = String(line.dropFirst(3)).replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
            sections.append((title, []))
        } else if sections.isEmpty {
            pre.append(line)
        } else {
            sections[sections.count - 1].1.append(line)
        }
    }
    return (pre.joined(separator: "\n"),
            sections.map { ($0.0, $0.1.joined(separator: "\n")) })
}

func tabLabel(_ title: String) -> String {
    if title.hasPrefix("Transcript") {
        return title.contains("English") ? "English" : "Transcript"
    }
    var s = title
    if let r = s.range(of: " (") { s = String(s[..<r.lowerBound]) }
    if s.count > 20 { s = String(s.prefix(19)) + "\u{2026}" }
    return s
}

// Tabs for docs with 2-8 "## " sections. Leading Summary / Key Points /
// Reliability sections merge into a single Overview tab. Docs outside that
// range (ledger with per-meeting headings, junk notes) render as plain scroll.
func buildTabs(_ content: String) -> [(String, String)] {
    let (pre, secs) = splitSections(content)
    guard secs.count >= 2, secs.count <= 8 else { return [] }
    let preClean = pre.components(separatedBy: "\n")
        .filter { !$0.hasPrefix("# ") && !$0.hasPrefix("<!--") }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var overview: [String] = []
    var rest: [(String, String)] = []
    for (t, b) in secs {
        if rest.isEmpty, ["Summary", "Key Points", "Reliability"].contains(t) {
            overview.append("## \(t)\n\(b)")
        } else {
            rest.append((t, b))
        }
    }
    var tabs: [(String, String)] = []
    let ovBody = (preClean.isEmpty ? "" : preClean + "\n\n") + overview.joined(separator: "\n")
    if !ovBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        tabs.append(("Overview", ovBody))
    }
    for (t, b) in rest { tabs.append((tabLabel(t), "## \(t)\n\(b)")) }
    return tabs.count >= 2 ? tabs : []
}

// Emotional-eval sibling (<name>-behavioral.md) merges into the meeting's own
// tabs instead of being a separate sidebar entry. Reliability + Speaker Map
// fold into one "Speakers" tab; long titles get short labels.
func evalTabs(_ content: String) -> [(String, String)] {
    let (_, secs) = splitSections(content)
    guard !secs.isEmpty else { return [] }
    var speakers: [String] = []
    var tabs: [(String, String)] = []
    for (t, b) in secs {
        if t.hasPrefix("Reliability") || t.hasPrefix("Speaker Map") {
            speakers.append("## \(t)\n\(b)")
        } else if t.hasPrefix("Confidence") {
            tabs.append(("Confidence", "## \(t)\n\(b)"))
        } else if t.hasPrefix("Stress") {
            tabs.append(("Moments", "## \(t)\n\(b)"))
        } else if t.hasPrefix("Behavioral Evidence") {
            tabs.append(("Evidence", "## \(t)\n\(b)"))
        } else {
            tabs.append((tabLabel(t), "## \(t)\n\(b)"))
        }
    }
    if !speakers.isEmpty {
        tabs.insert(("Speakers", speakers.joined(separator: "\n")), at: 0)
    }
    return tabs
}

// Inline markdown: **bold** runs become semibold, everything else keeps `base`.
func inlineStyled(_ line: String, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let baseFont = (base[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 13)
    let boldFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
    let parts = line.components(separatedBy: "**")
    for (i, part) in parts.enumerated() {
        var attrs = base
        // odd segments are between ** markers; unbalanced trailing ** degrades gracefully
        if i % 2 == 1 && parts.count > i + 1 { attrs[.font] = boldFont }
        out.append(NSAttributedString(string: part, attributes: attrs))
    }
    return out
}

func styled(_ text: String, isLive: Bool, questions: [String] = []) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let mono: [NSAttributedString.Key: Any] = [
        .font: DS.mono(size: 12),
        .foregroundColor: DS.textPrimary,
    ]
    if isLive {
        let livePS = NSMutableParagraphStyle(); livePS.paragraphSpacing = 4
        out.append(NSAttributedString(
            string: "ROUGH LIVE PREVIEW\n",
            attributes: [.font: DS.body(size: 10, weight: .bold),
                         .foregroundColor: DS.paleYellowText,
                         .backgroundColor: DS.paleYellowBg,
                         .kern: NSNumber(value: 0.8),
                         .paragraphStyle: livePS]))
        let liveSubPS = NSMutableParagraphStyle(); liveSubPS.paragraphSpacing = 12
        out.append(NSAttributedString(
            string: "Small model, expect errors. Accurate transcript generated after recording stops.\n\n",
            attributes: [.font: DS.body(size: 11),
                         .foregroundColor: DS.textSecondary,
                         .paragraphStyle: liveSubPS]))
        out.append(NSAttributedString(string: text, attributes: mono))
        // AI question suggestions (live-questions.sh); rendered at the end so
        // the live view's auto-scroll keeps them on screen
        if !questions.isEmpty {
            let qhPS = NSMutableParagraphStyle(); qhPS.paragraphSpacingBefore = 20; qhPS.paragraphSpacing = 6
            out.append(NSAttributedString(
                string: "\nQUESTIONS YOU COULD ASK\n",
                attributes: [.font: DS.body(size: 10, weight: .bold),
                             .foregroundColor: DS.paleBlueText,
                             .kern: NSNumber(value: 0.8),
                             .paragraphStyle: qhPS]))
            let qPS = NSMutableParagraphStyle(); qPS.lineHeightMultiple = 1.5
            for q in questions {
                out.append(NSAttributedString(
                    string: "\u{2022}  \(q)\n",
                    attributes: [.font: DS.body(size: 13),
                                 .foregroundColor: DS.paleBlueText,
                                 .paragraphStyle: qPS]))
            }
        }
        return out
    }
    // editorial body: generous line height, quiet paragraph rhythm
    let bodyPS = NSMutableParagraphStyle()
    bodyPS.lineHeightMultiple = 1.5
    bodyPS.paragraphSpacing = 6
    let body: [NSAttributedString.Key: Any] = [
        .font: DS.body(size: 13),
        .foregroundColor: DS.textPrimary,
        .paragraphStyle: bodyPS,
    ]
    // headers: system serif, tight tracking, air above, little below
    func header(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacingBefore = size >= 15 ? 28 : 16
        ps.paragraphSpacing = 8
        return [.font: DS.serif(size: size),
                .foregroundColor: DS.textPrimary,
                .kern: size >= 15 ? -0.4 : -0.2,
                .paragraphStyle: ps]
    }
    var inFence = false
    let lines = text.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        var line = lines[i]
        if line.hasPrefix("```") { inFence.toggle(); i += 1; continue }
        if inFence {
            out.append(NSAttributedString(string: line + "\n", attributes: mono))
            i += 1; continue
        }
        // HTML comments (zaatar-title marker) and horizontal rules: skip
        if line.hasPrefix("<!--") { i += 1; continue }
        if line.trimmingCharacters(in: .whitespaces) == "---" { i += 1; continue }
        // markdown table: header row + separator row -> NSTextTable
        if isTableRow(line), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
            var block: [String] = []
            while i < lines.count, isTableRow(lines[i]) { block.append(lines[i]); i += 1 }
            appendTable(block, to: out)
            out.append(NSAttributedString(string: "\n", attributes: body))
            continue
        }
        if line.hasPrefix("#### ") {
            line = String(line.dropFirst(5)).replacingOccurrences(of: "**", with: "")
            out.append(NSAttributedString(string: line + "\n", attributes: header(12)))
            i += 1; continue
        }
        if line.hasPrefix("### ") {
            line = String(line.dropFirst(4)).replacingOccurrences(of: "**", with: "")
            out.append(NSAttributedString(string: line + "\n", attributes: header(13)))
            i += 1; continue
        }
        if line.hasPrefix("## ") {
            line = String(line.dropFirst(3)).replacingOccurrences(of: "**", with: "")
            out.append(NSAttributedString(string: line + "\n", attributes: header(17)))
            i += 1; continue
        }
        // transcript timestamp lines "**[00:02:15]**" -> quiet mono meta-line
        if Prefs.timestamps, line.trimmingCharacters(in: .whitespaces).range(
            of: #"^\*\*\[\d{1,2}:\d{2}(:\d{2})?\]\*\*$"#, options: .regularExpression) != nil {
            let ts = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
            let ps = NSMutableParagraphStyle()
            ps.paragraphSpacingBefore = 20
            ps.paragraphSpacing = 4
            out.append(NSAttributedString(string: ts + "\n", attributes: [
                .font: DS.mono(size: 10, weight: .medium),
                .foregroundColor: DS.textTertiary,
                .kern: NSNumber(value: 0.5),
                .paragraphStyle: ps]))
            i += 1; continue
        }
        // checkbox lines "- [ ] ..." -> click the box to mark done in the file
        let cbLine = line.trimmingCharacters(in: .whitespaces)
        if cbLine.hasPrefix("- [ ] ") || cbLine.hasPrefix("- [x] ") {
            let done = cbLine.hasPrefix("- [x] ")
            let rest = String(cbLine.dropFirst(6))
            let key = String(UInt(bitPattern: line.hashValue))
            checkboxLines[key] = line
            var glyph = body
            glyph[.link] = URL(string: "zaatar-check://\(key)")!
            glyph[.font] = DS.body(size: 13, weight: .medium)
            glyph[.foregroundColor] = done ? DS.textTertiary : DS.brandGreen
            out.append(NSAttributedString(string: done ? "\u{2611} " : "\u{2610} ", attributes: glyph))
            var restAttrs = body
            if done {
                restAttrs[.foregroundColor] = DS.textTertiary
                restAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(inlineStyled(rest, base: restAttrs))
            // quiet trailing delete affordance: removes the line from the file
            var del = body
            del[.link] = URL(string: "zaatar-delete://\(key)")!
            del[.font] = DS.body(size: 11, weight: .medium)
            del[.foregroundColor] = DS.textTertiary
            out.append(NSAttributedString(string: "  \u{00D7}", attributes: del))
            out.append(NSAttributedString(string: "\n", attributes: body))
            i += 1; continue
        }
        if line.hasPrefix("# ") {
            line = String(line.dropFirst(2)).replacingOccurrences(of: "**", with: "")
            out.append(NSAttributedString(string: line + "\n", attributes: header(18)))
            i += 1; continue
        }
        // blockquote: indented, secondary color, left border feel via indent
        if line.hasPrefix(">") {
            let inner = line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst(1))
            let ps = NSMutableParagraphStyle()
            ps.headIndent = 20
            ps.firstLineHeadIndent = 20
            ps.lineHeightMultiple = 1.4
            ps.paragraphSpacing = 4
            var q = body
            q[.foregroundColor] = DS.textSecondary
            q[.font] = DS.serif(size: 13, weight: .regular)
            q[.paragraphStyle] = ps
            out.append(inlineStyled(inner, base: q))
            out.append(NSAttributedString(string: "\n", attributes: q))
            i += 1; continue
        }
        // checkboxes (commitment ledger): "- [ ]" / "- [x]" -> box glyphs
        line = line.replacingOccurrences(
            of: #"^(\s*)- \[ \] "#, with: "$1\u{2610}  ", options: .regularExpression)
        line = line.replacingOccurrences(
            of: #"^(\s*)- \[[xX]\] "#, with: "$1\u{2611}  ", options: .regularExpression)
        // bullets: "- item" / "* item" (any indent) -> bullet glyph
        line = line.replacingOccurrences(
            of: #"^(\s*)[-*] (?=\S)"#, with: "$1\u{2022}  ", options: .regularExpression)
        out.append(inlineStyled(line, base: body))
        out.append(NSAttributedString(string: "\n", attributes: body))
        i += 1
    }
    return out
}

enum Row {
    case header(String)
    case entry(Entry)
}

final class ViewerController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {

    // expand/collapse of truncated table cells (zaatar-toggle:// links)
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        let key = url.host ?? ""
        switch url.scheme {
        case "zaatar-toggle":
            if expandedTableCells.contains(key) { expandedTableCells.remove(key) }
            else { expandedTableCells.insert(key) }
        case "zaatar-check":
            // tick/untick the checkbox line in the underlying file
            guard let lineText = checkboxLines[key], let sel = selectedURL,
                  var content = try? String(contentsOf: sel, encoding: .utf8),
                  let r = content.range(of: lineText) else { return true }
            let toggled = lineText.contains("- [ ]")
                ? lineText.replacingOccurrences(of: "- [ ]", with: "- [x]")
                : lineText.replacingOccurrences(of: "- [x]", with: "- [ ]")
            content.replaceSubrange(r, with: toggled)
            try? content.write(to: sel, atomically: true, encoding: .utf8)
        case "zaatar-delete":
            // remove an irrelevant item from the file entirely
            guard let lineText = checkboxLines[key], let sel = selectedURL,
                  var content = try? String(contentsOf: sel, encoding: .utf8) else { return true }
            if let r = content.range(of: lineText + "\n") ?? content.range(of: lineText) {
                content.removeSubrange(r)
                content = stripOrphanHeaders(content)
                try? content.write(to: sel, atomically: true, encoding: .utf8)
            }
        case "zaatar-edittext", "zaatar-editowner", "zaatar-editdue":
            let field = url.scheme == "zaatar-edittext" ? "text" : url.scheme == "zaatar-editowner" ? "owner" : "due"
            let editKey = key
            guard !editKey.isEmpty, let item = ledgerItems[editKey], let sel = selectedURL,
                  var content = try? String(contentsOf: sel, encoding: .utf8) else { return true }
            let alert = NSAlert()
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            var newVal = ""
            if field == "due" {
                alert.messageText = "Edit due date"
                let dueContainer = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
                let editPicker = NSDatePicker(frame: NSRect(x: 0, y: 4, width: 150, height: 22))
                editPicker.datePickerStyle = .textFieldAndStepper
                editPicker.datePickerElements = .yearMonthDay
                let editDf = DateFormatter(); editDf.dateFormat = "yyyy-MM-dd"
                if let existing = editDf.date(from: item.due) { editPicker.dateValue = existing }
                else { editPicker.dateValue = Date() }
                let editNoDue = NSButton(checkboxWithTitle: "No due date", target: nil, action: nil)
                editNoDue.frame = NSRect(x: 160, y: 4, width: 120, height: 22)
                editNoDue.state = (item.due == "unspecified" || item.due.isEmpty) ? .on : .off
                dueContainer.addSubview(editPicker); dueContainer.addSubview(editNoDue)
                alert.accessoryView = dueContainer
                alert.window.initialFirstResponder = editPicker
                guard alert.runModal() == .alertFirstButtonReturn else { return true }
                if editNoDue.state == .on {
                    newVal = "unspecified"
                } else {
                    newVal = editDf.string(from: editPicker.dateValue)
                }
            } else {
                let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                switch field {
                case "text":  alert.messageText = "Edit action item"; tf.stringValue = item.text
                case "owner": alert.messageText = "Edit assignee (Name -> Recipient)"; tf.stringValue = "\(item.owner) -> \(item.recipient)"
                default: return true
                }
                alert.accessoryView = tf
                alert.window.initialFirstResponder = tf
                guard alert.runModal() == .alertFirstButtonReturn else { return true }
                newVal = tf.stringValue.trimmingCharacters(in: .whitespaces)
            }
            guard !newVal.isEmpty else { return true }
            var newLine = item.rawLine
            switch field {
            case "text":
                newLine = newLine.replacingOccurrences(of: "| \(item.text) |", with: "| \(newVal) |")
            case "owner":
                let oldOwner = "\(item.owner) -> \(item.recipient)"
                let newOwner = newVal.contains("->") ? newVal : "\(newVal) -> self"
                newLine = newLine.replacingOccurrences(of: "| \(oldOwner) |", with: "| \(newOwner) |")
            case "due":
                newLine = newLine.replacingOccurrences(of: "due: \(item.due)", with: "due: \(newVal)")
            default: break
            }
            if newLine != item.rawLine, let r = content.range(of: item.rawLine) {
                content.replaceSubrange(r, with: newLine)
                content = stripOrphanHeaders(content)
                try? content.write(to: sel, atomically: true, encoding: .utf8)
            }
        case "zaatar-add":
            guard let sel = selectedURL else { return true }
            let alert = NSAlert()
            alert.messageText = "Add action item"
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            let textLabel = NSTextField(labelWithString: "What:")
            textLabel.frame = NSRect(x: 0, y: 76, width: 50, height: 20)
            let textField = NSTextField(frame: NSRect(x: 55, y: 76, width: 245, height: 22))
            textField.placeholderString = "Action item description"
            let ownerLabel = NSTextField(labelWithString: "Who:")
            ownerLabel.frame = NSRect(x: 0, y: 46, width: 50, height: 20)
            let ownerField = NSTextField(frame: NSRect(x: 55, y: 46, width: 245, height: 22))
            ownerField.placeholderString = "Person responsible (e.g. Monojit, Jatin)"
            ownerField.stringValue = "Monojit"
            let dueLabel = NSTextField(labelWithString: "Due:")
            dueLabel.frame = NSRect(x: 0, y: 16, width: 50, height: 20)
            let duePicker = NSDatePicker(frame: NSRect(x: 55, y: 16, width: 150, height: 22))
            duePicker.datePickerStyle = .textFieldAndStepper
            duePicker.datePickerElements = .yearMonthDay
            duePicker.dateValue = Date()
            duePicker.minDate = Date()
            let noDueCheck = NSButton(checkboxWithTitle: "No due date", target: nil, action: nil)
            noDueCheck.frame = NSRect(x: 210, y: 16, width: 100, height: 22)
            noDueCheck.state = .on
            container.addSubview(textLabel); container.addSubview(textField)
            container.addSubview(ownerLabel); container.addSubview(ownerField)
            container.addSubview(dueLabel); container.addSubview(duePicker); container.addSubview(noDueCheck)
            alert.accessoryView = container
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = textField
            guard alert.runModal() == .alertFirstButtonReturn else { return true }
            let itemText = textField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !itemText.isEmpty else { return true }
            let ownerVal = ownerField.stringValue.trimmingCharacters(in: .whitespaces)
            let ownerLower = ownerVal.lowercased()
            let owner: String
            if ownerVal.isEmpty || ownerLower == "monojit" || ownerLower == "self" || ownerLower == "me" {
                owner = "Monojit -> self"
            } else {
                owner = "\(ownerVal) -> Monojit"
            }
            let dueVal: String
            if noDueCheck.state == .on {
                dueVal = "unspecified"
            } else {
                let dueDf = DateFormatter(); dueDf.dateFormat = "yyyy-MM-dd"
                dueVal = dueDf.string(from: duePicker.dateValue)
            }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let today = df.string(from: Date())
            let newLine = "- [ ] \(today) | \(owner) | \(itemText) | due: \(dueVal) | src: manual"
            let header = "## \(today) manual"
            var content = (try? String(contentsOf: sel, encoding: .utf8)) ?? ""
            if content.contains(header) {
                // Append under existing manual section for today
                if let r = content.range(of: header) {
                    let insertAt = content.index(r.upperBound, offsetBy: 0)
                    content.insert(contentsOf: "\n\(newLine)\n", at: insertAt)
                }
            } else {
                // Prepend new section (newest first)
                content = "\(header)\n\(newLine)\n\n\(content)"
            }
            try? content.write(to: sel, atomically: true, encoding: .utf8)
        case "zaatar-filter":
            ledgerFilter = (key == "all" || key.isEmpty) ? "" : key.removingPercentEncoding ?? key
        default:
            return false
        }
        let saved = textView.enclosingScrollView?.contentView.bounds.origin
        showSelection(scrollToEnd: false)
        if let o = saved { textView.scroll(o) }
        return true
    }
    // single-window app: closing the window quits (SwiftBar relaunches next time)
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    var activeEditField: String = ""
    var activeEditKey: String = ""

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let editor = notification.object as? NSTextField, editor.tag == 9999,
              !activeEditKey.isEmpty, let item = ledgerItems[activeEditKey],
              let sel = selectedURL,
              var content = try? String(contentsOf: sel, encoding: .utf8) else {
            textView.subviews.filter { $0.tag == 9999 }.forEach { $0.removeFromSuperview() }
            return
        }
        let newVal = editor.stringValue.trimmingCharacters(in: .whitespaces)
        editor.removeFromSuperview()
        guard !newVal.isEmpty else { showSelection(scrollToEnd: false); return }
        var newLine = item.rawLine
        switch activeEditField {
        case "text":
            newLine = newLine.replacingOccurrences(of: "| \(item.text) |", with: "| \(newVal) |")
        case "owner":
            let oldOwner = "\(item.owner) -> \(item.recipient)"
            let newOwner = newVal.contains("->") ? newVal : "\(newVal) -> self"
            newLine = newLine.replacingOccurrences(of: "| \(oldOwner) |", with: "| \(newOwner) |")
        case "due":
            newLine = newLine.replacingOccurrences(of: "due: \(item.due)", with: "due: \(newVal)")
        default: break
        }
        if newLine != item.rawLine, let r = content.range(of: item.rawLine) {
            content.replaceSubrange(r, with: newLine)
            content = stripOrphanHeaders(content)
            try? content.write(to: sel, atomically: true, encoding: .utf8)
        }
        activeEditField = ""; activeEditKey = ""
        showSelection(scrollToEnd: false)
    }

    let prefsController = PrefsController()

    @objc func openPrefs() {
        prefsController.show { [weak self] in self?.reload() }
    }

    var all: [Entry] = []
    var rows: [Row] = []
    let table = NSTableView()
    let textView = NSTextView()
    let search = NSSearchField()
    let segmented = NSSegmentedControl()
    var tabs: [(String, String)] = []
    var scrollTopWithTabs: NSLayoutConstraint?
    var scrollTopNoTabs: NSLayoutConstraint?
    var timer: Timer?
    var selectedURL: URL?
    var selectedFileMtime: Date = .distantPast
    var contentCache: [URL: String] = [:]

    func setTabsVisible(_ visible: Bool) {
        segmented.isHidden = !visible
        scrollTopWithTabs?.isActive = false
        scrollTopNoTabs?.isActive = false
        (visible ? scrollTopWithTabs : scrollTopNoTabs)?.isActive = true
    }

    @objc func tabChanged() { showSelection(scrollToEnd: false) }

    func reload(keepSelection: Bool = true) {
        let prev = selectedURL
        all = loadEntries()
        contentCache.removeAll()
        applyFilter()
        if keepSelection, let p = prev, let idx = rowIndex(of: p) {
            table.selectRowIndexes([idx], byExtendingSelection: false)
        }
    }

    func rowIndex(of url: URL) -> Int? {
        rows.firstIndex { if case .entry(let e) = $0 { return e.url == url }; return false }
    }

    func entry(at row: Int) -> Entry? {
        guard row >= 0, row < rows.count, case .entry(let e) = rows[row] else { return nil }
        return e
    }

    // full-text: falls back to file contents when title/subtitle don't match
    func contentMatches(_ e: Entry, _ q: String) -> Bool {
        if e.isLive || e.processing || e.failed { return false }
        if let cached = contentCache[e.url] { return cached.contains(q) }
        let c = ((try? String(contentsOf: e.url, encoding: .utf8)) ?? "").lowercased()
        contentCache[e.url] = c
        return c.contains(q)
    }

    func section(for e: Entry) -> String {
        if e.isLive { return "Live" }
        if e.pinned { return "Pinned" }
        if e.processing || e.failed { return "Processing" }
        if e.upcoming { return "Upcoming" }
        if e.title.hasPrefix("Brief: ") { return "Pre-meeting briefs" }
        let cal = Calendar.current
        if cal.isDateInToday(e.mtime) { return "Today" }
        if cal.isDateInYesterday(e.mtime) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: e.mtime, to: Date()).day ?? 999
        if days < 7 { return "This week" }
        if days < 31 { return "This month" }
        return "Earlier"
    }

    func applyFilter() {
        let q = search.stringValue.lowercased()
        let filtered = q.isEmpty ? all : all.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
                || contentMatches($0, q)
        }
        rows = []
        var current = ""
        for e in filtered {
            let sec = section(for: e)
            if sec != current { rows.append(.header(sec)); current = sec }
            rows.append(.entry(e))
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func icon(for e: Entry) -> (String, NSColor) {
        if e.isLive { return ("record.circle", DS.paleRedText) }
        if e.pinned { return ("checklist", DS.paleYellowText) }
        if e.processing { return ("arrow.triangle.2.circlepath", DS.paleYellowText) }
        if e.failed { return ("exclamationmark.triangle.fill", DS.paleRedText) }
        if e.upcoming { return ("calendar.badge.clock", DS.brandGreen) }
        if e.title.hasPrefix("Brief: ") { return ("doc.badge.clock", DS.paleBlueText) }
        return ("text.bubble", DS.textTertiary)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let name):
            let t = NSTextField(labelWithString: name.uppercased())
            t.font = DS.body(size: 10, weight: .semibold)
            t.textColor = DS.textTertiary
            let cell = NSStackView(views: [t])
            cell.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 3, right: 8)
            return cell
        case .entry(let e):
            var title = e.title
            if title.hasPrefix("Brief: ") { title = String(title.dropFirst(7)) }
            let (sym, tint) = icon(for: e)
            let iv = NSImageView()
            if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
                iv.image = img
                iv.symbolConfiguration = .init(pointSize: 12, weight: .regular)
                iv.contentTintColor = tint
            }
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let t = NSTextField(labelWithString: title)
            t.font = DS.body(size: 13, weight: e.isLive ? .semibold : .medium)
            t.textColor = e.isLive ? DS.paleRedText : DS.textPrimary
            t.lineBreakMode = .byTruncatingTail
            let s = NSTextField(labelWithString: e.subtitle)
            s.font = DS.body(size: 11)
            s.textColor = DS.textSecondary
            s.lineBreakMode = .byTruncatingTail
            let labels = NSStackView(views: [t, s])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 2
            let cell = NSStackView(views: [iv, labels])
            cell.orientation = .horizontal
            cell.alignment = .centerY
            cell.spacing = 6
            cell.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 28 }
        return 50
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // the 5s refresh re-selects the same row (reload -> selectRowIndexes);
        // re-rendering then would yank the scroll position back to the top.
        // BUT if the file changed on disk (commitment ledger grows after each
        // meeting), re-render anyway - preserving scroll - or the pane shows
        // stale content forever while the row stays selected.
        if let e = entry(at: table.selectedRow), !e.isLive, e.url == selectedURL {
            let m = ((try? FileManager.default.attributesOfItem(atPath: e.url.path))?[.modificationDate] as? Date) ?? .distantPast
            if m <= selectedFileMtime { return }
            let saved = textView.enclosingScrollView?.contentView.bounds.origin
            showSelection(scrollToEnd: false)
            if let p = saved { textView.enclosingScrollView?.contentView.scroll(to: p) }
            return
        }
        showSelection(scrollToEnd: false)
    }

    func showSelection(scrollToEnd: Bool) {
        guard let e = entry(at: table.selectedRow) else { return }
        // processing/failed rows point at the wav: fixed message, never read the file
        if e.processing || e.failed {
            selectedURL = e.url
            tabs = []
            setTabsVisible(false)
            let doc = NSMutableAttributedString()
            let titlePS = NSMutableParagraphStyle()
            titlePS.paragraphSpacing = 4
            doc.append(NSAttributedString(string: e.title + "\n",
                attributes: [.font: DS.serif(size: 24),
                             .foregroundColor: DS.textPrimary,
                             .kern: NSNumber(value: -0.6),
                             .paragraphStyle: titlePS]))
            doc.append(NSAttributedString(string: e.subtitle + "\n\n",
                attributes: [.font: DS.body(size: 12),
                             .foregroundColor: DS.textSecondary]))
            let msg = e.processing
                ? "In progress. The transcript will appear here when processing finishes."
                : "Transcription did not complete. Retry from the Zaatar menu bar."
            doc.append(NSAttributedString(string: msg,
                attributes: [.font: DS.body(size: 13),
                             .foregroundColor: DS.textSecondary]))
            textView.textStorage?.setAttributedString(doc)
            textView.scroll(.zero)
            return
        }
        // Upcoming calendar event detail view
        if e.upcoming, let ev = upcomingEvents[e.eventId] {
            selectedURL = e.url
            tabs = []
            setTabsVisible(false)
            let doc = NSMutableAttributedString()
            let titlePS = NSMutableParagraphStyle(); titlePS.paragraphSpacing = 4
            doc.append(NSAttributedString(string: ev.summary + "\n",
                attributes: [.font: DS.serif(size: 24),
                             .foregroundColor: DS.textPrimary,
                             .kern: NSNumber(value: -0.6),
                             .paragraphStyle: titlePS]))

            // Time badge
            let timePS = NSMutableParagraphStyle(); timePS.paragraphSpacing = 16
            doc.append(NSAttributedString(string: "\(ev.timeRange)  \u{00b7}  \(ev.startsIn)\n",
                attributes: [.font: DS.mono(size: 12, weight: .medium),
                             .foregroundColor: DS.brandGreen,
                             .paragraphStyle: timePS]))

            // Attendees
            if !ev.attendees.isEmpty {
                let secPS = NSMutableParagraphStyle(); secPS.paragraphSpacingBefore = 12; secPS.paragraphSpacing = 6
                doc.append(NSAttributedString(string: "ATTENDEES\n",
                    attributes: [.font: DS.body(size: 10, weight: .bold),
                                 .foregroundColor: DS.textTertiary,
                                 .kern: NSNumber(value: 0.8),
                                 .paragraphStyle: secPS]))
                let attPS = NSMutableParagraphStyle(); attPS.lineHeightMultiple = 1.6
                for a in ev.attendees {
                    doc.append(NSAttributedString(string: "\u{2022}  \(a)\n",
                        attributes: [.font: DS.body(size: 13),
                                     .foregroundColor: DS.textPrimary,
                                     .paragraphStyle: attPS]))
                }
            }

            // Meet link
            if !ev.meetLink.isEmpty {
                let linkPS = NSMutableParagraphStyle(); linkPS.paragraphSpacingBefore = 16
                doc.append(NSAttributedString(string: "JOIN MEETING\n",
                    attributes: [.font: DS.body(size: 10, weight: .bold),
                                 .foregroundColor: DS.textTertiary,
                                 .kern: NSNumber(value: 0.8),
                                 .paragraphStyle: linkPS]))
                let lPS = NSMutableParagraphStyle(); lPS.paragraphSpacingBefore = 4
                doc.append(NSAttributedString(string: ev.meetLink + "\n",
                    attributes: [.font: DS.mono(size: 12),
                                 .foregroundColor: DS.paleBlueText,
                                 .link: URL(string: ev.meetLink)! as Any,
                                 .paragraphStyle: lPS]))
            }

            // Check for pre-meeting brief
            let briefsDir = transcriptsDir.appendingPathComponent("briefs")
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let dayStr = df.string(from: ev.startTime)
            let slug = ev.summary.lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .prefix(40)
            let briefPath = briefsDir.appendingPathComponent("\(dayStr)-\(slug)-brief.md")
            if FileManager.default.fileExists(atPath: briefPath.path),
               let brief = try? String(contentsOf: briefPath, encoding: .utf8),
               !brief.isEmpty {
                let bPS = NSMutableParagraphStyle(); bPS.paragraphSpacingBefore = 24; bPS.paragraphSpacing = 8
                doc.append(NSAttributedString(string: "PRE-MEETING BRIEF\n",
                    attributes: [.font: DS.body(size: 10, weight: .bold),
                                 .foregroundColor: DS.textTertiary,
                                 .kern: NSNumber(value: 0.8),
                                 .paragraphStyle: bPS]))
                doc.append(styled(brief, isLive: false))
            }

            if ev.attendees.isEmpty && ev.meetLink.isEmpty {
                let emptyPS = NSMutableParagraphStyle(); emptyPS.paragraphSpacingBefore = 16
                doc.append(NSAttributedString(string: "No additional details available for this event.\n",
                    attributes: [.font: DS.body(size: 13),
                                 .foregroundColor: DS.textSecondary,
                                 .paragraphStyle: emptyPS]))
            }

            textView.textStorage?.setAttributedString(doc)
            textView.scroll(.zero)
            return
        }

        let urlChanged = selectedURL != e.url
        selectedURL = e.url
        selectedFileMtime = ((try? FileManager.default.attributesOfItem(atPath: e.url.path))?[.modificationDate] as? Date) ?? .distantPast
        let content = (try? String(contentsOf: e.url, encoding: .utf8)) ?? ""

        // Structured ledger view: grouped by due status, editable fields, assignee filter
        if e.pinned && e.title == "Action Items" {
            tabs = []
            setTabsVisible(false)
            let doc = renderLedger(content, url: e.url)
            textView.textStorage?.setAttributedString(doc)
            if scrollToEnd { textView.scrollToEndOfDocument(nil) } else { textView.scroll(.zero) }
            return
        }

        let display = content.isEmpty && e.isLive
            ? "Waiting for the first live chunk (~30s of audio)..." : content
        var questions: [String] = []
        if e.isLive, Prefs.liveQuestions {
            let qURL = stateDir.appendingPathComponent(
                e.url.lastPathComponent
                    .replacingOccurrences(of: "live-", with: "questions-"))
            if let q = try? String(contentsOf: qURL, encoding: .utf8) {
                questions = q.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.lowercased() != "none" }
            }
        }
        // tabbed reading pane: sectioned docs get a segmented control
        tabs = e.isLive ? [] : buildTabs(content)
        if !Prefs.behavioralRead { tabs.removeAll { $0.0 == "Behavioral Read" } }
        // merge the emotional-eval sibling as extra tabs on the meeting entry
        if Prefs.emotionalEval, !e.isLive, !e.url.lastPathComponent.hasSuffix("-behavioral.md") {
            let behURL = URL(fileURLWithPath: String(e.url.path.dropLast(3)) + "-behavioral.md")
            if let beh = try? String(contentsOf: behURL, encoding: .utf8) {
                let extra = evalTabs(beh)
                if !extra.isEmpty {
                    if tabs.isEmpty { tabs = [("Notes", content)] }
                    // the notes' short Behavioral Read is superseded by the full eval
                    tabs.removeAll { $0.0 == "Behavioral Read" }
                    tabs += extra
                }
            }
        }
        if urlChanged {
            segmented.segmentCount = tabs.count
            for (idx, t) in tabs.enumerated() { segmented.setLabel(t.0, forSegment: idx) }
            if !tabs.isEmpty { segmented.selectedSegment = 0 }
        }
        setTabsVisible(tabs.count >= 2)
        // reading-pane header: title + date (tabbed docs always get one; plain
        // docs only when they don't already open with "# ")
        let doc = NSMutableAttributedString()
        let opensWithTitle = display.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# ")
        if !e.isLive, !tabs.isEmpty || !opensWithTitle {
            var title = e.title
            if title.hasPrefix("Brief: ") { title = String(title.dropFirst(7)) }
            let titlePS = NSMutableParagraphStyle()
            titlePS.paragraphSpacing = 4
            doc.append(NSAttributedString(string: title + "\n",
                attributes: [.font: DS.serif(size: 24),
                             .foregroundColor: DS.textPrimary,
                             .kern: NSNumber(value: -0.6),
                             .paragraphStyle: titlePS]))
            if !e.subtitle.isEmpty {
                doc.append(NSAttributedString(string: e.subtitle + "\n",
                    attributes: [.font: DS.mono(size: 11),
                                 .foregroundColor: DS.textTertiary,
                                 .kern: NSNumber(value: 0.3)]))
            }
            doc.append(NSAttributedString(string: "\n"))
        }
        let bodyText: String
        if tabs.isEmpty {
            bodyText = display
        } else {
            let sel = max(0, min(segmented.selectedSegment, tabs.count - 1))
            bodyText = tabs[sel].1
        }
        doc.append(styled(bodyText, isLive: e.isLive, questions: questions))
        textView.textStorage?.setAttributedString(doc)
        if e.isLive || scrollToEnd { textView.scrollToEndOfDocument(nil) }
        else { textView.scroll(.zero) }
    }

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let hadLive = self.all.contains { $0.isLive }
            self.reload()
            let hasLive = self.all.contains { $0.isLive }
            if let sel = self.selectedURL, let idx = self.rowIndex(of: sel),
               let e = self.entry(at: idx), e.isLive {
                self.showSelection(scrollToEnd: true)
            } else if hadLive != hasLive {
                self.table.reloadData()
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Dock icon: white leaf on a green rounded rect (macOS icon shape)
app.applicationIconImage = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
    let inset = rect.insetBy(dx: 51, dy: 51) // macOS icons use ~10% margin
    let path = NSBezierPath(roundedRect: inset, xRadius: 92, yRadius: 92)
    NSGradient(starting: NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.36, alpha: 1),
               ending: NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.24, alpha: 1))?
        .draw(in: path, angle: -90)
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "Zaatar")?
        .withSymbolConfiguration(.init(pointSize: 240, weight: .medium)) {
        let tinted = NSImage(size: leaf.size, flipped: false) { r in
            leaf.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = leaf.size
        tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                               width: s.width, height: s.height))
    }
    return true
}

// minimal menu so Cmd+Q / Cmd+W / Cmd+C work
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
appMenu.addItem(NSMenuItem.separator())
let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(ViewerController.openPrefs), keyEquivalent: ",")
appMenu.addItem(prefsItem)
appMenu.addItem(NSMenuItem(title: "Quit Zaatar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appMenuItem.submenu = appMenu
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
editMenuItem.submenu = editMenu
app.mainMenu = mainMenu

let controller = ViewerController()
prefsItem.target = controller

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false
)
window.title = "Zaatar"
window.backgroundColor = DS.cardWhite
window.titlebarAppearsTransparent = true
// leaf branding in the titlebar (document-icon slot, tinted green)
window.representedURL = URL(fileURLWithPath: "/")
if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "Zaatar")?
    .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)
        .applying(.init(paletteColors: [.systemGreen]))) {
    window.standardWindowButton(.documentIconButton)?.image = leaf
}
window.minSize = NSSize(width: 640, height: 400)
window.isReleasedWhenClosed = false
window.delegate = controller
window.center()

// left pane: search + table
controller.search.placeholderString = "Search"
controller.search.font = DS.body(size: 12)
controller.search.delegate = controller

let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
controller.table.addTableColumn(col)
controller.table.headerView = nil
controller.table.dataSource = controller
controller.table.delegate = controller
controller.table.style = .inset
controller.table.rowSizeStyle = .custom

let tableScroll = NSScrollView()
tableScroll.documentView = controller.table
tableScroll.hasVerticalScroller = true
tableScroll.drawsBackground = false

let leftStack = NSStackView(views: [controller.search, tableScroll])
leftStack.orientation = .vertical
leftStack.spacing = 10
leftStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 4)
leftStack.translatesAutoresizingMaskIntoConstraints = false
leftStack.wantsLayer = true
leftStack.layer?.backgroundColor = DS.sidebarBg.cgColor
leftStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

// right pane: transcript
controller.textView.isEditable = false
controller.textView.isSelectable = true
controller.textView.delegate = controller
controller.textView.backgroundColor = DS.cardWhite
controller.textView.linkTextAttributes = [
    .foregroundColor: DS.paleBlueText,
    .cursor: NSCursor.pointingHand,
]
controller.textView.textContainerInset = NSSize(width: 32, height: 28)
controller.textView.autoresizingMask = [.width]
controller.textView.isVerticallyResizable = true
controller.textView.textContainer?.widthTracksTextView = true

let textScroll = NSScrollView()
textScroll.documentView = controller.textView
textScroll.hasVerticalScroller = true
// NSTextTable needs TextKit 1; touching layoutManager opts out of TextKit 2
_ = controller.textView.layoutManager

// centered reading column: cap the text measure at ~680pt, generous side insets
func updateTextInsets() {
    let w = textScroll.contentView.bounds.width
    let side = max(32, (w - 680) / 2)
    controller.textView.textContainerInset = NSSize(width: side, height: 32)
}
textScroll.contentView.postsFrameChangedNotifications = true
NotificationCenter.default.addObserver(
    forName: NSView.frameDidChangeNotification,
    object: textScroll.contentView, queue: .main
) { _ in updateTextInsets() }
updateTextInsets()

// right pane: tab bar (hidden for plain docs) above the transcript
controller.segmented.target = controller
controller.segmented.action = #selector(ViewerController.tabChanged)
controller.segmented.segmentStyle = .automatic
controller.segmented.isHidden = true

let rightPane = NSView()
controller.segmented.translatesAutoresizingMaskIntoConstraints = false
textScroll.translatesAutoresizingMaskIntoConstraints = false
rightPane.addSubview(controller.segmented)
rightPane.addSubview(textScroll)
controller.scrollTopWithTabs = textScroll.topAnchor.constraint(
    equalTo: controller.segmented.bottomAnchor, constant: 8)
controller.scrollTopNoTabs = textScroll.topAnchor.constraint(equalTo: rightPane.topAnchor)
NSLayoutConstraint.activate([
    controller.segmented.topAnchor.constraint(equalTo: rightPane.topAnchor, constant: 10),
    controller.segmented.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor, constant: 16),
    controller.segmented.trailingAnchor.constraint(lessThanOrEqualTo: rightPane.trailingAnchor, constant: -16),
    textScroll.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
    textScroll.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
    textScroll.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
    controller.scrollTopNoTabs!,
])

let split = NSSplitView()
split.isVertical = true
split.dividerStyle = .thin
split.addArrangedSubview(leftStack)
split.addArrangedSubview(rightPane)
rightPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
// sidebar keeps its width when the window resizes; divider stays draggable
split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
window.contentView = split

controller.reload(keepSelection: false)
if let first = controller.rows.firstIndex(where: { if case .entry = $0 { return true }; return false }) {
    controller.table.selectRowIndexes([first], byExtendingSelection: false)
}
controller.startTimer()

window.makeKeyAndOrderFront(nil)
split.setPosition(300, ofDividerAt: 0)
if CommandLine.arguments.contains("--prefs") {
    controller.openPrefs()
}
app.activate(ignoringOtherApps: true)
app.run()
