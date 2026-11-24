// Drives QuickMark's real code through its event loop: posted key and mouse events,
// responder-chain actions, Apple Events and pasteboards. Run with `swift run QuickMarkTests`.
// Windows flash on screen while it runs. The general clipboard is saved and restored.
//
// State machines under test:
//   App windows   welcome / editors / none, via launch, open, paste, drop, close, reopen
//   Tool          box / fill / pen per window, via B F P keys, toolbar picker, Tools menu
//   Gesture       idle / drawing per window, via mouse down, drag, up
//   Undo          the shapes stack, via draw, Cmd+Z, Cmd+Shift+Z
//   Document      untitled / file-backed, saved / closed, via save, close, copy
//   Drop target   idle / targeted, via drag enter, exit, drop
// Not covered: the Open and Save dialogs (modal), and real app activation.

import AppKit
@testable import QuickMarkKit

// MARK: - Harness

setvbuf(stdout, nil, _IOLBF, 0)  // Keep output if a check crashes.
var passed = 0
var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failures.append("line \(line): \(what)")
        print("    FAIL line \(line): \(what)")
    }
}

func section(_ title: String) { print("• \(title)") }

/// A process started from a terminal can't make itself the active app, so its windows never
/// become key. This reports the window under test as key and main, which is what AppKit's
/// event and action routing reads.
final class TestApp: NSApplication {
    var focused: NSWindow?
    override var keyWindow: NSWindow? { focused ?? super.keyWindow }
    override var mainWindow: NSWindow? { focused ?? super.mainWindow }
}

let app = TestApp.shared as! TestApp
let delegate = setUpApp() as! AppDelegate

/// Runs the event loop, so posted events, Apple Events and async work are handled.
func pump(_ seconds: TimeInterval = 0.05) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
        app.sendEvent(event)
    }
}

@discardableResult
func wait(_ timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline { pump(0.02) }
    return condition()
}

let keyCodes: [String: UInt16] = ["b": 11, "f": 3, "p": 35, "z": 6, "s": 1, "c": 8, "v": 9, "w": 13]

func keyEvents(_ chars: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> [NSEvent] {
    let chars = flags.contains(.shift) ? chars.uppercased() : chars  // As real Shift presses report.
    return [NSEvent.EventType.keyDown, .keyUp].map { type in
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: keyCodes[chars.lowercased()]!)!
    }
}

func press(_ chars: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) {
    app.focused = window
    keyEvents(chars, flags, in: window).forEach { app.postEvent($0, atStart: false) }
    pump()
}

func mouseEvent(_ type: NSEvent.EventType, _ point: CGPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
}

func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in window: NSWindow) {
    app.focused = window
    let event = mouseEvent(type, point, in: window)
    // Delivered to the view under the pointer, as AppKit's hit-testing would. Going through
    // NSWindow.sendEvent can block on mouse down, waiting for a follow-up event we haven't posted.
    let view = window.contentView!.hitTest(window.contentView!.convert(point, from: nil))!
    switch type {
    case .leftMouseDown: view.mouseDown(with: event)
    case .leftMouseDragged: view.mouseDragged(with: event)
    default: view.mouseUp(with: event)
    }
    // No pump: delivery is synchronous, and running the event loop inside a gesture (which the
    // app never does) stops AppKit closing the undo group at the end of the pass.
}

func welcomeVisible() -> Bool { app.windows.contains { $0 is WelcomeWindow && $0.isVisible } }
func editorWindows() -> [NSWindow] { app.windows.filter { $0.windowController is EditorWindowController && $0.isVisible } }
func documents() -> [NSDocument] { NSDocumentController.shared.documents }

func closeAllDocuments() {
    documents().forEach { $0.close() }
    pump()
}

/// Sends the Apple Event macOS sends when the Dock icon is clicked.
func reopen() {
    let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    _ = try? event.sendEvent(options: [.noReply], timeout: 1)
    pump(0.2)
}

