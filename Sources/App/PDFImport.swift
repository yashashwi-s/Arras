import AppKit
import PDFKit

/// Displays one page of a PDF as a widget, via PDFKit. A page is rasterized
/// once at import time and stored like any other still image -- the widget
/// itself has no notion of PDFs after that.
extension PhotoManager {
    /// Number of pages in the PDF at `url`, or 0 if it can't be opened. Callers
    /// use this to decide whether a page picker is needed at all -- most PDFs
    /// pinned as reference material are a single page.
    func pdfPageCount(at url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// Renders `pageIndex` (zero-based) of the PDF at `url` and adds it as a
    /// new widget.
    /// - Returns: true if a widget was created.
    @discardableResult
    func addPDFPage(at url: URL, pageIndex: Int) -> Bool {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex),
              let image = Self.renderPDFPage(page) else { return false }
        addPhoto(image)
        return true
    }

    /// Rasterizes at 2x the page's point size so the widget stays crisp if the
    /// user enlarges it, capped so a poster-sized page doesn't produce a
    /// 100MP image that then has to be re-encoded to JPEG on save.
    private static let maxPixelArea: CGFloat = 8_000_000  // ~8MP; comfortably above any on-screen widget size

    private static func renderPDFPage(_ page: PDFPage) -> NSImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        var scale: CGFloat = 2
        let pixelArea = bounds.width * scale * bounds.height * scale
        if pixelArea > maxPixelArea {
            scale = sqrt(maxPixelArea / (bounds.width * bounds.height))
        }

        let pixelSize = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = NSImage(size: pixelSize)
        image.lockFocus()
        // PDF content doesn't necessarily cover its own media box (transparent
        // margins are common), and a widget with a transparent hole where paper
        // should be looks broken -- give it a page-white backdrop first.
        NSColor.white.setFill()
        NSRect(origin: .zero, size: pixelSize).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        image.unlockFocus()
        return image
    }
}
