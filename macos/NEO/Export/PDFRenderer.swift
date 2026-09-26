import AppKit
import WebKit

/// HTML → paginated PDF through WebKit's print path, which honours the CSS
/// page breaks the export stylesheet uses. Letter in North America and the
/// Philippines, A4 everywhere else; one-inch margins.
@MainActor
final class PDFRenderer: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?
    private var printed: CheckedContinuation<Bool, Never>?
    private static var active: [PDFRenderer] = []   // kept alive while working

    static func render(html: String) async throws -> Data {
        let r = PDFRenderer()
        active.append(r)
        defer { active.removeAll { $0 === r } }
        return try await r.run(html)
    }

    private func run(_ html: String) async throws -> Data {
        let letter = ["US", "CA", "MX", "PH"].contains(Locale.current.region?.identifier ?? "US")
        let paper = letter ? NSSize(width: 612, height: 792) : NSSize(width: 595.28, height: 841.89)
        let web = WKWebView(frame: NSRect(origin: .zero, size: paper))
        self.web = web
        web.navigationDelegate = self
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            web.loadHTMLString(html, baseURL: nil)
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("neo-\(UUID().uuidString).pdf")
        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: out
        ])
        info.paperSize = paper
        info.topMargin = 72; info.bottomMargin = 72; info.leftMargin = 72; info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let op = web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(origin: .zero, size: paper)

        // WebKit's print operation needs a window to run modally against; an
        // offscreen one keeps the writer's window untouched
        let host = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: paper.width, height: paper.height),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = web
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            printed = c
            op.runModal(for: host, delegate: self,
                         didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        host.contentView = nil
        self.web = nil
        defer { try? FileManager.default.removeItem(at: out) }
        guard ok, let data = try? Data(contentsOf: out), !data.isEmpty else {
            throw Importer.Failure(message: "The PDF could not be rendered")
        }
        return data
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printed?.resume(returning: success)
        printed = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // one more turn so layout settles before printing
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.loaded?.resume()
            self.loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.loaded?.resume(throwing: error)
            self.loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.loaded?.resume(throwing: error)
            self.loaded = nil
        }
    }
}