// MARK: Images and pasteboards

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("QuickMarkTests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

/// A white image. `dpi: nil` writes no resolution metadata.
func imageData(width: Int = 800, height: Int = 600, dpi: Double? = 72,
               type: String = "public.png", gray: Bool = false) -> Data {
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: (gray ? CGImageAlphaInfo.none : .noneSkipLast).rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
    let properties = dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] } ?? [:]
    CGImageDestinationAddImage(destination, ctx.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

func imageFile(_ name: String, dpi: Double? = 72, type: String = "public.png") -> URL {
    let url = tmp.appendingPathComponent(name)
    try! imageData(dpi: dpi, type: type).write(to: url)
    return url
}

struct RGB { var r, g, b: CGFloat }

/// sRGB colour at pixel (x, y), with y counted from the bottom like shape coordinates.
func pixel(_ data: Data, _ x: Int, _ y: Int) -> RGB {
    let rep = NSBitmapImageRep(data: data)!
    let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)!.usingColorSpace(.sRGB)!
    return RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
}

func isRed(_ c: RGB) -> Bool { c.r > 0.8 && c.g < 0.4 && c.b < 0.4 }
func isBlack(_ c: RGB) -> Bool { c.r < 0.1 && c.g < 0.1 && c.b < 0.1 }
func isWhite(_ c: RGB) -> Bool { c.r > 0.9 && c.g > 0.9 && c.b > 0.9 }

func dpi(of data: Data) -> Double? {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return properties?[kCGImagePropertyDPIWidth] as? Double
}

func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: .init("QuickMarkTests-\(UUID().uuidString)"))
}

/// Runs `body` and puts the user's clipboard back afterwards.
func preservingClipboard(_ body: () -> Void) {
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    body()
    pasteboard.clearContents()
    pasteboard.writeObjects(saved.map { pairs in
        let item = NSPasteboardItem()
        for (type, data) in pairs { item.setData(data, forType: type) }
        return item
    })
}

// MARK: Editors

func open(_ url: URL) -> ImageDocument? {
    var done = false
    var result: NSDocument?
    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
        result = document
        done = true
        if let error { print("    open failed: \(error)") }
    }
    wait { done }
    return result as? ImageDocument
}

struct Editor {
    let document: ImageDocument
    var controller: EditorWindowController { document.windowControllers.first as! EditorWindowController }
    var window: NSWindow { controller.window! }
    var canvas: CanvasView { controller.canvas }
    var shapes: [Shape] { document.markup.shapes }

    init(_ document: ImageDocument) {
        self.document = document
        window.layoutIfNeeded()
    }

    /// Window coordinates of an image pixel.
    func point(_ p: CGPoint) -> CGPoint { canvas.convert(p.applying(canvas.imageToView), to: nil) }

    /// Mouse down on the first point, drags through the rest, mouse up on the last.
    func drag(_ points: [CGPoint]) {
        mouse(.leftMouseDown, point(points[0]), in: window)
        for p in points.dropFirst() { mouse(.leftMouseDragged, point(p), in: window) }
        mouse(.leftMouseUp, point(points.last!), in: window)
    }

    func key(_ chars: String, _ flags: NSEvent.ModifierFlags = []) { press(chars, flags, in: window) }
}

func openEditor(_ name: String = "plain.png", dpi: Double? = 72, type: String = "public.png") -> Editor {
    Editor(open(imageFile(name, dpi: dpi, type: type))!)
}

func approx(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
}

func rect(of shape: Shape?) -> CGRect? {
    switch shape {
    case .box(let r), .fill(let r): r
    default: nil
    }
}

// MARK: - App windows

