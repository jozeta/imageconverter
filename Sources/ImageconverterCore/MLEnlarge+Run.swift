import Accelerate
import CoreGraphics
import Foundation

extension MLEnlarge {
    /// Enlarges `image` by `factor` (2, 3 or 4) with `scaler`: the image is cut into overlapping tiles
    /// (`tiling`), each tile goes through the model at its 4×, is brought down to `factor` with Lanczos when that is
    /// smaller, and is feathered into one row strip, and each strip into the output, with linear ramps across the
    /// overlaps. The model sees 8-bit colour in the image's RGB colour space (other models: sRGB) and the result is
    /// tagged with it; alpha never goes through the model but is enlarged separately with Lanczos.
    ///
    /// Refused before any work when the model isn't ready (`ConversionError.mlEnlargeUnavailable`) or the result
    /// breaks `limits` (`mlEnlargeTooLarge`). A deeper source adds `eightBitNote`.
    public static func enlarge(_ image: CGImage, factor: Int, scaler: any SuperResolutionScaler,
                               tiling: MLEnlargeTiling = .standard, limits: DecodeLimits = .standard,
                               notes: inout [String]) throws -> CGImage {
        let availability = scaler.availability()
        guard availability.isReady else { throw ConversionError.mlEnlargeUnavailable(availability) }
        let scale = clampedFactor(factor)
        try checkLimits(input: CGSize(width: image.width, height: image.height), factor: scale, limits: limits,
                        tiling: tiling)
        let failed = ConversionError.processingFailed(StepKind.resize.displayName)
        guard scaler.factor >= scale, let space = workingSpace(of: image) else { throw failed }
        if image.bitsPerComponent > 8 { notes.append(eightBitNote) }
        let alpha = ImageOps.hasAlpha(image)
        var source = try SourcePixels(image, space: space, alpha: alpha)
        let output = try enlargedColour(of: &source, scale: scale, scaler: scaler, tiling: tiling, space: space)
        try finishAlpha(output, source: &source, alpha: alpha)
        let info = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)
        guard let provider = CGDataProvider(data: output.data),
              let result = CGImage(width: output.width, height: output.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: output.width * 4, space: space, bitmapInfo: info, provider: provider,
                                   decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw failed }
        return result
    }

    /// The colour space the model works in: the image's own when it is RGB, else sRGB.
    static func workingSpace(of image: CGImage) -> CGColorSpace? {
        if let own = image.colorSpace, own.model == .rgb { return own }
        return CGColorSpace(name: CGColorSpace.sRGB)
    }

    // MARK: Buffers

    /// The source as straight RGBA8 (alpha forced to 255 for the model) and, with alpha, its alpha plane.
    struct SourcePixels {
        let width: Int
        let height: Int
        var rgba: [UInt8]
        var alpha: [UInt8] = []

        init(_ image: CGImage, space: CGColorSpace, alpha hasAlpha: Bool) throws {
            width = image.width
            height = image.height
            let (width, height) = (self.width, self.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw ConversionError.processingFailed(StepKind.resize.displayName) }
            if hasAlpha {
                var plane = [UInt8](repeating: 0, count: width * height)
                pixels.withUnsafeMutableBytes { raw in
                    var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height),
                                               width: vImagePixelCount(width), rowBytes: width * 4)
                    _ = vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
                }
                for index in 0..<(width * height) {
                    plane[index] = pixels[index * 4 + 3]
                    pixels[index * 4 + 3] = 255
                }
                alpha = plane
            }
            rgba = pixels
        }

        func tile(_ column: MLEnlargeTiling.Span, _ row: MLEnlargeTiling.Span) -> RGBA8Tile {
            var pixels = [UInt8](repeating: 0, count: column.length * row.length * 4)
            let rowBytes = column.length * 4
            rgba.withUnsafeBytes { source in
                pixels.withUnsafeMutableBytes { target in
                    for line in 0..<row.length {
                        let from = ((row.start + line) * width + column.start) * 4
                        target.baseAddress?.advanced(by: line * rowBytes)
                            .copyMemory(from: source.baseAddress!.advanced(by: from), byteCount: rowBytes)
                    }
                }
            }
            return RGBA8Tile(width: column.length, height: row.length, pixels: pixels)
        }
    }

    /// The output: RGBA8 rows in a buffer the result image uses without a copy.
    final class OutputPixels {
        let width: Int
        let height: Int
        let data: NSMutableData

        init(width: Int, height: Int) throws {
            self.width = width
            self.height = height
            guard let data = NSMutableData(length: width * height * 4) else {
                throw ConversionError.needsTooMuchMemory(limit: DecodeLimits.standard.maxDecodedBytes)
            }
            self.data = data
        }

        var bytes: UnsafeMutablePointer<UInt8> { data.mutableBytes.assumingMemoryBound(to: UInt8.self) }
    }

    // MARK: Tiles

    private static func enlargedColour(of source: inout SourcePixels, scale: Int, scaler: any SuperResolutionScaler,
                                       tiling: MLEnlargeTiling, space: CGColorSpace) throws -> OutputPixels {
        let columns = tiling.spans(length: source.width)
        let rows = tiling.spans(length: source.height)
        let output = try OutputPixels(width: source.width * scale, height: source.height * scale)
        let session = try scaler.makeSession(width: columns[0].length, height: rows[0].length, colorSpace: space)
        let stripHeight = rows[0].length * scale
        var strip = [UInt8](repeating: 0, count: output.width * stripHeight * 4)
        for row in rows {
            for column in columns {
                try Task.checkCancellation()
                let input = source.tile(column, row)
                var enlarged = try session.upscale(input)
                guard enlarged.width == input.width * scaler.factor, enlarged.height == input.height * scaler.factor,
                      enlarged.pixels.count == enlarged.width * enlarged.height * 4 else {
                    throw ConversionError.processingFailed(StepKind.resize.displayName)
                }
                if scale != scaler.factor {
                    enlarged = try lanczos(enlarged, width: input.width * scale, height: input.height * scale)
                }
                strip.withUnsafeMutableBufferPointer { target in
                    blendColumns(enlarged, into: target.baseAddress!, width: output.width, at: column.start * scale,
                                 feather: column.overlapBefore * scale)
                }
            }
            strip.withUnsafeBufferPointer { rowStrip in
                blendRows(rowStrip.baseAddress!, height: stripHeight, into: output, at: row.start * scale,
                          feather: row.overlapBefore * scale)
            }
        }
        // The colour copy isn't needed any more; the alpha plane still is.
        source.rgba = []
        return output
    }

    /// The weight (out of 256) of the newer tile at `index` of a `feather`-wide overlap: a linear ramp from
    /// just above 0 to just below 256, the same on every side.
    static func featherWeight(_ index: Int, of feather: Int) -> Int {
        ((2 * index + 1) * 256) / (2 * feather)
    }

    /// Mixes `old` and `new` by `weight`/256; equal values stay exactly what they were.
    @inline(__always)
    static func mix(_ old: UInt8, _ new: UInt8, _ weight: Int) -> UInt8 {
        UInt8((Int(old) * (256 - weight) + Int(new) * weight + 128) >> 8)
    }

    /// Puts `tile` into a strip `width` px wide at column `originX`; its first `feather` columns ramp in over what
    /// the tile to its left left there.
    static func blendColumns(_ tile: RGBA8Tile, into strip: UnsafeMutablePointer<UInt8>, width: Int, at originX: Int,
                             feather: Int) {
        let blended = min(feather, tile.width)
        tile.pixels.withUnsafeBufferPointer { source in
            let src = source.baseAddress!
            for line in 0..<tile.height {
                let from = src.advanced(by: line * tile.width * 4)
                let into = strip.advanced(by: (line * width + originX) * 4)
                for column in 0..<blended {
                    let weight = featherWeight(column, of: feather)
                    for channel in 0..<4 {
                        let offset = column * 4 + channel
                        into[offset] = mix(into[offset], from[offset], weight)
                    }
                }
                into.advanced(by: blended * 4).update(from: from.advanced(by: blended * 4),
                                                      count: (tile.width - blended) * 4)
            }
        }
    }

    /// Puts a row strip (`height` rows, the output's width) into `output` at row `originY`; its first `feather`
    /// rows ramp in over the strip above.
    static func blendRows(_ strip: UnsafePointer<UInt8>, height: Int, into output: OutputPixels, at originY: Int,
                          feather: Int) {
        let rowBytes = output.width * 4
        let blended = min(feather, height)
        for line in 0..<blended {
            let weight = featherWeight(line, of: feather)
            let from = strip.advanced(by: line * rowBytes)
            let into = output.bytes.advanced(by: (originY + line) * rowBytes)
            for offset in 0..<rowBytes { into[offset] = mix(into[offset], from[offset], weight) }
        }
        output.bytes.advanced(by: (originY + blended) * rowBytes)
            .update(from: strip.advanced(by: blended * rowBytes), count: (height - blended) * rowBytes)
    }

    /// `tile` scaled to `width` × `height` with vImage's Lanczos (edges extended, so a tile's border isn't darkened).
    static func lanczos(_ tile: RGBA8Tile, width: Int, height: Int) throws -> RGBA8Tile {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var source = tile.pixels
        let error = source.withUnsafeMutableBytes { from in
            pixels.withUnsafeMutableBytes { into in
                var input = vImage_Buffer(data: from.baseAddress, height: vImagePixelCount(tile.height),
                                          width: vImagePixelCount(tile.width), rowBytes: tile.width * 4)
                var output = vImage_Buffer(data: into.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width * 4)
                return vImageScale_ARGB8888(&input, &output, nil,
                                            vImage_Flags(kvImageHighQualityResampling | kvImageEdgeExtend))
            }
        }
        guard error == kvImageNoError else { throw ConversionError.processingFailed(StepKind.resize.displayName) }
        return RGBA8Tile(width: width, height: height, pixels: pixels)
    }

    // MARK: Alpha

    /// Opaque: every alpha byte 255 (the model's own are ignored). With alpha: the source's alpha plane enlarged
    /// with Lanczos, put back and the colour premultiplied by it.
    private static func finishAlpha(_ output: OutputPixels, source: inout SourcePixels, alpha: Bool) throws {
        let count = output.width * output.height
        let bytes = output.bytes
        guard alpha else {
            for index in 0..<count { bytes[index * 4 + 3] = 255 }
            return
        }
        var plane = [UInt8](repeating: 0, count: count)
        let error = source.alpha.withUnsafeMutableBytes { from in
            plane.withUnsafeMutableBytes { into in
                var input = vImage_Buffer(data: from.baseAddress, height: vImagePixelCount(source.height),
                                          width: vImagePixelCount(source.width), rowBytes: source.width)
                var scaled = vImage_Buffer(data: into.baseAddress, height: vImagePixelCount(output.height),
                                           width: vImagePixelCount(output.width), rowBytes: output.width)
                return vImageScale_Planar8(&input, &scaled, nil,
                                           vImage_Flags(kvImageHighQualityResampling | kvImageEdgeExtend))
            }
        }
        guard error == kvImageNoError else { throw ConversionError.processingFailed(StepKind.resize.displayName) }
        source.alpha = []
        for index in 0..<count { bytes[index * 4 + 3] = plane[index] }
        var buffer = vImage_Buffer(data: output.data.mutableBytes, height: vImagePixelCount(output.height),
                                   width: vImagePixelCount(output.width), rowBytes: output.width * 4)
        _ = vImagePremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
    }
}
