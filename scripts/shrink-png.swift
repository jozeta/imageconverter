// Shrinks a README screenshot in place with Apple frameworks only (Core Graphics, ImageIO):
// swift scripts/shrink-png.swift <file.png>
// Scales it to at most 1300 px wide (the window's size in points), then drops the lowest bits of each colour channel
// (8, 6, 5, 4 bits kept) until the PNG is 400 KB or less. Flat UI colours compress much better with fewer distinct
// values; the result is still a full-colour PNG (ImageIO writes no palette PNGs), so it may stay a little larger
// than a palette-reduced one. Exit 1 when the file can't be read or written.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let limit = 400 * 1024
let maxWidth = 1300

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("shrink-png.swift: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: shrink-png.swift <file.png>") }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(url.path)") }

let width = min(original.width, maxWidth)
let height = Int((Double(original.height) * Double(width) / Double(original.width)).rounded())
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let pixels = context.data else { fail("can't allocate \(width)x\(height)") }
context.interpolationQuality = .high
context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
let bytes = pixels.bindMemory(to: UInt8.self, capacity: width * height * 4)
let scaled = Data(bytes: bytes, count: width * height * 4)

func encode(keepingBits bits: Int) -> Data? {
    var copy = scaled
    let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
    // Rounds to the middle of each kept step, so dark and light areas don't shift.
    let half = bits < 8 ? UInt8(1 << (7 - bits)) : 0
    copy.withUnsafeMutableBytes { buffer in
        for index in stride(from: 0, to: buffer.count, by: 4) {
            for channel in 0..<3 { buffer[index + channel] = (buffer[index + channel] & mask) | half }
        }
    }
    guard let provider = CGDataProvider(data: copy as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
}

var best: Data?
for bits in [8, 6, 5, 4] {
    guard let data = encode(keepingBits: bits) else { fail("can't encode \(url.path)") }
    best = data
    if data.count <= limit { break }
}
do {
    try best!.write(to: url, options: .atomic)
} catch {
    fail("can't write \(url.path): \(error.localizedDescription)")
}