func testAppWindows() {
    section("App windows: launch with no file → welcome")
    check(wait { welcomeVisible() }, "welcome window shows at launch")
    check(editorWindows().isEmpty, "no editor at launch")

    section("App windows: welcome → open file → editor, welcome closes")
    let editor = openEditor()
    check(editorWindows().count == 1, "editor window shows")
    check(!welcomeVisible(), "welcome closes when an editor opens")

    section("App windows: editor → reopen (Dock click) → no welcome")
    reopen()
    check(!welcomeVisible(), "reopen with an editor open shows no welcome")

    section("App windows: editor → close last → none")
    editor.key("w", .command)
    check(wait { editorWindows().isEmpty }, "Cmd+W closes the editor")
    check(!welcomeVisible(), "closing the last editor doesn't show the welcome")

    section("App windows: none → reopen → welcome; welcome → reopen → one welcome")
    reopen()
    check(welcomeVisible(), "reopen with no windows shows the welcome")
    reopen()
    check(app.windows.filter { $0 is WelcomeWindow }.count == 1, "reopen doesn't duplicate the welcome")

    section("App windows: welcome → close → none → reopen → welcome")
    let welcome = app.windows.first { $0 is WelcomeWindow }!
    welcome.performClose(nil)
    pump()
    check(!welcomeVisible(), "welcome closes")
    reopen()
    check(welcomeVisible(), "closed welcome comes back on reopen")

    section("App windows: welcome → Cmd+V")
    preservingClipboard {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("not an image", forType: .string)
        press("v", .command, in: welcome)
        check(documents().isEmpty, "pasting text opens nothing")
        check(welcomeVisible(), "welcome stays after pasting text")

        pasteboard.clearContents()
        pasteboard.setData(imageData(dpi: 144), forType: .png)
        press("v", .command, in: welcome)
        check(documents().count == 1, "pasting an image opens it")
        check(documents().first?.fileURL == nil, "pasted image is untitled")
        check(!welcomeVisible(), "welcome closes after pasting an image")
        closeAllDocuments()

        reopen()
        let url = imageFile("pasted-file.png")
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        press("v", .command, in: welcome)
        check(wait { documents().first?.fileURL == url }, "pasting a copied file opens that file")
        check(!welcomeVisible(), "welcome closes after pasting a file")
        closeAllDocuments()
    }
}

// MARK: - Pasteboard and drop input

final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

func testInput() {
    section("Input: pasteboard contents → documents")
    var pasteboard = privatePasteboard()
    pasteboard.setData(imageData(dpi: 144), forType: .png)
    check(ImageDocument.open(from: pasteboard), "PNG data opens")
    let pasted = documents().last as? ImageDocument
    check(pasted?.fileURL == nil && pasted?.fileType == "public.png", "PNG data opens as untitled PNG")
    check(pasted?.markup.scale == 2, "pasted PNG keeps its Retina scale")
    closeAllDocuments()

    pasteboard = privatePasteboard()
    pasteboard.setData(NSImage(data: imageData())!.tiffRepresentation!, forType: .tiff)
    check(ImageDocument.open(from: pasteboard) && documents().count == 1, "TIFF data opens")
    closeAllDocuments()

    // Copying a file in Finder puts both the file URL and the file's icon (TIFF) on the pasteboard.
    let file = imageFile("finder-copy.png")
    pasteboard = privatePasteboard()
    pasteboard.writeObjects([file as NSURL])
    pasteboard.addTypes([.tiff], owner: nil)
    pasteboard.setData(NSImage(data: imageData(width: 32, height: 32))!.tiffRepresentation!, forType: .tiff)
    check(ImageDocument.open(from: pasteboard), "Finder copy opens")
    check(wait { documents().count == 1 } && documents()[0].fileURL == file, "Finder copy opens the file, not its icon")
    closeAllDocuments()

    pasteboard = privatePasteboard()
    pasteboard.writeObjects([imageFile("one.png") as NSURL, imageFile("two.png") as NSURL])
    check(ImageDocument.open(from: pasteboard), "two copied files open")
    check(wait { documents().count == 2 }, "two copied files open two documents")
    closeAllDocuments()

    pasteboard = privatePasteboard()
    pasteboard.setString("text", forType: .string)
    check(!ImageDocument.open(from: pasteboard) && documents().isEmpty, "text opens nothing")

    section("Drop target: idle ⇄ targeted, drop opens")
    let view = DropView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
    let image = privatePasteboard()
    image.setData(imageData(), forType: .png)
    check(!view.targeted, "starts idle")
    check(view.draggingEntered(FakeDrag(image)) == .copy && view.targeted, "drag enter → targeted")
    view.draggingExited(FakeDrag(image))
    check(!view.targeted, "drag exit → idle")
    _ = view.draggingEntered(FakeDrag(image))
    check(view.performDragOperation(FakeDrag(image)) && !view.targeted, "drop → idle, accepted")
    check(documents().count == 1, "dropped image opens")
    closeAllDocuments()

    let file2 = imageFile("dropped.png")
    let files = privatePasteboard()
    files.writeObjects([file2 as NSURL])
    _ = view.draggingEntered(FakeDrag(files))
    check(view.performDragOperation(FakeDrag(files)), "dropped file accepted")
    check(wait { documents().first?.fileURL == file2 }, "dropped file opens")
    closeAllDocuments()

    let text = privatePasteboard()
    text.setString("text", forType: .string)
    _ = view.draggingEntered(FakeDrag(text))
    check(!view.performDragOperation(FakeDrag(text)) && !view.targeted, "dropped text rejected → idle")
    check(documents().isEmpty, "dropped text opens nothing")
}

