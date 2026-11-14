import AppKit
import ImageIO
import SwiftUI
import ImageconverterCore

/// The chosen file's name with a small thumbnail, loaded off the main actor. An SVG goes through the same
/// sanitiser the batch uses, so a refused file shows why here, before a run.
struct WatermarkThumbnail: View {
    let path: String
    @State private var thumbnail: NSImage?
    @State private var problem: String?

    var body: some View {
        if path.isEmpty {
            Text("No image chosen").font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.warnText)
        } else {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                HStack(spacing: LadaGlass.Spacing.s) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFit()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(LadaGlass.Typography.body)
                        .foregroundStyle(LadaGlass.Colors.text).lineLimit(1).truncationMode(.middle)
                }
                if let problem {
                    Text(problem).font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.warnText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Problem: \(problem)")
                }
            }
            .task(id: path) {
                thumbnail = nil
                problem = nil
                let loaded = await Self.loadThumbnail(path: path)
                guard !Task.isCancelled else { return }
                switch loaded {
                case .success(let image): thumbnail = image
                case .failure(let error): problem = error.reason
                }
            }
        }
    }

    private static func loadThumbnail(path: String) async -> Result<NSImage, ConversionError> {
        await Task.detached(priority: .utility) { () -> Result<NSImage, ConversionError> in
            let fileURL = URL(fileURLWithPath: path)
            if SVGRasterizer.isSVG(fileURL) {
                do {
                    let image = try SVGRasterizer.rasterize(url: fileURL)
                    return .success(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                } catch {
                    return .failure(error as? ConversionError ?? .watermarkSVGInvalid)
                }
            }
            guard let header = ImageLoader.header(of: fileURL),
                  header.width <= ImageLoader.defaultMaxPixels / header.height else {
                return .failure(.watermarkImageUnreadable)
            }
            let url = fileURL as CFURL
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
            ]
            guard let source = CGImageSourceCreateWithURL(url, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return .failure(.watermarkImageUnreadable)
            }
            return .success(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        }.value
    }
}
