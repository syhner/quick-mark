import AppKit
import UniformTypeIdentifiers

/// Named for Objective-C so Info.plist's NSDocumentClass can refer to it.
@objc(ImageDocument)
final class ImageDocument: NSDocument {
    var markup: Markup!

    /// Closing never asks to save: the document never reports unsaved changes.
    override var isDocumentEdited: Bool { false }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
        WelcomeWindow.closeAll()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let markup = Markup(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        self.markup = markup
    }

    /// Saves in the format the image came in; pasted images are PNG.
    override func data(ofType typeName: String) throws -> Data {
        guard let data = markup.data(type: typeName) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    func setShapes(_ shapes: [Shape]) {
        let old = markup.shapes
        undoManager?.registerUndo(withTarget: self) { $0.setShapes(old) }
        markup.shapes = shapes
        windowControllers.forEach { $0.window?.contentView?.needsDisplay = true }
    }

    /// Opens image files from a paste or drop, or raw image data as a new untitled PNG.
    /// Returns false if there was nothing to open.
    /// Checks the types before reading, so macOS's clipboard privacy prompt only shows when there may be an image.
    static func open(from pasteboard: NSPasteboard) -> Bool {
        // Copying a file in Finder also puts its icon on the pasteboard: never open that instead.
        if pasteboard.availableType(from: [.fileURL]) != nil {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: readableTypes,
            ]) as? [URL] ?? []
            for url in urls { NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in } }
            return !urls.isEmpty
        }
        guard let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type),
              let markup = Markup(data: data)
        else { return false }
        let document = ImageDocument()
        document.markup = markup
        document.fileType = UTType.png.identifier
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        return true
    }

    @objc func copy(_ sender: Any?) {
        guard let data = markup.data(type: UTType.png.identifier) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }
}