// MARK: - Tool

func toolState(_ e: Editor) -> (tool: Tool, picker: Int, checked: [Int]) {
    let menu = app.mainMenu!.item(withTitle: "Tools")!.submenu!
    app.focused = e.window
    menu.update()  // Validates through the responder chain, setting the checkmarks.
    return (e.canvas.tool, e.controller.picker?.selectedSegment ?? -1,
            menu.items.filter { $0.state == .on }.map(\.tag))
}

func consistent(_ e: Editor, _ tool: Tool) -> Bool {
    let state = toolState(e)
    return state.tool == tool && state.picker == tool.rawValue && state.checked == [tool.rawValue]
}

func clickPicker(_ e: Editor, _ tool: Tool) {
    let picker = e.controller.picker!
    picker.selectedSegment = tool.rawValue
    picker.sendAction(picker.action, to: picker.target)
}

func chooseMenuItem(_ e: Editor, _ tool: Tool) {
    let item = app.mainMenu!.item(withTitle: "Tools")!.submenu!.items[tool.rawValue]
    app.focused = e.window
    app.sendAction(item.action!, to: nil, from: item)
}

func testTool() {
    let e = openEditor()
    section("Tool: starts as box")
    check(consistent(e, .box), "box, picker and menu agree")

    section("Tool: every transition via key, picker and menu")
    let routes: [(String, (Editor, Tool) -> Void)] = [
        ("key", { e, tool in e.key(tool.key) }), ("picker", clickPicker), ("menu", chooseMenuItem),
    ]
    for (route, perform) in routes {
        for from in Tool.allCases {
            for to in Tool.allCases {
                clickPicker(e, from)
                perform(e, to)
                check(consistent(e, to), "\(from) → \(to) via \(route): got \(toolState(e))")
            }
        }
    }

    section("Tool: keys work whatever has focus in the window")
    for (label, responder) in [("window", nil), ("picker", e.controller.picker), ("canvas", e.canvas)] as [(String, NSResponder?)] {
        clickPicker(e, .box)
        e.window.makeFirstResponder(responder)
        e.key("p")
        check(consistent(e, .pen), "P with \(label) focused")
    }
    e.window.makeFirstResponder(e.canvas)

    section("Tool: modifier keys (including Shift) don't switch; Caps Lock does")
    for flags in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
        clickPicker(e, .box)
        e.key("f", flags)
        check(consistent(e, .box), "\(flags) + F leaves the tool alone")
    }
    clickPicker(e, .box)
    e.key("F", .capsLock)
    check(consistent(e, .fill), "Caps Lock + F → fill")

    section("Tool: each window has its own tool")
    let other = openEditor("other.png")
    clickPicker(e, .box)
    clickPicker(other, .box)
    other.key("f")
    check(consistent(other, .fill) && consistent(e, .box), "F in one window leaves the other alone")

    section("Tool: closing a window leaves the others' keys working")
    other.key("w", .command)
    check(wait { other.document.windowControllers.isEmpty }, "other window closed")
    e.key("p")
    check(consistent(e, .pen), "P still works in the remaining window")
    closeAllDocuments()
}

// MARK: - Gesture

