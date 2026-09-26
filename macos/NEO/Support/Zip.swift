import Foundation
import Compression

// Just enough zip for NEO: writing EPUB/DOCX exports and daily backups, and
// reading word/document.xml out of an imported .docx. Apple's Compression
// framework speaks raw DEFLATE (its "zlib" mode), which is what zip stores.

private let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        for b in buf { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    }
    return c ^ 0xFFFF_FFFF
}

private func deflate(_ data: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    let cap = data.count + data.count / 8 + 1024
    var out = Data(count: cap)
    let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
    }
    guard n > 0, n < data.count else { return nil }
    return out.prefix(n)
}

private func inflate(_ data: Data, size: Int) -> Data? {
    if size == 0 { return Data() }
    var out = Data(count: size)
    let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
    }
    return n == size ? out : nil
}

private extension Data {
    mutating func le16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    func u16(_ at: Int) -> Int { Int(self[startIndex + at]) | Int(self[startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
}

final class ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count = 0
    private let dosTime: Int
    private let dosDate: Int

    init() {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        dosTime = (c.hour! << 11) | (c.minute! << 5) | (c.second! / 2)
        dosDate = ((max(c.year!, 1980) - 1980) << 9) | (c.month! << 5) | c.day!
    }

    /// `store` keeps an entry uncompressed (the EPUB mimetype must be).
    func add(_ path: String, data: Data, store: Bool = false) {
        let name = Data(path.utf8)
        let packed = store ? nil : deflate(data)
        let method = packed == nil ? 0 : 8
        let payload = packed ?? data
        let crc = crc32(data)
        let offset = UInt32(body.count)

        body.le32(0x0403_4B50)
        body.le16(20); body.le16(0x0800); body.le16(method)
        body.le16(dosTime); body.le16(dosDate)
        body.le32(crc); body.le32(UInt32(payload.count)); body.le32(UInt32(data.count))
        body.le16(name.count); body.le16(0)
        body.append(name)
        body.append(payload)

        central.le32(0x0201_4B50)
        central.le16(20); central.le16(20); central.le16(0x0800); central.le16(method)
        central.le16(dosTime); central.le16(dosDate)
        central.le32(crc); central.le32(UInt32(payload.count)); central.le32(UInt32(data.count))
        central.le16(name.count); central.le16(0); central.le16(0)
        central.le16(0); central.le16(0); central.le32(0)
        central.le32(offset)
        central.append(name)
        count += 1
    }

    func add(_ path: String, text: String, store: Bool = false) {
        add(path, data: Data(text.utf8), store: store)
    }

    func finish() -> Data {
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4B50)
        out.le16(0); out.le16(0)
        out.le16(count); out.le16(count)
        out.le32(UInt32(central.count)); out.le32(cdOffset)
        out.le16(0)
        return out
    }
}

struct ZipReader {
    struct Entry { let name: String; let method: Int; let csize: Int; let usize: Int; let offset: Int }

    let data: Data
    let entries: [Entry]

    init?(_ data: Data) {
        self.data = data
        // end-of-central-directory record, searched for from the tail
        guard data.count >= 22 else { return nil }
        var eocd = -1
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while i >= floor {
            if data.u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let total = data.u16(eocd + 10)
        var p = data.u32(eocd + 16)
        var list: [Entry] = []
        for _ in 0..<total {
            guard p + 46 <= data.count, data.u32(p) == 0x0201_4B50 else { return nil }
            let n = data.u16(p + 28), e = data.u16(p + 30), c = data.u16(p + 32)
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + n))
            list.append(Entry(name: String(decoding: nameData, as: UTF8.self),
                              method: data.u16(p + 10), csize: data.u32(p + 20),
                              usize: data.u32(p + 24), offset: data.u32(p + 42)))
            p += 46 + n + e + c
        }
        entries = list
    }

    func read(_ name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        let h = e.offset
        guard h + 30 <= data.count, data.u32(h) == 0x0403_4B50 else { return nil }
        let start = h + 30 + data.u16(h + 26) + data.u16(h + 28)
        guard start + e.csize <= data.count else { return nil }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.csize))
        switch e.method {
        case 0: return raw
        case 8: return inflate(raw, size: e.usize)
        default: return nil
        }
    }
}
