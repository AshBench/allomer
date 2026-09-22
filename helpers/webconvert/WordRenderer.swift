import AppKit
import CoreGraphics
import Foundation
import PDFKit
import WebKit

/// Print a Word document at its own declared page size, and repeat its header and footer on
/// every page. The document's geometry arrives from the adapter, which read it from `w:sectPr`.
final class WordRenderer: NSObject, WKNavigationDelegate, WKURLSchemeHandler, WKScriptMessageHandler {
    struct Geometry {
        let width: Double, height: Double
        let top: Double, right: Double, bottom: Double, left: Double
        let header: Double, footer: Double
        var printableWidth: Double { width - left - right }
        /// CSS pixels across the printable area. A CSS pixel is a 96th of an inch.
        var cssWidth: Double { printableWidth * 96 / 72 }

        /// Whether the adapter found a header and a footer the document expects to see printed.
        let expectsHeader: Bool, expectsFooter: Bool

        /// Eight point values then two flags, comma separated, as the adapter writes them.
        init?(_ text: String) {
            let values = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
            guard values.count == 10, values.allSatisfy({ $0?.isFinite == true }) else { return nil }
            let v = values.map { $0! }
            expectsHeader = v[8] == 1
            expectsFooter = v[9] == 1
            (width, height) = (v[0], v[1])
            (top, right, bottom, left) = (v[2], v[3], v[4], v[5])
            (header, footer) = (v[6], v[7])
            guard [width, height].allSatisfy({ $0 >= 36 && $0 <= 14_400 }),
                  [top, right, bottom, left, header, footer].allSatisfy({ $0 >= 0 && $0 <= 14_400 }),
                  printableWidth >= 36, height - top - bottom >= 36 else { return nil }
        }
    }

    // The printer owns the paper box, so docx-preview's own page box is stripped. Without the
    // break rule an explicit page break yields a second section that shares a page with the first.
    private static let overrideStyle = """
        /* renderAsync empties the style container, so the page reset is restated here. */
        html, body { margin: 0 !important; padding: 0 !important; background: white }
        section.docx { display: block !important; width: auto !important; min-height: 0 !important;
                       padding: 0 !important; margin: 0 !important; overflow: visible !important }
        section.docx + section.docx { break-before: page !important; page-break-before: always !important }
        section.docx > header, section.docx > footer { display: none !important }
        /* Word counts a cell's padding and borders inside its declared width. CSS does not. */
        section.docx td, section.docx th { box-sizing: border-box }
        """

    /// WebKit writes a printed CSS pixel as a 90th of an inch rather than a 96th, so a page
    /// printed at its declared size comes out this much too large. The paper handed to the
    /// printer is enlarged by the same factor and the result is scaled back when composing,
    /// which keeps line breaking at the document's real printable width.
    private static let printScale = 96.0 / 90.0
    /// `createPDF` writes a CSS pixel as one point instead.
    private static let captureScale = 72.0 / 96.0

    let input: URL, output: URL, work: URL
    let geometry: Geometry
    let stamp: FileStamp
    private let script: String
    let address = URL(string: "local-word://source/")!
    var view: WKWebView!
    var done = false
    var error: Error?
    private let body: URL
    private var header: Data?
    private var footer: Data?
    private var printOperation: NSPrintOperation?
    private var printWindow: NSWindow?

