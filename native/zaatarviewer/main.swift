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
    var pinned: Bool = false
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

    // Pinned: commitment ledger (action items extracted from every meeting)
    let ledger = transcriptsDir.appendingPathComponent("ledger/commitments.md")
    if let content = try? String(contentsOf: ledger, encoding: .utf8) {
        let open = content.components(separatedBy: "\n").filter { $0.hasPrefix("- [ ]") }.count
        entries.append(Entry(title: "Action Items", subtitle: "\(open) open \u{00b7} commitment ledger",
                             url: ledger, isLive: false, mtime: .distantFuture, pinned: true))
    }

    // Pre-meeting briefs ("YYYY-MM-DD-slug-brief.md"), sorted in with transcripts
    let briefsDir = transcriptsDir.appendingPathComponent("briefs")
    if let files = try? fm.contentsOfDirectory(at: briefsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
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
            let (fallback, when) = humanTitle(from: f.lastPathComponent)
            let name = storedTitle(of: f) ?? fallback
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            entries.append(Entry(title: name, subtitle: when, url: f, isLive: false, mtime: mtime))
        }
    }
    return entries.sorted {
        if $0.isLive != $1.isLive { return $0.isLive }
        if $0.pinned != $1.pinned { return $0.pinned }
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
                    ? NSColor.separatorColor
                    : NSColor.separatorColor.withAlphaComponent(0.5), for: .maxY)
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
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .kern: 0.6,
                    .paragraphStyle: ps,
                ]
                out.append(NSAttributedString(string: cell.uppercased() + "\n", attributes: attrs))
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: ps,
                ]
                out.append(inlineStyled(cell, base: attrs))
                out.append(NSAttributedString(string: "\n", attributes: attrs))
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
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]
    if isLive {
        out.append(NSAttributedString(
            string: "ROUGH LIVE PREVIEW (small model, expect errors) - the accurate transcript is generated after the recording stops\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                         .foregroundColor: NSColor.systemOrange]))
        out.append(NSAttributedString(string: text, attributes: mono))
        // AI question suggestions (live-questions.sh); rendered at the end so
        // the live view's auto-scroll keeps them on screen
        if !questions.isEmpty {
            out.append(NSAttributedString(
                string: "\nQUESTIONS YOU COULD ASK\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                             .foregroundColor: NSColor.systemTeal]))
            for q in questions {
                out.append(NSAttributedString(
                    string: "\u{2022}  \(q)\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 13),
                                 .foregroundColor: NSColor.systemTeal]))
            }
        }
        return out
    }
    // editorial body: relaxed line height, quiet paragraph rhythm
    let bodyPS = NSMutableParagraphStyle()
    bodyPS.lineHeightMultiple = 1.3
    bodyPS.paragraphSpacing = 5
    let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: bodyPS,
    ]
    // headers: tight tracking, air above, little below
    func header(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacingBefore = size >= 15 ? 24 : 14
        ps.paragraphSpacing = 6
        return [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .kern: -0.2,
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
        if line.trimmingCharacters(in: .whitespaces).range(
            of: #"^\*\*\[\d{1,2}:\d{2}(:\d{2})?\]\*\*$"#, options: .regularExpression) != nil {
            let ts = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
            let ps = NSMutableParagraphStyle()
            ps.paragraphSpacingBefore = 16
            ps.paragraphSpacing = 3
            out.append(NSAttributedString(string: ts + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: ps]))
            i += 1; continue
        }
        if line.hasPrefix("# ") {
            line = String(line.dropFirst(2)).replacingOccurrences(of: "**", with: "")
            out.append(NSAttributedString(string: line + "\n", attributes: header(18)))
            i += 1; continue
        }
        // blockquote: indented, secondary color
        if line.hasPrefix(">") {
            let inner = line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst(1))
            let ps = NSMutableParagraphStyle()
            ps.headIndent = 16
            ps.firstLineHeadIndent = 16
            ps.lineHeightMultiple = 1.25
            ps.paragraphSpacing = 3
            var q = body
            q[.foregroundColor] = NSColor.secondaryLabelColor
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

final class ViewerController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    // single-window app: closing the window quits (SwiftBar relaunches next time)
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

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
        if e.isLive { return false }
        if let cached = contentCache[e.url] { return cached.contains(q) }
        let c = ((try? String(contentsOf: e.url, encoding: .utf8)) ?? "").lowercased()
        contentCache[e.url] = c
        return c.contains(q)
    }

    func section(for e: Entry) -> String {
        if e.isLive { return "Live" }
        if e.pinned { return "Pinned" }
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
        if e.isLive { return ("record.circle", .systemRed) }
        if e.pinned { return ("checklist", .systemOrange) }
        if e.title.hasPrefix("Brief: ") { return ("doc.badge.clock", .systemTeal) }
        return ("text.bubble", .secondaryLabelColor)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let name):
            let t = NSTextField(labelWithString: name.uppercased())
            t.font = .systemFont(ofSize: 10, weight: .semibold)
            t.textColor = .tertiaryLabelColor
            let cell = NSStackView(views: [t])
            cell.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 2, right: 6)
            return cell
        case .entry(let e):
            var title = e.title
            if title.hasPrefix("Brief: ") { title = String(title.dropFirst(7)) }
            let (sym, tint) = icon(for: e)
            let iv = NSImageView()
            if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
                iv.image = img
                iv.symbolConfiguration = .init(pointSize: 13, weight: .regular)
                iv.contentTintColor = tint
            }
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 13, weight: e.isLive ? .bold : .medium)
            t.textColor = e.isLive ? .systemRed : .labelColor
            t.lineBreakMode = .byTruncatingTail
            let s = NSTextField(labelWithString: e.subtitle)
            s.font = .systemFont(ofSize: 11)
            s.textColor = .secondaryLabelColor
            s.lineBreakMode = .byTruncatingTail
            let labels = NSStackView(views: [t, s])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 1
            let cell = NSStackView(views: [iv, labels])
            cell.orientation = .horizontal
            cell.alignment = .centerY
            cell.spacing = 4
            cell.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 6)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 24 }
        return 44
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // the 5s refresh re-selects the same row (reload -> selectRowIndexes);
        // re-rendering then would yank the scroll position back to the top
        if let e = entry(at: table.selectedRow), !e.isLive, e.url == selectedURL { return }
        showSelection(scrollToEnd: false)
    }

    func showSelection(scrollToEnd: Bool) {
        guard let e = entry(at: table.selectedRow) else { return }
        let urlChanged = selectedURL != e.url
        selectedURL = e.url
        let content = (try? String(contentsOf: e.url, encoding: .utf8)) ?? ""
        let display = content.isEmpty && e.isLive
            ? "Waiting for the first live chunk (~30s of audio)..." : content
        var questions: [String] = []
        if e.isLive {
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
            titlePS.paragraphSpacing = 3
            doc.append(NSAttributedString(string: title + "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                             .foregroundColor: NSColor.labelColor,
                             .kern: -0.4,
                             .paragraphStyle: titlePS]))
            if !e.subtitle.isEmpty {
                doc.append(NSAttributedString(string: e.subtitle + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 12),
                                 .foregroundColor: NSColor.secondaryLabelColor]))
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
controller.search.placeholderString = "Search meetings, briefs, action items"
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
leftStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

// right pane: transcript
controller.textView.isEditable = false
controller.textView.isSelectable = true
controller.textView.textContainerInset = NSSize(width: 26, height: 20)
controller.textView.autoresizingMask = [.width]
controller.textView.isVerticallyResizable = true
controller.textView.textContainer?.widthTracksTextView = true

let textScroll = NSScrollView()
textScroll.documentView = controller.textView
textScroll.hasVerticalScroller = true
// NSTextTable needs TextKit 1; touching layoutManager opts out of TextKit 2
_ = controller.textView.layoutManager

// centered reading column: cap the text measure at ~720pt, grow side insets beyond it
func updateTextInsets() {
    let w = textScroll.contentView.bounds.width
    let side = max(26, (w - 720) / 2)
    controller.textView.textContainerInset = NSSize(width: side, height: 24)
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
split.setPosition(280, ofDividerAt: 0)
app.activate(ignoringOtherApps: true)
app.run()
