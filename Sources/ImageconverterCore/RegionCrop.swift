import CoreGraphics

/// Copies part of an image into a new, small bitmap, so a comparison never has to keep a full-size copy.
public enum RegionCrop {
    /// The pixel rectangle `region` (unit coordinates, origin top left) covers in an image of `width` × `height`,
    /// at least one pixel and inside the image.
    public static func pixelRect(_ region: CGRect, width: Int, height: Int) -> CGRect {
        let unit = region.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let clipped = unit.isNull || unit.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : unit
        let minX = min(max(Int((clipped.minX * CGFloat(width)).rounded(.down)), 0), width - 1)
        let minY = min(max(Int((clipped.minY * CGFloat(height)).rounded(.down)), 0), height - 1)
        let maxX = min(max(Int((clipped.maxX * CGFloat(width)).rounded(.up)), minX + 1), width)
        let maxY = min(max(Int((clipped.maxY * CGFloat(height)).rounded(.up)), minY + 1), height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The size a `pixels` crop is drawn at: unchanged when its longer side is at most `maxSide`, else scaled down.
    public static func targetSize(for pixels: CGSize, maxSide: Int) -> (width: Int, height: Int) {
        let longest = max(pixels.width, pixels.height)
        let scale = longest > CGFloat(maxSide) ? CGFloat(max(maxSide, 1)) / longest : 1
        return (max(1, Int((pixels.width * scale).rounded())), max(1, Int((pixels.height * scale).rounded())))
    }

    /// `region` of `image` in 8-bit sRGB RGBA (transparency kept), at most `maxSide` pixels on the longer side.
    /// Crops that need no scaling are copied pixel for pixel.
    public static func draw(_ image: CGImage, region: CGRect, maxSide: Int) -> CGImage? {
        guard image.width > 0, image.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let pixels = pixelRect(region, width: image.width, height: image.height)
        let target = targetSize(for: pixels.size, maxSide: maxSide)
        guard let context = CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scaleX = CGFloat(target.width) / pixels.width
        let scaleY = CGFloat(target.height) / pixels.height
        context.interpolationQuality = scaleX == 1 && scaleY == 1 ? .none : .high
        // Core Graphics counts y from the bottom: the region's bottom edge goes to y = 0.
        let bottom = CGFloat(image.height) - pixels.maxY
        context.draw(image, in: CGRect(x: -pixels.minX * scaleX, y: -bottom * scaleY,
                                       width: CGFloat(image.width) * scaleX, height: CGFloat(image.height) * scaleY))
        return context.makeImage()
    }
}
