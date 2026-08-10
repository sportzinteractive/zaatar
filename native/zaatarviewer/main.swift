// zaatarviewer - Zaatar transcript browser
// Left: searchable list of past meeting transcripts (Outputs/transcripts/*.md,
// -raw files excluded) plus a LIVE row while a recording is in progress.
// Right: styled transcript view. Live view tails the rough live transcript
// (live-transcribe.sh) and auto-refreshes every 5s.

import AppKit

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

struct Entry {
    let title: String
    let subtitle: String
    let url: URL
    let isLive: Bool
    let mtime: Date
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
    if let pidStr = try? String(contentsOf: stateDir.appendingPathComponent("rec.pid"), encoding: .utf8),
       let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(pid, 0) == 0,
       let liveFiles = try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil) {
        for f in liveFiles where f.lastPathComponent.hasPrefix("live-") && f.pathExtension == "txt" {
            let raw = f.lastPathComponent
                .replacingOccurrences(of: "live-", with: "")
            let (name, when) = humanTitle(from: raw)
            entries.append(Entry(title: "LIVE  \(name)", subtitle: when.isEmpty ? "recording now" : "\(when) - recording now",
                                 url: f, isLive: true, mtime: .distantFuture))
        }
    }

    if let files = try? fm.contentsOfDirectory(at: transcriptsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
        for f in files where f.pathExtension == "md" && !f.lastPathComponent.hasSuffix("-raw.md") {
            let (fallback, when) = humanTitle(from: f.lastPathComponent)
            let name = storedTitle(of: f) ?? fallback
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            entries.append(Entry(title: name, subtitle: when, url: f, isLive: false, mtime: mtime))
        }
    }
    return entries.sorted { $0.mtime > $1.mtime }
}

func styled(_ text: String, isLive: Bool) -> NSAttributedString {
    let out = NSMutableAttributedString()
    if isLive {
        out.append(NSAttributedString(
            string: "ROUGH LIVE PREVIEW (small model, expect errors) - the accurate transcript is generated after the recording stops\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                         .foregroundColor: NSColor.systemOrange]))
    }
    let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.labelColor,
    ]
    let mono: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]
    func header(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
         .foregroundColor: NSColor.labelColor]
    }
    for lineSub in text.components(separatedBy: "\n") {
        var line = lineSub
        var attrs = isLive ? mono : body
        if line.hasPrefix("### ") { line = String(line.dropFirst(4)); attrs = header(13) }
        else if line.hasPrefix("## ") { line = String(line.dropFirst(3)); attrs = header(15) }
        else if line.hasPrefix("# ") { line = String(line.dropFirst(2)); attrs = header(18) }
        line = line.replacingOccurrences(of: "**", with: "")
        out.append(NSAttributedString(string: line + "\n", attributes: attrs))
    }
    return out
}

final class ViewerController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    // single-window app: closing the window quits (SwiftBar relaunches next time)
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    var all: [Entry] = []
    var filtered: [Entry] = []
    let table = NSTableView()
    let textView = NSTextView()
    let search = NSSearchField()
    var timer: Timer?
    var selectedURL: URL?

    func reload(keepSelection: Bool = true) {
        let prev = selectedURL
        all = loadEntries()
        applyFilter()
        if keepSelection, let p = prev, let idx = filtered.firstIndex(where: { $0.url == p }) {
            table.selectRowIndexes([idx], byExtendingSelection: false)
        }
    }

    func applyFilter() {
        let q = search.stringValue.lowercased()
        filtered = q.isEmpty ? all : all.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = filtered[row]
        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 1
        cell.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        let t = NSTextField(labelWithString: e.title)
        t.font = .systemFont(ofSize: 13, weight: e.isLive ? .bold : .medium)
        t.textColor = e.isLive ? .systemRed : .labelColor
        t.lineBreakMode = .byTruncatingTail
        let s = NSTextField(labelWithString: e.subtitle)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        cell.addArrangedSubview(t)
        cell.addArrangedSubview(s)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 42 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSelection(scrollToEnd: false)
    }

    func showSelection(scrollToEnd: Bool) {
        guard table.selectedRow >= 0, table.selectedRow < filtered.count else { return }
        let e = filtered[table.selectedRow]
        selectedURL = e.url
        let content = (try? String(contentsOf: e.url, encoding: .utf8)) ?? ""
        let display = content.isEmpty && e.isLive
            ? "Waiting for the first live chunk (~30s of audio)..." : content
        textView.textStorage?.setAttributedString(styled(display, isLive: e.isLive))
        if e.isLive || scrollToEnd { textView.scrollToEndOfDocument(nil) }
    }

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let hadLive = self.all.contains { $0.isLive }
            self.reload()
            let hasLive = self.all.contains { $0.isLive }
            if let sel = self.selectedURL,
               let e = self.filtered.first(where: { $0.url == sel }), e.isLive {
                self.showSelection(scrollToEnd: true)
            } else if hadLive != hasLive {
                self.table.reloadData()
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// minimal menu so Cmd+Q / Cmd+W / Cmd+C work
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
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

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false
)
window.title = "Zaatar"
window.minSize = NSSize(width: 640, height: 400)
window.isReleasedWhenClosed = false
window.delegate = controller
window.center()

// left pane: search + table
controller.search.placeholderString = "Search meetings"
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
leftStack.spacing = 8
leftStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 4)
leftStack.translatesAutoresizingMaskIntoConstraints = false
leftStack.widthAnchor.constraint(equalToConstant: 280).isActive = true

// right pane: transcript
controller.textView.isEditable = false
controller.textView.isSelectable = true
controller.textView.textContainerInset = NSSize(width: 18, height: 16)
controller.textView.autoresizingMask = [.width]
controller.textView.isVerticallyResizable = true
controller.textView.textContainer?.widthTracksTextView = true

let textScroll = NSScrollView()
textScroll.documentView = controller.textView
textScroll.hasVerticalScroller = true

let split = NSStackView(views: [leftStack, textScroll])
split.orientation = .horizontal
split.spacing = 0
split.distribution = .fill
window.contentView = split

controller.reload(keepSelection: false)
if !controller.filtered.isEmpty {
    controller.table.selectRowIndexes([0], byExtendingSelection: false)
}
controller.startTimer()

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
