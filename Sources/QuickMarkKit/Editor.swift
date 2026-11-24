import AppKit

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let canvas: CanvasView
    private static let toolsItem = NSToolbarItem.Identifier("tools")

    init(document: ImageDocument) {
        canvas = CanvasView(document: document)

        // Open at the image's point size, shrunk to fit the screen. Below 360pt wide the
        // toolbar pushes the tool picker into its overflow menu, so small images get letterboxed.
        let markup = document.markup!
        let size = CGSize(width: markup.size.width / markup.scale, height: markup.size.height / markup.scale)
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let fit = min(1, screen.width * 0.9 / size.width, (screen.height * 0.9 - 60) / size.height)
        let minSize = CGSize(width: 360, height: 200)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: max(minSize.width, size.width * fit),
                                height: max(minSize.height, size.height * fit)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentView = canvas
        window.contentMinSize = minSize
        window.center()
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "editor")
        toolbar.delegate = self
        toolbar.centeredItemIdentifiers = [Self.toolsItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.delegate = self
        window.makeFirstResponder(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.toolsItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.toolsItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let picker = NSSegmentedControl(
            images: Tool.allCases.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
            trackingMode: .selectOne, target: self, action: #selector(selectTool(_:)))
        for tool in Tool.allCases {
            picker.setToolTip("\(tool.title) (\(tool.key.uppercased()))", forSegment: tool.rawValue)
        }
        picker.selectedSegment = canvas.tool.rawValue
        picker.refusesFirstResponder = true  // Keep keyboard focus on the canvas.
        self.picker = picker
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = picker
        return item
    }

    weak var picker: NSSegmentedControl?

    private func select(_ tool: Tool) {
        canvas.tool = tool
        picker?.selectedSegment = tool.rawValue
    }

    /// Sender is a Tools menu item (tag) or the toolbar picker (selected segment).
    @objc func selectTool(_ sender: Any?) {
        let index = (sender as? NSSegmentedControl)?.selectedSegment ?? (sender as? NSMenuItem)?.tag ?? 0
        select(Tool(rawValue: index) ?? .box)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectTool(_:)) { item.state = item.tag == canvas.tool.rawValue ? .on : .off }
        return true
    }
}

final class CanvasView: NSView {
    private unowned let document: ImageDocument
    var tool = Tool.box
    /// Nil when idle. Set on mouse down; the tool stays fixed until mouse up.
    private var gesture: (tool: Tool, start: CGPoint)?
    /// The shape being drawn, shown but not yet committed.
    private(set) var drawing: Shape?

    init(document: ImageDocument) {
        self.document = document
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }  // Drags draw; they never move the window.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// Maps image pixels into the view: fitted and centred.
    var imageToView: CGAffineTransform {
        let size = document.markup.size
        let s = min(bounds.width / size.width, bounds.height / size.height)
        return CGAffineTransform(translationX: (bounds.width - size.width * s) / 2,
                                 y: (bounds.height - size.height * s) / 2)
            .scaledBy(x: s, y: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.concatenate(imageToView)
        ctx.interpolationQuality = .high
        document.markup.draw(in: ctx, extra: drawing)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).applying(imageToView.inverted())
    }

    override func mouseDown(with event: NSEvent) {
        let start = imagePoint(event)
        gesture = (tool, start)
        drawing = tool == .pen ? .pen([start]) : nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (tool, start) = gesture else { return }
        let point = imagePoint(event)
        let rect = CGRect(x: start.x, y: start.y, width: point.x - start.x, height: point.y - start.y).standardized
        switch tool {
        case .box: drawing = .box(rect)
        case .fill: drawing = .fill(rect)
        case .pen: if case .pen(let points) = drawing { drawing = .pen(points + [point]) }
        }
        needsDisplay = true
    }

    /// Commits the shape. A box or filled box clicked without dragging draws nothing.
    override func mouseUp(with event: NSEvent) {
        let shape = drawing
        gesture = nil
        drawing = nil
        needsDisplay = true
        if let shape { document.setShapes(document.markup.shapes + [shape]) }
    }
}