func testGesture() {
    let e = openEditor()
    let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 300, y: 250)
    let ab = CGRect(x: 100, y: 100, width: 200, height: 150)

    section("Gesture: click without dragging")
    clickPicker(e, .box); e.drag([a])
    check(e.shapes.isEmpty, "box click draws nothing")
    clickPicker(e, .fill); e.drag([a])
    check(e.shapes.isEmpty, "filled box click draws nothing")
    clickPicker(e, .pen); e.drag([a])
    check(e.shapes.count == 1, "pen click draws a dot")
    if case .pen(let points) = e.shapes.last { check(points.count == 1, "dot has one point") }
    e.document.setShapes([])

    section("Gesture: idle → down → drag (preview) → up (commit)")
    for (tool, expected) in [(Tool.box, Shape.box(ab)), (.fill, .fill(ab))] {
        clickPicker(e, tool)
        mouse(.leftMouseDown, e.point(a), in: e.window)
        check(e.canvas.drawing == nil, "\(tool): nothing previewed before dragging")
        mouse(.leftMouseDragged, e.point(b), in: e.window)
        check(approx(rect(of: e.canvas.drawing) ?? .null, ab), "\(tool): drag previews the shape")
        check(e.shapes.isEmpty, "\(tool): nothing committed while dragging")
        mouse(.leftMouseUp, e.point(b), in: e.window)
        check(e.canvas.drawing == nil, "\(tool): preview cleared on mouse up")
        check(e.shapes.count == 1 && approx(rect(of: e.shapes.first) ?? .null, ab)
              && String(describing: e.shapes[0]).hasPrefix(String(describing: expected).prefix(4)),
              "\(tool): mouse up commits \(expected), got \(e.shapes)")
        e.document.setShapes([])

        e.drag([b, a])
        check(approx(rect(of: e.shapes.first) ?? .null, ab), "\(tool): dragging backwards gives the same rect")
        e.document.setShapes([])
    }
    clickPicker(e, .pen)
    e.drag([a, b, CGPoint(x: 400, y: 120)])
    if case .pen(let points) = e.shapes.first {
        check(points.count == 3, "pen records every drag point")
    } else { check(false, "pen drag commits a pen stroke, got \(e.shapes)") }
    e.document.setShapes([])

    section("Gesture: switching tool mid-drag doesn't change the shape being drawn")
    clickPicker(e, .pen)
    mouse(.leftMouseDown, e.point(a), in: e.window)
    mouse(.leftMouseDragged, e.point(b), in: e.window)
    e.key("b")
    mouse(.leftMouseDragged, e.point(CGPoint(x: 400, y: 120)), in: e.window)
    mouse(.leftMouseUp, e.point(CGPoint(x: 400, y: 120)), in: e.window)
    if case .pen(let points) = e.shapes.first { check(points.count == 3, "pen stroke completes as pen") }
    else { check(false, "pen → B mid-drag still commits a pen stroke, got \(e.shapes)") }
    check(e.canvas.tool == .box, "the new tool applies to the next gesture")
    e.document.setShapes([])

    mouse(.leftMouseDown, e.point(a), in: e.window)
    mouse(.leftMouseDragged, e.point(b), in: e.window)
    e.key("p")
    mouse(.leftMouseDragged, e.point(CGPoint(x: 400, y: 300)), in: e.window)
    mouse(.leftMouseUp, e.point(CGPoint(x: 400, y: 300)), in: e.window)
    check(approx(rect(of: e.shapes.first) ?? .null, CGRect(x: 100, y: 100, width: 300, height: 200)),
          "box → P mid-drag still commits a box, got \(e.shapes)")
    e.document.setShapes([])

    section("Gesture: stray drag or mouse up without mouse down")
    let stray = NSEvent.mouseEvent(with: .leftMouseDragged, location: e.point(b), modifierFlags: [], timestamp: 0,
                                   windowNumber: e.window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: 1)!
    e.canvas.mouseDragged(with: stray)
    e.canvas.mouseUp(with: stray)
    check(e.shapes.isEmpty && e.canvas.drawing == nil, "ignored")

    section("Gesture: letterboxed window maps clicks to the right pixels")
    e.window.setContentSize(CGSize(width: 400, height: 600))
    e.window.layoutIfNeeded()
    let origin = CGPoint.zero.applying(e.canvas.imageToView)
    let scale = e.canvas.imageToView.a
    check(abs(scale - 0.5) < 0.01 && abs(origin.x) < 0.5 && abs(origin.y - 150) < 0.5,
          "800×600 image in 400×600 view: scale 0.5, offset 150, got \(scale) \(origin)")
    clickPicker(e, .box)
    e.drag([a, b])
    check(approx(rect(of: e.shapes.first) ?? .null, ab), "drag in letterboxed view lands on the same pixels")
    closeAllDocuments()
}

// MARK: - Undo

