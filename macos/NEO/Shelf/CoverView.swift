import SwiftUI
import AppKit

/// The standard NEO cover: a clothbound book with the title set in type.
/// Its colour is chosen from a muted palette by the book's id, so a shelf
/// isn't a row of identical spines. Drawn at any size — the shelf tile and
/// the full-size export cover are the same picture.
struct CoverArt: View {
    let title: String
    let author: String
    let seed: String
    let size: CGSize

    static let cloths: [UInt32] = [0x2F3E46, 0x5B2A2E, 0x2E4A3F, 0x3B3552, 0x1F3A5F, 0x6B4E2E, 0x3A3A3A, 0x4A5A3A]

    static func cloth(for seed: String) -> Color {
        var h: UInt32 = 0x811C_9DC5
        for u in seed.utf8 { h = (h ^ UInt32(u)) &* 0x0100_0193 }
        return Color(hex: cloths[Int(h % UInt32(cloths.count))])
    }

    var body: some View {
        let k = size.width / 104
        let ink = Color(hex: 0xEFE6D2)
        let gold = Color(hex: 0xC9A86A)
        ZStack {
            CoverArt.cloth(for: seed)
            // the spine's shadow and a whisper of light across the board
            LinearGradient(colors: [.black.opacity(0.35), .clear, .white.opacity(0.04), .clear],
                           startPoint: .leading, endPoint: .trailing)
            VStack(spacing: 0) {
                Rectangle().fill(gold.opacity(0.75)).frame(height: 1 * k)
                    .padding(.horizontal, 14 * k).padding(.top, 16 * k)
                Spacer(minLength: 6 * k)
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.custom("Georgia-Bold", size: 15 * k))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .minimumScaleFactor(0.45)
                    .padding(.horizontal, 10 * k)
                Rectangle().fill(gold.opacity(0.75)).frame(width: 18 * k, height: 1 * k)
                    .padding(.top, 8 * k)
                Spacer(minLength: 6 * k)
                Text(author.uppercased())
                    .font(.custom("Georgia", size: 6.5 * k))
                    .tracking(1.4 * k)
                    .foregroundStyle(ink.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 8 * k)
                    .padding(.bottom, 14 * k)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// A book on the shelf: the writer's own image when they gave one, the
/// standard cover otherwise.
struct BookCover: View {
    let meta: BookMeta

    var body: some View {
        let size = CGSize(width: 104, height: 150)
        ZStack {
            if let f = meta.coverImage, let url = LibraryStore.coverURL(meta.id, f),
               let img = CoverImageCache.image(url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height).clipped()
            } else {
                CoverArt(title: meta.title, author: meta.author, seed: meta.id, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Covers are decoded once and downsampled to tile size.
enum CoverImageCache {
    private static var cache: [URL: NSImage] = [:]

    static func forget(_ bookId: String) {
        cache = cache.filter { !$0.key.path.contains("/\(bookId)/") }
    }

    static func image(_ url: URL) -> NSImage? {
        if let i = cache[url] { return i }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[url] = img
        return img
    }
}

/// The cover that travels with an export: the writer's own image if they gave
/// one, otherwise the standard cover rendered at KDP size (1600×2560).
@MainActor
enum ExportCover {
    static func make(bookId: String?, coverImage: String?, title: String, author: String) -> Exporter.Cover {
        if let bookId, let f = coverImage, let url = LibraryStore.coverURL(bookId, f),
           let data = try? Data(contentsOf: url) {
            let ext = url.pathExtension.lowercased()
            if ext == "png" { return Exporter.Cover(data: data, mime: "image/png", ext: "png") }
            if ext == "jpg" || ext == "jpeg" { return Exporter.Cover(data: data, mime: "image/jpeg", ext: "jpg") }
            // anything else is re-encoded, since e-readers only promise JPEG and PNG
            if let img = NSImage(data: data), let jpg = jpeg(img) {
                return Exporter.Cover(data: jpg, mime: "image/jpeg", ext: "jpg")
            }
        }
        let art = CoverArt(title: title, author: author, seed: bookId ?? title, size: CGSize(width: 1600, height: 2560))
        let r = ImageRenderer(content: art)
        r.scale = 1
        if let img = r.nsImage, let jpg = jpeg(img) {
            return Exporter.Cover(data: jpg, mime: "image/jpeg", ext: "jpg")
        }
        return Exporter.Cover(data: Data(), mime: "image/jpeg", ext: "jpg")
    }

    private static func jpeg(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
