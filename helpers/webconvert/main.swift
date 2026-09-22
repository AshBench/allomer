import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

enum Failure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case let .message(value): return value } }
}

final class SVGCheck: NSObject, XMLParserDelegate {
    var depth = 0, nodes = 0
    var isSVG = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if nodes == 0 { isSVG = name == "svg" && namespaceURI == "http://www.w3.org/2000/svg" }
        depth += 1
        nodes += 1
        if depth > 256 || nodes > 100_000 { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
}

struct FileStamp: Equatable {
    let size: Int64
    let modifiedSeconds: Int, modifiedNanos: Int
    let changedSeconds: Int, changedNanos: Int
    let inode: UInt64, device: Int32
    init(_ url: URL) throws {
        var values = stat()
        guard lstat(url.path, &values) == 0, values.st_mode & S_IFMT == S_IFREG else {
            throw Failure.message("A web resource is not a readable regular file.")
        }
        size = values.st_size
        inode = values.st_ino
        device = values.st_dev
        modifiedSeconds = values.st_mtimespec.tv_sec
        modifiedNanos = values.st_mtimespec.tv_nsec
        changedSeconds = values.st_ctimespec.tv_sec
        changedNanos = values.st_ctimespec.tv_nsec
    }
}

func readResource(_ url: URL) throws -> Data {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
    guard data.count <= 64 * 1024 * 1024 else { throw Failure.message("A document resource exceeds 64 MiB.") }
    return data
}

final class WebRenderer: NSObject, WKNavigationDelegate, WKURLSchemeHandler, WKScriptMessageHandler {
    let input: URL, root: URL, output: URL, format: String
    let isHTML: Bool, template: String
    let source: Data
    let intrinsic: CGSize, size: CGSize
    var view: WKWebView!
    var error: Error?
    var done = false
    var resources: [URL: FileStamp] = [:]
    var resourceBytes: Int64 = 0
    var rasterPixels = 0
    var printOperation: NSPrintOperation?
    var printWindow: NSWindow?
    let address: URL

