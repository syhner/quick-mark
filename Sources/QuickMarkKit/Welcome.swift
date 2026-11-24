import AppKit

/// Shown when no images are open. Opening an editor closes it (ImageDocument.makeWindowControllers).
final class WelcomeWindow: NSWindow {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 360, height: 240),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "QuickMark"
        isReleasedWhenClosed = false
        contentView = DropView()
        center()
    }

    static func closeAll() {
        NSApp.windows.filter { $0 is WelcomeWindow }.forEach { $0.close() }
    }
}

/// Accepts dropped files or image data; a click shows the Open dialog. Cmd+V reaches AppDelegate.paste.
final class DropView: NSView {
    private(set) var targeted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        targeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false
        return ImageDocument.open(from: sender.draggingPasteboard)
    }

    override func mouseUp(with event: NSEvent) {
        NSDocumentController.shared.openDocument(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 20, dy: 20), xRadius: 12, yRadius: 12)
        outline.lineWidth = 2
        outline.setLineDash([6, 4], count: 2, phase: 0)
        (targeted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        outline.stroke()

        drawCentered("Drop an image", y: bounds.midY + 4,
                     font: .systemFont(ofSize: 17, weight: .medium), color: .labelColor)
        drawCentered("⌘V to paste · click or ⌘O to open", y: bounds.midY - 22,
                     font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    }

    private func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        string.draw(at: CGPoint(x: bounds.midX - string.size().width / 2, y: y))
    }
}
