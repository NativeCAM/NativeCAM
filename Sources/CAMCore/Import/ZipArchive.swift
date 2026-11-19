import Compression
import Foundation

/// A minimal read-only ZIP reader (central directory, ZIP64, "stored" and "deflate" entries) for 3MF and USDZ packages.
struct ZipArchive {
    struct Entry: Sendable {
        var name: String
        var method: UInt16
        var flags: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
    }

    enum ZipError: Error, LocalizedError {
        case notAZip
        case damaged(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: "the file is not a ZIP archive"
            case let .damaged(d): "the ZIP archive is damaged (\(d))"
            case let .unsupported(d): "the ZIP archive uses an unsupported feature (\(d))"
            }
        }
    }

    /// Largest entry we are willing to inflate into memory.
    static let maxEntrySize: UInt64 = 4 << 30

    let data: Data
    let entries: [Entry]

    init(data: Data) throws {
        self.data = data
        self.entries = try data.withUnsafeBytes { try ZipArchive.readCentralDirectory($0) }
    }

    /// The entry with this exact name, else the one matching case-insensitively (ignoring a leading "/").
    func entry(named name: String) -> Entry? {
        let wanted = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if let e = entries.first(where: { $0.name == wanted }) { return e }
        let lower = wanted.lowercased()
        return entries.first { $0.name.lowercased() == lower }
    }

    func extract(_ entry: Entry) throws -> Data {
        guard entry.flags & 1 == 0 else { throw ZipError.unsupported("“\(entry.name)” is encrypted") }
        guard entry.uncompressedSize <= ZipArchive.maxEntrySize, entry.compressedSize <= UInt64(data.count) else {
            throw ZipError.damaged("“\(entry.name)” is too large")
        }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard entry.localHeaderOffset < UInt64(raw.count) else {
                throw ZipError.damaged("bad local header offset for “\(entry.name)”")
            }
            let local = Int(entry.localHeaderOffset)
            guard local + 30 <= raw.count, ZipArchive.u32(raw, local) == 0x0403_4B50 else {
                throw ZipError.damaged("bad local header for “\(entry.name)”")
            }
            let start = local + 30 + Int(ZipArchive.u16(raw, local + 26)) + Int(ZipArchive.u16(raw, local + 28))
            let size = Int(entry.compressedSize)
            guard start + size <= raw.count else { throw ZipError.damaged("“\(entry.name)” is truncated") }
            let src = raw.baseAddress! + start
            switch entry.method {
            case 0:
                return Data(bytes: src, count: size)
            case 8:
                let outSize = Int(entry.uncompressedSize)
                if outSize == 0 { return Data() }
                // One spare byte detects a declared size that is too small.
                var out = Data(count: outSize + 1)
                let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, outSize + 1,
                                              src.assumingMemoryBound(to: UInt8.self), size, nil, COMPRESSION_ZLIB)
                }
                guard written == outSize else {
                    throw ZipError.damaged("“\(entry.name)” did not inflate to its declared size (\(written) of \(outSize) bytes)")
                }
                out.removeLast()
                return out
            default:
                throw ZipError.unsupported("compression method \(entry.method) for “\(entry.name)”")
            }
        }
    }

    func extract(named name: String) throws -> Data? {
        guard let e = entry(named: name) else { return nil }
        return try extract(e)
    }

    // MARK: Parsing

    @inline(__always) static func u16(_ r: UnsafeRawBufferPointer, _ o: Int) -> UInt16 {
        UInt16(littleEndian: r.loadUnaligned(fromByteOffset: o, as: UInt16.self))
    }

    @inline(__always) static func u32(_ r: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
        UInt32(littleEndian: r.loadUnaligned(fromByteOffset: o, as: UInt32.self))
    }

    @inline(__always) static func u64(_ r: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
        UInt64(littleEndian: r.loadUnaligned(fromByteOffset: o, as: UInt64.self))
    }

    private static func readCentralDirectory(_ r: UnsafeRawBufferPointer) throws -> [Entry] {
        let n = r.count
        guard n >= 22 else { throw ZipError.notAZip }
        // End of central directory: last 22 bytes plus a comment of up to 65535 bytes.
        var eocd = -1
        var i = n - 22
        let lowest = max(0, n - 22 - 0xFFFF)
        while i >= lowest {
            if u32(r, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        var count = UInt64(u16(r, eocd + 10))
        var cdSize = UInt64(u32(r, eocd + 12))
        var cdOffset = UInt64(u32(r, eocd + 16))

        // ZIP64 end-of-central-directory locator sits just before the EOCD.
        if eocd >= 20, u32(r, eocd - 20) == 0x0706_4B50 {
            let z = u64(r, eocd - 20 + 8)
            if n >= 56, z <= UInt64(n - 56), u32(r, Int(z)) == 0x0606_4B50 {
                count = u64(r, Int(z) + 32)
                cdSize = u64(r, Int(z) + 40)
                cdOffset = u64(r, Int(z) + 48)
            }
        }
        guard cdOffset <= UInt64(n), cdSize <= UInt64(n) - cdOffset else {
            throw ZipError.damaged("central directory is out of range")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(count, 100_000)))
        var p = Int(cdOffset)
        let cdEnd = Int(cdOffset + cdSize)
        while p + 46 <= cdEnd, u32(r, p) == 0x0201_4B50 {
            let flags = u16(r, p + 8)
            let method = u16(r, p + 10)
            var compressed = UInt64(u32(r, p + 20))
            var uncompressed = UInt64(u32(r, p + 24))
            let nameLen = Int(u16(r, p + 28))
            let extraLen = Int(u16(r, p + 30))
            let commentLen = Int(u16(r, p + 32))
            var offset = UInt64(u32(r, p + 42))
            let nameStart = p + 46
            guard nameStart + nameLen + extraLen + commentLen <= cdEnd else {
                throw ZipError.damaged("central directory entry overruns")
            }
            let nameBytes = UnsafeRawBufferPointer(rebasing: r[nameStart..<(nameStart + nameLen)])
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""

            // ZIP64 extended information: present fields replace the 0xFFFFFFFF placeholders, in order.
            var e = nameStart + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let tag = u16(r, e), len = Int(u16(r, e + 2))
                let body = e + 4
                if tag == 0x0001 {
                    var q = body
                    if uncompressed == 0xFFFF_FFFF && q + 8 <= body + len { uncompressed = u64(r, q); q += 8 }
                    if compressed == 0xFFFF_FFFF && q + 8 <= body + len { compressed = u64(r, q); q += 8 }
                    if offset == 0xFFFF_FFFF && q + 8 <= body + len { offset = u64(r, q); q += 8 }
                }
                e = body + len
            }
            entries.append(Entry(name: name, method: method, flags: flags, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: offset))
            p = extraEnd + commentLen
        }
        guard !entries.isEmpty || count == 0 else { throw ZipError.damaged("no central directory entries") }
        return entries
    }
}