    init(input: URL, root: URL, output: URL, format: String, width: Int = 0, height: Int = 0, scale: Double = 1,
         paper: String? = nil, template: String = "none") throws {
        self.input = input.resolvingSymlinksInPath()
        self.root = root.resolvingSymlinksInPath()
        self.output = output.absoluteURL
        self.format = format
        isHTML = paper != nil
        self.template = template
        address = URL(string: "local-render://source/")!.appendingPathComponent(input.lastPathComponent)
        let stamp = try FileStamp(self.input)
        guard stamp.size > 0, stamp.size <= 64 * 1024 * 1024 else {
            throw Failure.message("Use a web document up to 64 MiB.")
        }
        source = try readResource(self.input)
        if let paper {
            guard ["a4", "letter"].contains(paper), ["none", "github", "minimal"].contains(template),
                  let text = String(data: source, encoding: .utf8), !text.contains("\0") else {
                throw Failure.message("Use UTF-8 HTML with a valid page size and template.")
            }
            intrinsic = paper == "a4" ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792)
            size = intrinsic
        } else {
            let check = SVGCheck(), parser = XMLParser(data: source)
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = check
            guard parser.parse(), check.isSVG, let image = NSImage(data: source) else {
                throw Failure.message("The source is not a readable SVG document.")
            }
            intrinsic = image.size
            guard [intrinsic.width, intrinsic.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100_000 }),
                  intrinsic.width * intrinsic.height <= 32_000_000,
                  (0...100_000).contains(width), (0...100_000).contains(height) else {
                throw Failure.message("The SVG dimensions exceed their limits.")
            }
            let dimensions: CGSize
            if width > 0 {
                dimensions = CGSize(width: Double(width), height: height > 0 ? Double(height) : Double(width) * intrinsic.height / intrinsic.width)
            } else if height > 0 {
                dimensions = CGSize(width: Double(height) * intrinsic.width / intrinsic.height, height: Double(height))
            } else {
                guard scale.isFinite, scale > 0 else { throw Failure.message("SVG scale must be positive.") }
                dimensions = CGSize(width: intrinsic.width * scale, height: intrinsic.height * scale)
            }
            size = format == "png" ? CGSize(width: dimensions.width.rounded(), height: dimensions.height.rounded()) : dimensions
            guard [size.width, size.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100_000 }),
                  size.width * size.height <= 32_000_000 else {
                throw Failure.message("The SVG output exceeds 32 million pixels or 100,000 pixels on an edge.")
            }
        }
        super.init()
        resources[self.input] = stamp
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.shouldPrintBackgrounds = true
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(self, forURLScheme: "local-render")
        config.userContentController.add(self, contentWorld: .defaultClient, name: "blocked")
        config.userContentController.addUserScript(WKUserScript(source: """
            document.addEventListener('securitypolicyviolation', event => {
                if (!event.effectiveDirective.startsWith('script-src')) window.webkit.messageHandlers.blocked.postMessage(true);
            });
            document.addEventListener('error', event => {
                if (['image', 'img', 'use', 'link'].includes(event.target.localName)) window.webkit.messageHandlers.blocked.postMessage(true);
            }, true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        view = WKWebView(frame: CGRect(origin: .zero, size: intrinsic), configuration: config)
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = self
    }

    func start() { view.load(URLRequest(url: address)) }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == address.scheme, url.host == address.host else {
                throw Failure.message("The document contains an unsupported resource URL.")
            }
            let data: Data, mime: String
            if url.path == address.path {
                data = source
                mime = isHTML ? "text/html; charset=utf-8" : "image/svg+xml"
            } else {
                let file = root.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL.resolvingSymlinksInPath()
                guard file.pathComponents.starts(with: root.pathComponents) else { throw Failure.message("A document resource is outside its source folder.") }
                let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                             "webp": "image/webp", "avif": "image/avif", "svg": "image/svg+xml", "css": "text/css",
                             "ttf": "font/ttf", "otf": "font/otf", "woff": "font/woff", "woff2": "font/woff2"]
                guard let type = types[file.pathExtension.lowercased()] else {
                    throw Failure.message("A document resource has an unsupported file type.")
                }
                mime = type
                let stamp = try FileStamp(file)
                let isNew = resources[file] == nil
                if isNew {
                    guard resources.count < 1024, stamp.size >= 0, stamp.size <= 64 * 1024 * 1024,
                          resourceBytes <= 512 * 1024 * 1024 - stamp.size else {
                        throw Failure.message("The document resources exceed their size or file-count limit.")
                    }
                    resourceBytes += stamp.size
                    resources[file] = stamp
                } else if resources[file] != stamp { throw Failure.message("A document resource changed during conversion.") }
                data = try readResource(file)
                if mime.hasPrefix("image/"), mime != "image/svg+xml" {
                    guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 100_000, height <= 100_000, width <= 32_000_000 / height else {
                        throw Failure.message("An image resource is unreadable or exceeds 32 million pixels.")
                    }
                    if isNew {
                        guard rasterPixels <= 128_000_000 - width * height else {
                            throw Failure.message("The local image resources exceed 128 million pixels in total.")
                        }
                        rasterPixels += width * height
                    }
                }
            }
            let policy = "default-src 'none'; style-src 'unsafe-inline' local-render: data:; img-src local-render: data:; font-src local-render: data:; base-uri 'none'; form-action 'none'"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime, "Content-Security-Policy": policy, "Content-Length": String(data.count)])!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            self.error = error
            task.didFailWithError(error)
        }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if error == nil { error = Failure.message("A document resource could not be loaded. Network resources are not available offline.") }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == address && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error; done = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error; done = true }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = Failure.message("The web renderer stopped before completion."); done = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript("""
            if (document.getElementsByTagName('*').length > 100000) throw new Error('The document exceeds 100,000 elements.');
            if (style) { const node = document.createElement('style'); node.textContent = style; document.head.appendChild(node); }
            if (document.documentElement.pauseAnimations) {
                document.documentElement.pauseAnimations(); document.documentElement.setCurrentTime(0);
            }
            for (const animation of document.getAnimations()) { animation.pause(); animation.currentTime = 0; }
            await document.fonts.ready;
            if (Array.from(document.fonts).some(font => font.status === 'error')) throw new Error('A document font could not be loaded.');
            """, arguments: ["style": templateStyle], in: nil, in: .defaultClient) { result in
            do {
                _ = try result.get()
                if let error = self.error { throw error }
                if self.isHTML { self.printHTML(); return }
                let config = WKPDFConfiguration()
                config.rect = CGRect(origin: .zero, size: self.intrinsic)
                config.allowTransparentBackground = true
                webView.createPDF(configuration: config) { result in
                    do { try self.save(result.get()) } catch { self.error = error }
                    self.done = true
                }
            } catch { self.error = error; self.done = true }
        }
    }

    var templateStyle: String {
        guard template != "none" else { return "" }
        let family = template == "github" ? "-apple-system, Helvetica, Arial, sans-serif" : "Georgia, Times, serif"
        return """
            body { margin:0; max-width:none; padding:0; font:16px/1.5 \(family); color:#202124; background:white }
            h1,h2,h3,h4,h5,h6 { line-height:1.25; break-after:avoid }
            h1,h2 { border-bottom:1px solid #d8dee4; padding-bottom:0.25em }
            pre { white-space:pre-wrap; overflow-wrap:anywhere; padding:12px; background:#f4f5f6; border-radius:4px }
            code { font-family:Menlo,monospace; font-size:0.85em }
            table { border-collapse:collapse; max-width:100% } th,td { border:1px solid #d8dee4; padding:6px 12px }
            img,svg { max-width:100%; height:auto } blockquote { margin-left:0; padding-left:1em; border-left:3px solid #d8dee4 }
            a { color:\(template == "github" ? "#0969da" : "inherit") }
            @media print { body { margin:0; padding:0 } }
            """
    }

    func printHTML() {
        let info = NSPrintInfo(dictionary: [:])
        info.paperSize = size
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        info.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
        info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 1
        info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 10_001
        let operation = view.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit waits for pagination on its print worker while the main run loop receives the result.
        operation.canSpawnSeparateThread = true
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: true)
        printWindow = window
        printOperation = operation
        operation.runModal(for: window, delegate: self, didRun: #selector(printed(_:success:context:)), contextInfo: nil)
    }

    @objc func printed(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        do {
            guard success, let document = CGPDFDocument(output as CFURL), (1...10_000).contains(document.numberOfPages) else {
                throw Failure.message("The document print operation failed or exceeded 10,000 pages.")
            }
            for number in 1...document.numberOfPages {
                guard let page = document.page(at: number) else { throw Failure.message("A printed page is unreadable.") }
                let box = page.getBoxRect(.mediaBox)
                guard abs(box.width - size.width) <= 1, abs(box.height - size.height) <= 1 else {
                    throw Failure.message("A printed page has an unexpected paper size.")
                }
            }
            try checkResources()
        } catch { self.error = error }
        done = true
        printOperation = nil
        printWindow = nil
    }

    func checkResources() throws {
        for (file, stamp) in resources where try FileStamp(file) != stamp { throw Failure.message("A document resource changed during conversion.") }
    }

    func save(_ data: Data) throws {
        if let error { throw error }
        guard data.count <= 512 * 1024 * 1024, let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages == 1, let page = document.page(at: 1) else {
            throw Failure.message("The SVG renderer did not produce one readable PDF page.")
        }
        let sourceBox = page.getBoxRect(.mediaBox)
        guard page.rotationAngle == 0, [sourceBox.width, sourceBox.height].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw Failure.message("The SVG renderer produced invalid page dimensions.")
        }
        var box = CGRect(origin: .zero, size: size)
        let context: CGContext
        if format == "pdf" {
            guard let writer = CGContext(output as CFURL, mediaBox: &box, nil) else { throw Failure.message("The SVG PDF output could not be opened.") }
            context = writer
            context.beginPDFPage(nil)
        } else {
            guard let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure.message("The SVG image buffer could not be created.")
            }
            context = bitmap
        }
        context.scaleBy(x: size.width / sourceBox.width, y: size.height / sourceBox.height)
        context.translateBy(x: -sourceBox.minX, y: -sourceBox.minY)
        context.drawPDFPage(page)
        if format == "pdf" { context.endPDFPage(); context.closePDF() }
        else {
            guard let image = context.makeImage(), let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw Failure.message("The SVG PNG output could not be opened.")
            }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw Failure.message("The SVG PNG writer failed.") }
        }
        try checkResources()
    }
}

do {
    let args = CommandLine.arguments
    NSApplication.shared.setActivationPolicy(.prohibited)
    if args.count == 6, args[2] == "pptx", let count = Int(args[5]) {
        let renderer = try PresentationRenderer(input: URL(fileURLWithPath: args[3]), root: URL(fileURLWithPath: args[1]),
            output: URL(fileURLWithPath: args[4]), count: count)
        renderer.start()
        let deadline = Date().addingTimeInterval(110)
        while !renderer.done && Date() < deadline {
            autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        renderer.view.stopLoading()
        guard renderer.done else { throw Failure.message("The slide renderer timed out.") }
        if let error = renderer.error { throw error }
        exit(0)
    }
    if args.count == 6, args[2] == "docx", let geometry = WordRenderer.Geometry(args[5]) {
        let renderer = try WordRenderer(input: URL(fileURLWithPath: args[3]), root: URL(fileURLWithPath: args[1]),
            output: URL(fileURLWithPath: args[4]), geometry: geometry)
        renderer.start()
        let deadline = Date().addingTimeInterval(110)
        while !renderer.done && Date() < deadline {
            autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        renderer.view.stopLoading()
        // exit() skips deferred work, so the paginated body is removed before either outcome.
        renderer.cleanUp()
        guard renderer.done else { throw Failure.message("The document renderer timed out.") }
        if let error = renderer.error { throw error }
        exit(0)
    }
    let renderer: WebRenderer
    if args.count == 9, args[2] == "svg", ["pdf", "png"].contains(args[5]),
       let width = Int(args[6]), let height = Int(args[7]), let scale = Double(args[8]) {
        renderer = try WebRenderer(input: URL(fileURLWithPath: args[3]), root: URL(fileURLWithPath: args[1]),
            output: URL(fileURLWithPath: args[4]), format: args[5], width: width, height: height, scale: scale)
    } else if args.count == 8, args[2] == "html", args[5] == "pdf" {
        renderer = try WebRenderer(input: URL(fileURLWithPath: args[3]), root: URL(fileURLWithPath: args[1]),
            output: URL(fileURLWithPath: args[4]), format: "pdf", paper: args[6], template: args[7])
    } else {
        throw Failure.message("Expected: RESOURCE_ROOT svg INPUT OUTPUT png|pdf WIDTH HEIGHT SCALE; or RESOURCE_ROOT html INPUT OUTPUT pdf a4|letter none|github|minimal; or RESOURCE_ROOT docx INPUT OUTPUT GEOMETRY")
    }
    renderer.start()
    let deadline = Date().addingTimeInterval(110)
    while !renderer.done && Date() < deadline {
        autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    renderer.view.stopLoading()
    guard renderer.done else { throw Failure.message("The web renderer timed out.") }
    if let error = renderer.error { throw error }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
