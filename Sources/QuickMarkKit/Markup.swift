import AppKit
import ImageIO

enum Tool: Int, CaseIterable {
    case box, fill, pen

    /// Menu and tooltip title, key equivalent and SF Symbol.
    private var info: (title: String, key: String, symbol: String) {
        switch self {
        case .box: ("Box", "b", "rectangle")
        case .fill: ("Filled Box", "f", "rectangle.fill")
        case .pen: ("Pen", "p", "scribble")
        }
    }

    var title: String { info.title }
    var key: String { info.key }
    var symbol: String { info.symbol }
}

enum Shape: Equatable {
    case box(CGRect)
    case fill(CGRect)
    case pen([CGPoint])
}

/// An image plus the shapes drawn on it. Shapes are in image pixels, origin bottom-left.
struct Markup {
    var image: CGImage
    /// Pixels per point: 2 for Retina screenshots. Keeps strokes the same visual width.
    var scale: CGFloat
    var shapes: [Shape] = []

    var size: CGSize { CGSize(width: image.width, height: image.height) }

    private static let red = CGColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1)
    private static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// Single drawing routine, used both on screen and for export.
    func draw(in ctx: CGContext, extra: Shape? = nil) {
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.setLineWidth(3 * scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for shape in shapes + [extra].compactMap({ $0 }) {
            switch shape {
            case .box(let rect):
                ctx.setStrokeColor(Self.red)
                ctx.stroke(rect)
            case .fill(let rect):
                ctx.setFillColor(Self.black)
                ctx.fill(rect)
            case .pen(let points):
                ctx.setStrokeColor(Self.red)
                ctx.addLines(between: points.count == 1 ? points + points : points)
                ctx.strokePath()
            }
        }
    }
}

// MARK: - Encoding

extension Markup {
    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        // Photos often store their rotation as an EXIF tag. Saving drops the tag, so bake it into the pixels.
        let rotated = (properties?[kCGImagePropertyOrientation] as? Int ?? 1) != 1
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                                     properties?[kCGImagePropertyPixelHeight] as? Int ?? 0),
        ]
        guard let image = rotated
            ? CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            : CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let dpi = properties?[kCGImagePropertyDPIWidth] as? Double ?? 72
        self.init(image: image, scale: max(1, dpi / 72))
    }

    /// Flattens the shapes into the image and encodes it as `type` (a UTI such as public.png).
    func data(type: String) -> Data? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(in: ctx)
        guard let flattened = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)
        else { return nil }
        let dpi = 72 * scale
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, flattened, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