    init(input: URL, root: URL, output: URL, geometry: Geometry) throws {
        self.input = input.resolvingSymlinksInPath()
        self.output = output.absoluteURL
        work = output.deletingLastPathComponent()
        body = work.appendingPathComponent("word-body-\(UUID().uuidString).pdf")
        self.geometry = geometry
        stamp = try FileStamp(self.input)
        let library = root.resolvingSymlinksInPath().appendingPathComponent("renderer.js")
        guard stamp.size > 0, stamp.size <= 64 * 1024 * 1024,
              try FileStamp(library).size <= 8 * 1024 * 1024,
              let text = String(data: try readResource(library), encoding: .utf8) else {
            throw Failure.message("The document or its renderer exceeds its size limit.")
        }
        script = text
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.shouldPrintBackgrounds = true
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(self, forURLScheme: address.scheme!)
        config.userContentController.add(self, contentWorld: .defaultClient, name: "blocked")
        let setup = """
            const failed = reason => {
                window.renderFailure = true;
                window.webkit.messageHandlers.blocked.postMessage(typeof reason === 'string' ? reason.slice(0, 1000) : 'A resource was blocked or unreadable.');
            };
            document.addEventListener('securitypolicyviolation', failed);
            document.addEventListener('error', event => {
                if (['image', 'img', 'use', 'link'].includes(event.target.localName)) failed();
            }, true);
            console.warn = console.error = failed;
            """
        config.userContentController.addUserScript(WKUserScript(source: setup + script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: geometry.cssWidth, height: geometry.height),
                         configuration: config)
        view.navigationDelegate = self
    }

    func start() { view.load(URLRequest(url: address)) }