/// AppKit closes an undo group after each event it dispatches. So here, unlike elsewhere, each
/// action posts its events and returns; the app's own event loop delivers them, and the next
/// step checks the result.
func testUndo() {
    var e: Editor!
    var undo: UndoManager!
    let boxA = CGRect(x: 50, y: 50, width: 100, height: 100), boxB = CGRect(x: 200, y: 200, width: 100, height: 50)

    func act(_ body: @escaping () -> Void) {
        step {
            check(undo.groupingLevel == 0, "each action starts a new undo group")
            body()
        }
    }
    func postKey(_ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        keyEvents(chars, flags, in: e.window).forEach { app.postEvent($0, atStart: false) }
    }
    func postBox(_ r: CGRect) {
        app.focused = e.window
        for (type, p) in [(NSEvent.EventType.leftMouseDown, r.origin), (.leftMouseDragged, CGPoint(x: r.maxX, y: r.maxY)),
                          (.leftMouseUp, CGPoint(x: r.maxX, y: r.maxY))] {
            app.postEvent(mouseEvent(type, e.point(p), in: e.window), atStart: false)
        }
    }

    step {
        e = openEditor()
        undo = e.document.undoManager!
        pump(0.2)  // Let the new window finish layout, so posted clicks land where computed.
        section("Undo: the window uses the document's undo manager")
        check(e.window.undoManager === undo, "same undo manager")
        check(!undo.canUndo && !undo.canRedo, "nothing to undo at first")
        section("Undo: [] → A → AB → undo → A → undo → [] → redo → A → redo → AB")
        clickPicker(e, .box)
    }
    act { postBox(boxA) }
    act { postBox(boxB) }
    step { check(e.shapes.count == 2, "two shapes, got \(e.shapes.count)") }
    act { postKey("z", .command) }
    step { check(e.shapes.count == 1 && approx(rect(of: e.shapes[0]) ?? .null, boxA), "Cmd+Z removes the last shape") }
    act { postKey("z", .command) }
    step { check(e.shapes.isEmpty && !undo.canUndo, "Cmd+Z again empties it") }
    act { postKey("z", .command) }
    step { check(e.shapes.isEmpty, "Cmd+Z with nothing to undo does nothing") }
    act { postKey("z", [.command, .shift]) }
    step { check(e.shapes.count == 1, "Cmd+Shift+Z redoes A") }
    act { postKey("z", [.command, .shift]) }
    step {
        check(e.shapes.count == 2 && approx(rect(of: e.shapes[1]) ?? .null, boxB), "Cmd+Shift+Z redoes B")
        check(!undo.canRedo, "nothing left to redo")
        section("Undo: drawing after undo clears redo")
    }
    act { postKey("z", .command) }
    act { postBox(CGRect(x: 500, y: 300, width: 100, height: 100)) }
    step {
        check(e.shapes.count == 2 && !undo.canRedo, "new shape replaces the redo history")
        closeAllDocuments()
    }
}

// MARK: - Document

