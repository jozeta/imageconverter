import Accelerate
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Scales images with a chosen interpolation. Every method keeps the source's RGB colour space
/// (sRGB for other models), 8 or 16 bits per component (32-bit float stays float) and stays
/// opaque when the source has no alpha, like the other steps.
public enum Resampler {
    public static func scale(_ image: CGImage, to size: (Int, Int), method: Resampling) throws -> CGImage {
        let (width, height) = size
        guard width >= 1, height >= 1, width <= ImageOps.maxPixels / height else {
            throw ConversionError.processingFailed(StepKind.resize.displayName)
        }
        let result: CGImage?
        switch method {
        // Lanczos and bicubic fall back to Core Graphics' high quality if their framework can't
        // handle the pixel format, so an unusual file still resizes.
        case .lanczos: result = lanczos(image, width: width, height: height) ?? drawn(image, width, height, .high)
        case .bicubic: result = bicubic(image, width: width, height: height) ?? drawn(image, width, height, .high)
        case .bilinear: result = drawn(image, width, height, .low)
        case .nearest: result = drawn(image, width, height, .none)
        }
        guard let result else { throw ConversionError.processingFailed(StepKind.resize.displayName) }
        return result
    }

    // MARK: Core Graphics

    private static func drawn(_ image: CGImage, _ width: Int, _ height: Int,
                              _ quality: CGInterpolationQuality) -> CGImage? {
        guard let ctx = ImageOps.makeContext(width: width, height: height, like: image,
                                             alpha: ImageOps.hasAlpha(image), keepFloat: true) else { return nil }
        ctx.interpolationQuality = quality
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: Core Image (bicubic)

    private static func bicubic(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let scaleY = Double(height) / Double(image.height)
        let scaleX = Double(width) / Double(image.width)
        let filter = CIFilter.bicubicScaleTransform()
        // Clamped so the edges sample real pixels instead of fading into transparency.
        filter.inputImage = CIImage(cgImage: image).clampedToExtent()
        filter.scale = Float(scaleY)
        filter.aspectRatio = Float(scaleX / scaleY)
        filter.parameterB = 0
        filter.parameterC = 0.75
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let output = filter.outputImage,
              let ctx = ImageOps.makeContext(width: width, height: height, like: image,
                                             alpha: ImageOps.hasAlpha(image), keepFloat: true),
              let space = ctx.colorSpace,
              let rendered = SharedCIContext.context.createCGImage(
                output, from: rect, format: ciFormat(bits: ctx.bitsPerComponent), colorSpace: space) else { return nil }
        // Same size: this only puts the pixels into the agreed format (depth, opacity).
        ctx.interpolationQuality = .none
        ctx.draw(rendered, in: rect)
        return ctx.makeImage()
    }

    private static func ciFormat(bits: Int) -> CIFormat {
        switch bits {
        case 32: return .RGBAf
        case 16: return .RGBA16
        default: return .RGBA8
        }
    }

    // MARK: vImage (Lanczos)

    private static func lanczos(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let alpha = ImageOps.hasAlpha(image)
        let bits = ImageOps.isFloat(image) ? 32 : (image.bitsPerComponent > 8 ? 16 : 8)
        var spaces: [CGColorSpace] = []
        if let own = image.colorSpace, own.model == .rgb { spaces.append(own) }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { spaces.append(srgb) }
        var layouts = [CGImageAlphaInfo.premultipliedLast]
        if !alpha { layouts.insert(.noneSkipLast, at: 0) }
        let order: CGBitmapInfo = bits == 32 ? [.byteOrder32Little, .floatComponents]
            : bits == 16 ? .byteOrder16Little : []
        for space in spaces {
            for layout in layouts {
                let info = CGBitmapInfo(rawValue: layout.rawValue).union(order)
                guard let format = vImage_CGImageFormat(bitsPerComponent: bits, bitsPerPixel: bits * 4,
                                                        colorSpace: space, bitmapInfo: info) else { continue }
                if let result = lanczos(image, width: width, height: height, format: format,
                                        clip: layout == .premultipliedLast) {
                    return result
                }
            }
        }
        return nil
    }

    private static func lanczos(_ image: CGImage, width: Int, height: Int, format: vImage_CGImageFormat,
                                clip: Bool) -> CGImage? {
        guard var source = try? vImage_Buffer(cgImage: image, format: format) else { return nil }
        defer { source.free() }
        guard var target = try? vImage_Buffer(width: width, height: height,
                                              bitsPerPixel: format.bitsPerPixel) else { return nil }
        defer { target.free() }
        let flags = vImage_Flags(kvImageHighQualityResampling)
        // The scalers treat the four channels alike, so RGBA order works with the ARGB functions.
        let error: vImage_Error
        switch format.bitsPerComponent {
        case 8: error = vImageScale_ARGB8888(&source, &target, nil, flags)
        case 16: error = vImageScale_ARGB16U(&source, &target, nil, flags)
        default: error = vImageScale_ARGBFFFF(&source, &target, nil, flags)
        }
        guard error == kvImageNoError else { return nil }
        // Lanczos rings: keep premultiplied colour at or below alpha so edges stay valid.
        if clip { clipToAlpha(&target, bits: Int(format.bitsPerComponent)) }
        return try? target.createCGImage(format: format)
    }

    /// Clamps every premultiplied pixel to 0 ≤ colour ≤ alpha ≤ 1 (16-bit and float: SIMD per pixel,
    /// since vImage has no 16-bit clip and its float clip lets negatives through).
    private static func clipToAlpha(_ buffer: inout vImage_Buffer, bits: Int) {
        let width = Int(buffer.width)
        switch bits {
        case 8:
            _ = vImageClipToAlpha_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        case 16:
            for row in 0..<Int(buffer.height) {
                let pixels = buffer.data.advanced(by: row * buffer.rowBytes).assumingMemoryBound(to: SIMD4<UInt16>.self)
                for index in 0..<width {
                    let pixel = pixels[index]
                    pixels[index] = pointwiseMin(pixel, SIMD4(repeating: pixel.w))
                }
            }
        default:
            let zero = SIMD4<Float>(repeating: 0)
            for row in 0..<Int(buffer.height) {
                let pixels = buffer.data.advanced(by: row * buffer.rowBytes).assumingMemoryBound(to: SIMD4<Float>.self)
                for index in 0..<width {
                    let pixel = pixels[index]
                    let alpha = min(max(pixel.w, 0), 1)
                    pixels[index] = pixel.clamped(lowerBound: zero, upperBound: SIMD4(repeating: alpha))
                }
            }
        }
    }
}