    private func fail(_ error: Error) {
        if self.error == nil { self.error = error }
        done = true
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == address.scheme, url.host == address.host,
                  url.query == nil else {
                throw Failure.message("The document requested an unsupported resource.")
            }
            let data: Data
            switch url.path {
            case "/":
                data = Data("<!DOCTYPE html><meta charset=\"utf-8\"><style>html,body{margin:0;padding:0;background:white}</style><body></body>".utf8)
            case "/input.docx":
                guard try FileStamp(input) == stamp else { throw Failure.message("The document changed during conversion.") }
                data = try readResource(input)
            default:
                throw Failure.message("The document requested an unknown part.")
            }
            let policy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data: blob:; connect-src local-word:; base-uri 'none'; form-action 'none'"
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": url.path == "/" ? "text/html; charset=utf-8" : "application/octet-stream",
                "Content-Security-Policy": policy, "Content-Length": String(data.count), "Cache-Control": "no-store"])!)
            task.didReceive(data)
            task.didFinish()
        } catch { task.didFailWithError(error); fail(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let detail = (message.body as? String).map { String($0.prefix(1000)) } ?? "A resource was blocked or unreadable."
        fail(Failure.message("The document could not be rendered. \(detail)"))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == address && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(Failure.message("The document renderer stopped before completion.")) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        view.callAsyncJavaScript("""
            const bytes = await (await fetch('local-word://source/input.docx')).arrayBuffer();
            await DOCX.renderAsync(new Blob([bytes]), document.body, document.head, {
                className: 'docx', inWrapper: false, breakPages: true, ignoreLastRenderedPageBreak: true,
                renderHeaders: true, renderFooters: true, renderFootnotes: true, renderEndnotes: true,
                renderChanges: false, renderComments: false, renderAltChunks: false,
                useBase64URL: true, experimental: false, debug: false
            });
            const sheet = document.createElement('style');
            sheet.textContent = style;
            document.head.appendChild(sheet);
            const sections = Array.from(document.querySelectorAll('section.docx'));
            if (!sections.length) throw new Error('The document produced no pages.');
            if (document.getElementsByTagName('*').length > 100000) throw new Error('The document exceeds 100,000 elements.');
            const collect = name => {
                const bodies = new Set();
                for (const section of sections) {
                    for (const node of section.querySelectorAll(':scope > ' + name)) {
                        const markup = node.innerHTML.trim();
                        // A running block can hold a picture, a rule or a table and no text at all.
                        if (markup && (node.textContent.trim() || node.querySelector('img, svg, table, hr'))) {
                            bodies.add(markup);
                        }
                    }
                }
                return Array.from(bodies);
            };
            window.wordRunning = {header: collect('header'), footer: collect('footer')};
            if (wordRunning.header.length > 1) throw new Error('This document uses more than one header. Converting it would repeat the wrong one on some pages.');
            if (wordRunning.footer.length > 1) throw new Error('This document uses more than one footer. Converting it would repeat the wrong one on some pages.');
            for (const [name, wanted] of [['header', expectsHeader], ['footer', expectsFooter]]) {
                if (wanted && !wordRunning[name].length) {
                    throw new Error('This document has a ' + name + ' this conversion cannot draw, so it would be missing from every page.');
                }
            }
            await Promise.all(Array.from(document.images).map(image => image.decode().catch(() => { throw new Error('A document image could not be decoded.'); })));
            await document.fonts.ready;
            if (Array.from(document.fonts).some(font => font.status === 'error')) throw new Error('A document font could not be loaded.');
            for (const animation of document.getAnimations()) { animation.pause(); animation.currentTime = 0; }
            if (window.renderFailure) throw new Error('A document resource failed to render.');
            return {sections: sections.length, header: wordRunning.header.length, footer: wordRunning.footer.length};
            """, arguments: ["style": WordRenderer.overrideStyle, "expectsHeader": geometry.expectsHeader,
                              "expectsFooter": geometry.expectsFooter], in: nil, in: .defaultClient) { result in
            do {
                _ = try WordRenderer.value(result)
                if let error = self.error { throw error }
                self.renderRunning(name: "header")
            } catch { self.fail(error) }
        }
    }

    /// The printed height of a running block, in points.
    private func runningHeight(_ data: Data?) throws -> Double {
        guard let page = try onePage(data) else { return 0 }
        return page.getBoxRect(.mediaBox).height * WordRenderer.captureScale
    }

    private func printBody() throws {
        let scale = WordRenderer.printScale
        // Word reserves whatever a running block needs, so the body starts below the header and
        // ends above the footer even when either is taller than its declared distance.
        let top = max(geometry.top, geometry.header + (try runningHeight(header)))
        let bottom = max(geometry.bottom, geometry.footer + (try runningHeight(footer)))
        guard geometry.height - top - bottom >= 36 else {
            throw Failure.message("This document's header and footer leave no room for its body text on the page size it declares.")
        }
        let info = NSPrintInfo(dictionary: [:])
        info.paperSize = CGSize(width: geometry.width * scale, height: geometry.height * scale)
        info.topMargin = top * scale; info.bottomMargin = bottom * scale
        info.leftMargin = geometry.left * scale; info.rightMargin = geometry.right * scale
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = body
        info.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
        info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 1
        info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 10_001
        let operation = view.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit waits for pagination on its print worker while the main run loop receives the result.
        operation.canSpawnSeparateThread = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: geometry.width * scale, height: geometry.height * scale),
                              styleMask: [], backing: .buffered, defer: true)
        printWindow = window
        printOperation = operation
        operation.runModal(for: window, delegate: self, didRun: #selector(printed(_:success:context:)), contextInfo: nil)
    }

    @objc private func printed(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        printOperation = nil
        printWindow = nil
        // The print worker delivers this callback on its own thread. WebKit is main-thread only.
        DispatchQueue.main.async {
            do {
                guard success, try FileStamp(self.body).size > 0 else {
                    throw Failure.message("The document print operation failed.")
                }
                try self.compose()
                guard try FileStamp(self.input) == self.stamp else {
                    throw Failure.message("The document changed during conversion.")
                }
                self.done = true
            } catch { self.fail(error) }
        }
    }

    /// Draw one running block on its own single page, at the printable width and its own height.
    private func renderRunning(name: String) {
        view.callAsyncJavaScript("""
            const markup = wordRunning[name];
            if (!window.wordBody) window.wordBody = Array.from(document.body.childNodes);
            if (!markup.length) return 0;
            const section = document.createElement('section');
            section.className = 'docx';
            section.setAttribute('style', 'display:block;width:' + width + 'px;min-height:0;padding:0;margin:0;overflow:visible');
            const block = document.createElement(name);
            block.setAttribute('style', 'display:block !important');
            block.innerHTML = markup[0];
            section.appendChild(block);
            document.body.replaceChildren(section);
            await new Promise(resolve => setTimeout(resolve, 0));
            const height = Math.ceil(section.getBoundingClientRect().height);
            if (!(height > 0) || height > 4096) throw new Error('A running ' + name + ' has an unusable height.');
            return height;
            """, arguments: ["name": name, "width": geometry.cssWidth], in: nil, in: .defaultClient) { result in
            do {
                if let error = self.error { throw error }
                guard let height = try WordRenderer.value(result) as? Double, height.isFinite, height >= 0 else {
                    throw Failure.message("A running block could not be measured.")
                }
                guard height > 0 else { try self.advance(name: name, data: nil); return }
                self.view.setFrameSize(CGSize(width: self.geometry.cssWidth, height: height))
                let config = WKPDFConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: self.geometry.cssWidth, height: height)
                config.allowTransparentBackground = true
                self.view.createPDF(configuration: config) { result in
                    do { try self.advance(name: name, data: result.get()) } catch { self.fail(error) }
                }
            } catch { self.fail(error) }
        }
    }

    private func advance(name: String, data: Data?) throws {
        if let error { throw error }
        if let data {
            guard data.count <= 64 * 1024 * 1024 else { throw Failure.message("A running block PDF is too large.") }
            if name == "header" { header = data } else { footer = data }
        }
        if name == "header" { renderRunning(name: "footer"); return }
        restoreBody()
    }

    /// The fragments replaced the page, so the document is put back before it is printed.
    private func restoreBody() {
        view.setFrameSize(CGSize(width: geometry.cssWidth, height: geometry.height))
        view.callAsyncJavaScript("""
            if (window.wordBody) document.body.replaceChildren(...window.wordBody);
            await new Promise(resolve => setTimeout(resolve, 0));
            if (!document.querySelector('section.docx')) throw new Error('The document could not be restored for printing.');
            """, arguments: [:], in: nil, in: .defaultClient) { result in
            do {
                _ = try WordRenderer.value(result)
                if let error = self.error { throw error }
                try self.printBody()
            } catch { self.fail(error) }
        }
    }

    /// One link the printer put on a page. Drawing page content does not carry annotations, so
    /// every link is read back and written again onto the composed page.
    private struct Link {
        let page: Int
        let rect: CGRect
        let url: URL?
        let destination: (page: Int, point: CGPoint)?
    }

    /// The links a running block carries, in its own fragment coordinates.
    private func runningLinks(_ data: Data?) throws -> [(rect: CGRect, url: URL)] {
        guard let data, let document = PDFDocument(data: data), let page = document.page(at: 0) else { return [] }
        return page.annotations.filter { $0.type == "Link" }.compactMap { annotation in
            guard let action = annotation.action as? PDFActionURL, let url = action.url,
                  ["http", "https", "mailto"].contains(url.scheme ?? "") else { return nil }
            return (annotation.bounds, url)
        }
    }

    private func links(in file: URL) throws -> [Link] {
        guard let document = PDFDocument(url: file) else { return [] }
        var links: [Link] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Link" {
                guard links.count < 10_000 else { throw Failure.message("The document has more than 10,000 links.") }
                if let action = annotation.action as? PDFActionURL, let url = action.url,
                   ["http", "https", "mailto"].contains(url.scheme ?? "") {
                    links.append(Link(page: index, rect: annotation.bounds, url: url, destination: nil))
                } else if let action = annotation.action as? PDFActionGoTo,
                          let target = action.destination.page.flatMap({ document.index(for: $0) }),
                          (0..<document.pageCount).contains(target) {
                    links.append(Link(page: index, rect: annotation.bounds, url: nil,
                        destination: (target, action.destination.point)))
                }
            }
        }
        return links
    }

    private func onePage(_ data: Data?) throws -> CGPDFPage? {
        guard let data else { return nil }
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              document.numberOfPages == 1, let page = document.page(at: 1), page.rotationAngle == 0 else {
            throw Failure.message("A running block did not render to one readable page.")
        }
        return page
    }

    /// Where a link inside a running block lands once that block has been stamped onto the page.
    private func stamped(_ rect: CGRect, area: CGRect, capture: Double, y: Double) -> CGRect {
        CGRect(x: geometry.left + (rect.minX - area.minX) * capture,
               y: y + (rect.minY - area.minY) * capture,
               width: rect.width * capture, height: rect.height * capture)
    }

    /// Stamp the running blocks onto every printed page. No CSS mechanism in this engine repeats a
    /// block across printed pages, so the pages are composed after the body is paginated.
    private func compose() throws {
        guard let provider = CGDataProvider(url: body as CFURL), let printed = CGPDFDocument(provider),
              (1...10_000).contains(printed.numberOfPages) else {
            throw Failure.message("The printed document is unreadable or exceeds 10,000 pages.")
        }
        let headerPage = try onePage(header), footerPage = try onePage(footer)
        let links = try links(in: body)
        let headerLinks = try runningLinks(header), footerLinks = try runningLinks(footer)
        var box = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        guard let writer = CGContext(output as CFURL, mediaBox: &box, nil) else {
            throw Failure.message("The document PDF could not be opened.")
        }
        // A page that fails part way through must not leave a half-written PDF behind.
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        for index in 0..<printed.numberOfPages {
            try autoreleasepool {
                guard let page = printed.page(at: index + 1) else { throw Failure.message("A printed page is unreadable.") }
                let source = page.getBoxRect(.mediaBox)
                guard page.rotationAngle == 0, source.width > 0, source.height > 0,
                      abs(source.width - geometry.width * WordRenderer.printScale) <= 1,
                      abs(source.height - geometry.height * WordRenderer.printScale) <= 1 else {
                    throw Failure.message("A printed page has an unexpected paper size.")
                }
                let back = (x: geometry.width / source.width, y: geometry.height / source.height)
                writer.beginPDFPage(nil)
                writer.saveGState()
                writer.scaleBy(x: back.x, y: back.y)
                writer.translateBy(x: -source.minX, y: -source.minY)
                writer.drawPDFPage(page)
                writer.restoreGState()
                let capture = WordRenderer.captureScale
                if let headerPage {
                    let area = headerPage.getBoxRect(.mediaBox)
                    writer.saveGState()
                    writer.translateBy(x: geometry.left,
                                       y: geometry.height - geometry.header - area.height * capture)
                    writer.scaleBy(x: capture, y: capture)
                    writer.translateBy(x: -area.minX, y: -area.minY)
                    writer.drawPDFPage(headerPage)
                    writer.restoreGState()
                    for link in headerLinks {
                        writer.setURL(link.url as CFURL, for: stamped(link.rect, area: area, capture: capture,
                            y: geometry.height - geometry.header - area.height * capture))
                    }
                }
                if let footerPage {
                    let area = footerPage.getBoxRect(.mediaBox)
                    writer.saveGState()
                    writer.translateBy(x: geometry.left, y: geometry.footer)
                    writer.scaleBy(x: capture, y: capture)
                    writer.translateBy(x: -area.minX, y: -area.minY)
                    writer.drawPDFPage(footerPage)
                    writer.restoreGState()
                    for link in footerLinks {
                        writer.setURL(link.url as CFURL, for: stamped(link.rect, area: area, capture: capture,
                            y: geometry.footer))
                    }
                }
                // Annotations live beside the content stream, so they are re-issued here.
                for (number, link) in links.enumerated() where link.page == index {
                    let rect = link.rect.offsetBy(dx: -source.minX, dy: -source.minY)
                        .applying(CGAffineTransform(scaleX: back.x, y: back.y))
                    if let url = link.url {
                        writer.setURL(url as CFURL, for: rect)
                    } else {
                        writer.setDestination("link-\(number)" as CFString, for: rect)
                    }
                }
                for (number, link) in links.enumerated() where link.destination?.page == index {
                    let point = link.destination!.point
                    writer.addDestination("link-\(number)" as CFString,
                        at: CGPoint(x: (point.x - source.minX) * back.x, y: (point.y - source.minY) * back.y))
                }
                writer.endPDFPage()
            }
        }
        writer.closePDF()
        guard try FileStamp(output).size <= 512 * 1024 * 1024 else {
            throw Failure.message("The document PDF exceeds 512 MiB.")
        }
        complete = true
    }

    func cleanUp() { try? FileManager.default.removeItem(at: body) }

    /// WebKit reports a thrown script error as one opaque code. Carry its message instead.
    private static func value(_ result: Result<Any, Error>) throws -> Any {
        do { return try result.get() } catch {
            let info = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            throw info.map { Failure.message(String($0.prefix(1000))) } ?? error
        }
    }
}
