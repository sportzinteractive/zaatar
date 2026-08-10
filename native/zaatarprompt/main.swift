// zaatarprompt - Granola-style floating meeting prompt for Zaatar
// Drop-in replacement for `osascript display dialog` in meet-watch.sh:
// shows a rounded, non-activating panel top-right (visible over full-screen
// apps, never steals focus), prints the clicked button label to stdout.
// Timeout prints "timeout". --url is opened when the primary button is clicked.
//
// Usage:
//   zaatarprompt --title "Weekly Sync" --subtitle "13:00 - 13:15" \
//     --primary "Join & Record" --button "Skip" [--url <meet-link>] [--timeout 55]

import AppKit

var title = "Zaatar"
var subtitle = ""
var timeout: Double = 55
var urlString: String?
var primaryLabel: String?
var secondaryLabels: [String] = []

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--title":    title = it.next() ?? title
    case "--subtitle": subtitle = it.next() ?? subtitle
    case "--timeout":  timeout = Double(it.next() ?? "") ?? timeout
    case "--url":      urlString = it.next()
    case "--primary":  primaryLabel = it.next()
    case "--button":   if let b = it.next() { secondaryLabels.append(b) }
    default: break
    }
}

func finish(_ result: String) -> Never {
    print(result)
    exit(0)
}

final class Handler: NSObject {
    @objc func clicked(_ sender: NSButton) {
        if sender.tag == 1, let u = urlString, let nsu = URL(string: u) {
            NSWorkspace.shared.open(nsu)
        }
        finish(sender.title)
    }
}
let handler = Handler()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// --- branding ---
let brandGreen = NSColor(calibratedRed: 0.36, green: 0.47, blue: 0.26, alpha: 1.0)

let badge = NSView()
badge.wantsLayer = true
badge.layer?.backgroundColor = brandGreen.cgColor
badge.layer?.cornerRadius = 18
badge.translatesAutoresizingMaskIntoConstraints = false
badge.widthAnchor.constraint(equalToConstant: 36).isActive = true
badge.heightAnchor.constraint(equalToConstant: 36).isActive = true

let glyph: NSView
if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "Zaatar") {
    let iv = NSImageView(image: leaf)
    iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
    iv.contentTintColor = .white
    glyph = iv
} else {
    let z = NSTextField(labelWithString: "Z")
    z.font = .systemFont(ofSize: 18, weight: .bold)
    z.textColor = .white
    glyph = z
}
glyph.translatesAutoresizingMaskIntoConstraints = false
badge.addSubview(glyph)
NSLayoutConstraint.activate([
    glyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
    glyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
])

let brandField = NSTextField(labelWithString: "ZAATAR")
brandField.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
brandField.textColor = brandGreen

// --- views ---
let titleField = NSTextField(labelWithString: title)
titleField.font = .systemFont(ofSize: 14, weight: .semibold)
titleField.lineBreakMode = .byTruncatingTail
titleField.maximumNumberOfLines = 1

let subtitleField = NSTextField(labelWithString: subtitle)
subtitleField.font = .systemFont(ofSize: 12)
subtitleField.textColor = .secondaryLabelColor

var buttonViews: [NSButton] = []
for label in secondaryLabels {
    let b = NSButton(title: label, target: handler, action: #selector(Handler.clicked(_:)))
    b.bezelStyle = .rounded
    b.controlSize = .large
    buttonViews.append(b)
}
if let p = primaryLabel {
    let b = NSButton(title: p, target: handler, action: #selector(Handler.clicked(_:)))
    b.bezelStyle = .rounded
    b.controlSize = .large
    b.tag = 1
    b.bezelColor = brandGreen
    b.keyEquivalent = "\r"
    buttonViews.append(b)
}

let textStack = NSStackView(views: subtitle.isEmpty ? [brandField, titleField] : [brandField, titleField, subtitleField])
textStack.orientation = .vertical
textStack.alignment = .leading
textStack.spacing = 2

let buttonStack = NSStackView(views: buttonViews)
buttonStack.orientation = .horizontal
buttonStack.spacing = 8

let rootStack = NSStackView(views: [badge, textStack, buttonStack])
rootStack.orientation = .horizontal
rootStack.alignment = .centerY
rootStack.spacing = 20
rootStack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 14)
rootStack.translatesAutoresizingMaskIntoConstraints = false
titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

let effect = NSVisualEffectView()
effect.material = .popover
effect.blendingMode = .behindWindow
effect.state = .active
effect.wantsLayer = true
effect.layer?.cornerRadius = 14
effect.layer?.masksToBounds = true
effect.addSubview(rootStack)
NSLayoutConstraint.activate([
    rootStack.topAnchor.constraint(equalTo: effect.topAnchor),
    rootStack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    rootStack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
    rootStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
])

let size = effect.fittingSize
let panel = NSPanel(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.contentView = effect
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.level = .statusBar
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.isMovableByWindowBackground = true
panel.hidesOnDeactivate = false

// top-right, just under the menu bar
if let screen = NSScreen.main {
    let vf = screen.visibleFrame
    panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 12))
}

panel.alphaValue = 0
panel.orderFrontRegardless()
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.25
    panel.animator().alphaValue = 1
}

DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.2
        panel.animator().alphaValue = 0
    }, completionHandler: { finish("timeout") })
}

app.run()
