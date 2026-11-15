import Foundation

/// A minimal zip writer for tests that need a zip lying about itself: each file entry is raw DEFLATE (Foundation's
/// `.zlib` is RFC 1951 without a header), and its declared uncompressed size can be set to anything.
enum TestZip {
    struct Entry {
        var name: String
        var data: Data = Data()
        /// The size written into the headers; nil = the real size.
        var declaredSize: UInt32?
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        var archive = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt32(archive.count)
            let name = Data(entry.name.utf8)
            let compressed = entry.isDirectory ? Data() : try (entry.data as NSData).compressed(using: .zlib) as Data
            let method: UInt16 = entry.isDirectory ? 0 : 8
            let crc = entry.isDirectory ? 0 : crc32(entry.data)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            archive += le32(0x0403_4b50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0x5A21)
            archive += le32(crc) + le32(UInt32(compressed.count)) + le32(size) + le16(UInt16(name.count)) + le16(0)
            archive += name + compressed
            let mode: UInt32 = entry.isDirectory ? 0o40755 : 0o100644
            central += le32(0x0201_4b50) + le16(0x031E) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0x5A21)
            central += le32(crc) + le32(UInt32(compressed.count)) + le32(size) + le16(UInt16(name.count))
            central += le16(0) + le16(0) + le16(0) + le16(0) + le32(mode << 16 | (entry.isDirectory ? 0x10 : 0)) + le32(offset)
            central += name
        }
        let centralOffset = UInt32(archive.count)
        archive += central
        archive += le32(0x0605_4b50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        archive += le32(UInt32(central.count)) + le32(centralOffset) + le16(0)
        try archive.write(to: url)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
