import Foundation

/// A minimal zip writer for tests that need a zip lying about itself: each file entry is raw DEFLATE (Foundation's
/// `.zlib` is RFC 1951 without a header), and its declared uncompressed size can be set to anything.
enum TestZip {
    struct Entry {
        var name: String
        var data: Data = Data()
        /// The size written into the headers; nil = the real size.
        var declaredSize: UInt32?
        /// The name in the local header (what ditto writes); nil = `name`, which the central directory (what
        /// zipinfo lists) always has.
        var localName: String?
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        var archive = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt32(archive.count)
            let name = Data(entry.name.utf8)
            let local = Data((entry.localName ?? entry.name).utf8)
            let compressed = entry.isDirectory ? Data() : try (entry.data as NSData).compressed(using: .zlib) as Data
            let method: UInt16 = entry.isDirectory ? 0 : 8
            let crc = entry.isDirectory ? 0 : crc32(entry.data)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            archive += le32(0x0403_4b50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0x5A21)
            archive += le32(crc) + le32(UInt32(compressed.count)) + le32(size) + le16(UInt16(local.count)) + le16(0)
            archive += local + compressed
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

    /// Rewrites the declared uncompressed size of entry `name` (central directory, local header and, when the entry
    /// has one, its data descriptor) in a zip without a comment, such as one `ditto -c -k` made.
    static func patchDeclaredSize(of name: String, in url: URL, to size: UInt32) throws {
        var data = try Data(contentsOf: url)
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        func put32(_ value: UInt32, _ offset: Int) { data.replaceSubrange(offset..<offset + 4, with: le32(value)) }
        let end = data.count - 22
        guard u32(end) == 0x0605_4b50 else { throw CocoaError(.fileReadCorruptFile) }
        var entry = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            let nameLength = u16(entry + 28), extra = u16(entry + 30), comment = u16(entry + 32)
            let entryName = String(bytes: data[(entry + 46)..<(entry + 46 + nameLength)], encoding: .utf8) ?? ""
            if entryName == name {
                let flags = u16(entry + 8), compressed = u32(entry + 20), local = u32(entry + 42)
                put32(size, entry + 24)
                let dataStart = local + 30 + u16(local + 26) + u16(local + 28)
                if flags & 0x8 != 0 {
                    var descriptor = dataStart + compressed
                    if u32(descriptor) == 0x0807_4b50 { descriptor += 4 }
                    put32(size, descriptor + 8)
                } else {
                    put32(size, local + 22)
                }
                try data.write(to: url)
                return
            }
            entry += 46 + nameLength + extra + comment
        }
        throw CocoaError(.fileNoSuchFile)
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
