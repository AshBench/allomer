import AppKit
import CoreGraphics
import Foundation
import WebKit

final class PresentationRenderer: NSObject, WKNavigationDelegate, WKURLSchemeHandler, WKScriptMessageHandler {
    let input: URL, output: URL
    let stamp: FileStamp
    let count: Int
    private let mediaManifest: Data
    private let mediaLabels: Set<String>
    private var mediaStamps: [URL: FileStamp] = [:]
    let address = URL(string: "local-slides://source/")!
    var view: WKWebView!
    var done = false
    var error: Error?
    private var index = 0
    private var size = CGSize.zero
    private var pdf: CGContext?

    init(input: URL, root: URL, output: URL, count: Int) throws {
        self.input = input
        self.output = output
        self.count = count
        stamp = try FileStamp(input)
        let manifest = input.deletingLastPathComponent().appendingPathComponent("media.json")
        guard try FileStamp(manifest).size <= 32 * 1024 * 1024 else {
            throw Failure.message("The presentation media index exceeds 32 MiB.")
        }
        mediaManifest = try readResource(manifest)
        guard let media = try JSONSerialization.jsonObject(with: mediaManifest) as? [String: String], media.count <= 100_000,
              media.keys.allSatisfy({ $0.hasPrefix("ppt/media/") && !$0.contains("\0") }),
              media.values.allSatisfy({ value in
                  guard let number = Int(value) else { return false }
                  return (1...100_000).contains(number) && String(number) == value
              }) else { throw Failure.message("The presentation media index is invalid.") }
        mediaLabels = Set(media.values)
        let library = root.appendingPathComponent("renderer.js")
        guard stamp.size > 0, stamp.size <= 64 * 1024 * 1024, (1...10_000).contains(count),
              try FileStamp(library).size <= 8 * 1024 * 1024,
              let script = String(data: try readResource(library), encoding: .utf8) else {
            throw Failure.message("The presentation or its renderer exceeds its size limit.")
        }
        super.init()
        var mediaBytes: Int64 = 0
        for label in mediaLabels {
            let file = input.deletingLastPathComponent().appendingPathComponent(label)
            let stamp = try FileStamp(file)
            mediaBytes += stamp.size
            guard stamp.size >= 0, stamp.size <= 32 * 1024 * 1024, mediaBytes <= 192 * 1024 * 1024 else {
                throw Failure.message("The presentation media exceed their size limits.")
            }
            mediaStamps[file] = stamp
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(self, forURLScheme: address.scheme!)
        config.userContentController.add(self, contentWorld: .defaultClient, name: "blocked")
        // A hidden WebKit view does not deliver animation frames. Static export uses timer turns.
        let setup = """
            globalThis.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 0);
            globalThis.cancelAnimationFrame = handle => clearTimeout(handle);
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
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 960, height: 540), configuration: config)
        view.navigationDelegate = self
    }

    func start() { view.load(URLRequest(url: address)) }
    func fail(_ error: Error) {
        if self.error == nil { self.error = error }
        pdf?.closePDF()
        pdf = nil
        done = true
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == address.scheme, url.host == address.host,
                  url.query == nil else {
                throw Failure.message("The presentation requested an unsupported resource.")
            }
            let data: Data
            switch url.path {
            case "/":
                data = Data("""
                    <!DOCTYPE html><meta charset="utf-8">
                    <style>html,body{margin:0;padding:0;background:white}</style><body></body>
                    """.utf8)
            case "/input.pptx": data = try readResource(input)
            case "/media.json": data = mediaManifest
            default:
                let label = String(url.path.dropFirst("/media/".count))
                guard url.path.hasPrefix("/media/"), mediaLabels.contains(label) else {
                    throw Failure.message("The presentation requested an unknown media part.")
                }
                let file = input.deletingLastPathComponent().appendingPathComponent(label)
                guard try FileStamp(file) == mediaStamps[file] else { throw Failure.message("A slide image changed during conversion.") }
                data = try readResource(file)
                guard data.count <= 32 * 1024 * 1024, try FileStamp(file) == mediaStamps[file] else {
                    throw Failure.message("A slide image changed during conversion.")
                }
            }
            let policy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data: blob:; connect-src local-slides:; base-uri 'none'; form-action 'none'"
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": url.path == "/" ? "text/html; charset=utf-8" : "application/octet-stream",
                "Content-Security-Policy": policy, "Content-Length": String(data.count), "Cache-Control": "no-store"])!)
            task.didReceive(data)
            task.didFinish()
        } catch { task.didFailWithError(error); fail(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let detail = (message.body as? String).map { String($0.prefix(1000)) } ?? "A resource was blocked or unreadable."
        fail(Failure.message("The slide could not be rendered. \(detail)"))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == address && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(Failure.message("The slide renderer stopped before completion.")) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        view.callAsyncJavaScript("""
            const bytes = await (await fetch('local-slides://source/input.pptx')).arrayBuffer();
            const files = await PPTX.parseZipLazyMedia(bytes, {...PPTX.RECOMMENDED_ZIP_LIMITS, maxEntries:100000, maxConcurrency:1});
            const media = await (await fetch('local-slides://source/media.json')).json();
            const inflight = new Map();
            files.mediaResolver = {resolve: async target => {
                const name = PPTX.resolveMediaPathCandidates(target).find(name => Object.hasOwn(media, name));
                if (!name) return undefined;
                if (!inflight.has(name)) {
                    inflight.set(name, fetch('local-slides://source/media/' + media[name])
                        .then(response => response.arrayBuffer()).then(bytes => {
                            const data = new Uint8Array(bytes); files.media.set(name, data);
                            return {mediaPath:name, data};
                        }));
                }
                try { return await inflight.get(name); } finally { inflight.delete(name); }
            }};
            window.deck = PPTX.buildPresentation(files, {lazySlides:true});
            return {width:deck.width, height:deck.height, count:deck.slides.length};
            """, arguments: [:], in: nil, in: .defaultClient) { result in
            do {
                if let error = self.error { throw error }
                guard let values = try result.get() as? [String: Double], let width = values["width"], let height = values["height"],
                      values["count"] == Double(self.count),
                      [width, height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10_000 }), width * height <= 32_000_000 else {
                    throw Failure.message("The slide count or dimensions are invalid, or the canvas exceeds 32 million pixels.")
                }
                self.size = CGSize(width: width, height: height)
                self.view.setFrameSize(self.size)
                var box = CGRect(x: 0, y: 0, width: width * 0.75, height: height * 0.75)
                self.pdf = CGContext(self.output as CFURL, mediaBox: &box, nil)
                guard self.pdf != nil else { throw Failure.message("The presentation PDF could not be opened.") }
                self.render()
            } catch { self.fail(error) }
        }
    }

    private func render() {
        view.callAsyncJavaScript("""
            let errors = [];
            window.handle = PPTX.renderSlide(deck, deck.slides[index], {pdfjs:false, onNodeError:(id,error) => errors.push(String(error))});
            document.body.appendChild(handle.element);
            await handle.ready;
            await Promise.all(Array.from(document.images).map(image => image.decode()));
            await document.fonts.ready;
            if (Array.from(document.fonts).some(font => font.status === 'error')) throw new Error('A slide font failed to load.');
            if (errors.length) throw new Error(errors.join('; '));
            if (document.getElementsByTagName('*').length > 100000) throw new Error('A slide exceeds 100,000 elements.');
            for (const animation of document.getAnimations()) { animation.pause(); animation.currentTime = 0; }
            await new Promise(resolve => setTimeout(resolve, 0));
            if (window.renderFailure) throw new Error('A slide resource failed to render.');
            """, arguments: ["index": index], in: nil, in: .defaultClient) { result in
            do {
                _ = try result.get()
                if let error = self.error { throw error }
                let config = WKPDFConfiguration()
                config.rect = CGRect(origin: .zero, size: self.size)
                self.view.createPDF(configuration: config) { result in
                    do {
                        try autoreleasepool { try self.append(result.get()) }
                        self.releaseSlide()
                    } catch { self.fail(error) }
                }
            } catch { self.fail(error) }
        }
    }

    private func append(_ data: Data) throws {
        if let error { throw error }
        guard data.count <= 512 * 1024 * 1024, let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages == 1,
              let page = document.page(at: 1), let pdf else { throw Failure.message("The slide PDF is unreadable.") }
        let box = page.getBoxRect(.mediaBox)
        guard page.rotationAngle == 0, abs(box.width - size.width) < 1, abs(box.height - size.height) < 1 else {
            throw Failure.message("A rendered slide has unexpected dimensions.")
        }
        pdf.beginPDFPage(nil)
        pdf.saveGState()
        pdf.scaleBy(x: 0.75, y: 0.75)
        pdf.translateBy(x: -box.minX, y: -box.minY)
        pdf.drawPDFPage(page)
        pdf.restoreGState()
        pdf.endPDFPage()
        guard try FileStamp(output).size <= 512 * 1024 * 1024 else { throw Failure.message("The presentation PDF exceeds 512 MiB.") }
    }

    private func releaseSlide() {
        view.callAsyncJavaScript("""
            handle.dispose(); handle.element.remove(); window.handle = null;
            deck.media.clear(); deck.slides[index].nodes = []; deck.slides[index].sourceXml = undefined;
            """, arguments: ["index": index], in: nil, in: .defaultClient) { result in
            do {
                _ = try result.get()
                if let error = self.error { throw error }
                self.index += 1
                if self.index == self.count {
                    self.pdf?.closePDF()
                    self.pdf = nil
                    guard try FileStamp(self.input) == self.stamp else { throw Failure.message("The presentation changed during conversion.") }
                    self.done = true
                } else { self.render() }
            } catch { self.fail(error) }
        }
    }
}
