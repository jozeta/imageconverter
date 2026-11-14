import Foundation
import ImageIO

extension ImageLoader {
    /// The upright pixel size of encoded data's first frame, from the header only. Nil if unreadable.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateWithData(data as CFData, options).flatMap(ImageHeader.read)?.uprightSize
    }
}