func testDocument() {
    section("Document: open a Retina PNG")
    let e = openEditor("retina.png", dpi: 144)
    let url = e.document.fileURL!
    check(e.document.markup.scale == 2, "144 dpi → scale 2")
    check(e.document.fileType == "public.png", "file type PNG")

    section("Document: drawing never marks it edited, so close and quit don't prompt")
    clickPicker(e, .box)
    e.drag([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)])
    check(!e.document.isDocumentEdited, "not edited after drawing")
    check(!NSDocumentController.shared.hasEditedDocuments, "quit won't ask to save")

    section("Document: Cmd+S overwrites the file")
    e.key("s", .command)
    wait { (try? Data(contentsOf: url)).map { isRed(pixel($0, 100, 200)) } ?? false }
    let saved = try! Data(contentsOf: url)
    check(isRed(pixel(saved, 100, 200)), "box edge is red in the saved file")
    check(isWhite(pixel(saved, 200, 200)), "box inside is untouched")
    check(saved.starts(with: [0x89, 0x50, 0x4E, 0x47]), "still PNG")
    check(dpi(of: saved) == 144, "keeps 144 dpi")

    section("Document: Cmd+W discards unsaved shapes without asking")
    clickPicker(e, .fill)
    e.drag([CGPoint(x: 500, y: 100), CGPoint(x: 600, y: 200)])
    let window = e.window
    e.key("w", .command)
    check(window.attachedSheet == nil, "no save prompt")
    check(wait { documents().isEmpty }, "document closed")
    check(isWhite(pixel(try! Data(contentsOf: url), 550, 150)), "unsaved fill not written")

    section("Document: reopening an open file returns the same document")
    let first = open(url)
    check(open(url) === first, "same document")
    closeAllDocuments()

    section("Document: JPEG saves as JPEG")
    let jpeg = openEditor("photo.jpg", type: "public.jpeg")
    clickPicker(jpeg, .fill)
    jpeg.drag([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200)])
    jpeg.key("s", .command)
    wait { (try? Data(contentsOf: jpeg.document.fileURL!)).map { isBlack(pixel($0, 150, 150)) } ?? false }
    let jpegData = try! Data(contentsOf: jpeg.document.fileURL!)
    check(jpegData.starts(with: [0xFF, 0xD8]), "still JPEG")
    check(isBlack(pixel(jpegData, 150, 150)), "fill saved")
    closeAllDocuments()

    section("Document: untitled → save as → file-backed → Cmd+S overwrites")
    let pasteboard = privatePasteboard()
    pasteboard.setData(imageData(), forType: .png)
    _ = ImageDocument.open(from: pasteboard)
    let untitled = Editor(documents().last as! ImageDocument)
    check(untitled.document.fileURL == nil, "starts untitled")
    clickPicker(untitled, .box)
    untitled.drag([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)])
    let target = tmp.appendingPathComponent("saved-as.png")
    var saveDone = false
    var saveError: Error?
    untitled.document.save(to: target, ofType: "public.png", for: .saveAsOperation) { saveError = $0; saveDone = true }
    wait { saveDone }
    check(saveDone && saveError == nil, "save as succeeds: \(String(describing: saveError))")
    check(untitled.document.fileURL == target, "document now points at the file")
    check(isRed(pixel(try! Data(contentsOf: target), 100, 200)), "box saved")
    clickPicker(untitled, .fill)
    untitled.drag([CGPoint(x: 500, y: 100), CGPoint(x: 600, y: 200)])
    untitled.key("s", .command)
    check(wait { isBlack(pixel(try! Data(contentsOf: target), 550, 150)) }, "Cmd+S overwrites the saved file")

    section("Document: Cmd+C copies the marked-up image")
    preservingClipboard {
        untitled.key("c", .command)
        let copied = NSPasteboard.general.data(forType: .png)
        check(copied != nil, "PNG on the clipboard")
        if let copied {
            check(isRed(pixel(copied, 100, 200)) && isBlack(pixel(copied, 550, 150)), "copy includes the shapes")
        }
    }
    closeAllDocuments()
}

// MARK: - Encoding

func testEncoding() {
    section("Encoding: resolution → scale")
    for (dpi, scale) in [(72.0, 1.0), (144, 2), (216, 3), (36, 1)] as [(Double, CGFloat)] {
        check(Markup(data: imageData(dpi: dpi))?.scale == scale, "\(dpi) dpi → scale \(scale)")
    }
    check(Markup(data: imageData(dpi: nil))?.scale == 1, "no dpi → scale 1")
    check(Markup(data: Data("not an image".utf8)) == nil, "garbage → nil")

    section("Encoding: greyscale image saves in colour")
    var markup = Markup(data: imageData(gray: true))!
    markup.shapes = [.box(CGRect(x: 100, y: 100, width: 200, height: 200))]
    check(isRed(pixel(markup.data(type: "public.png")!, 100, 200)), "red stays red")
}

// MARK: - Run

/// Steps run in separate passes of the event loop, with the loop idle in between.
var steps: [() -> Void] = []
func step(_ body: @escaping () -> Void) { steps.append(body) }

func runSteps() {
    guard !steps.isEmpty else {
        try? FileManager.default.removeItem(at: tmp)
        print(failures.isEmpty ? "\nAll \(passed) checks passed." : "\n\(failures.count) of \(passed + failures.count) checks failed.")
        exit(failures.isEmpty ? 0 : 1)
    }
    steps.removeFirst()()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: runSteps)
}

step(testAppWindows)
step(testInput)
step(testTool)
step(testGesture)
testUndo()
step(testDocument)
step(testEncoding)
DispatchQueue.main.async(execute: runSteps)
app.run()
