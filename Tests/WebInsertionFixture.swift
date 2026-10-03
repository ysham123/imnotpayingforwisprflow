import AppKit
import WebKit

/// A local, nonpersistent WKWebView. All navigation and all controls belong to
/// this synthetic fixture; no user browser or AI application participates.
@MainActor final class FixtureWebView: WKWebView {
    var deferPaste = false
    var onDeferredPaste: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if deferPaste, event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            onDeferredPaste?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class WebFixtureController: NSObject, WKNavigationDelegate {
    let directory: URL
    let token: String
    let window: NSWindow
    let webView: FixtureWebView
    private var loaded = false
    private var busy = false
    private var lastID = -1
    private var deferredRequests = 0
    private var activeField = "input"
    private var timer: Timer?

    init(directory: URL, token: String) {
        self.directory = directory
        self.token = token
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = FixtureWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 650), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Local Dictation synthetic web fixture"
        window.contentView = webView
        webView.navigationDelegate = self
        webView.onDeferredPaste = { [weak self] in self?.deferredPaste() }
        let main = NSMenu(), item = NSMenuItem(), edit = NSMenu(title: "Edit")
        let paste = NSMenuItem(title: "Paste", action: #selector(pasteFromMenu(_:)), keyEquivalent: "v")
        paste.target = self
        edit.addItem(paste); main.addItem(item); main.setSubmenu(edit, for: item)
        NSApplication.shared.mainMenu = main
    }

    func start() {
        webView.loadHTMLString(Self.html, baseURL: nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.receiveCommand() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.loaded = true }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // loadHTMLString uses about:blank. The fixture never contacts a server.
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    @objc private func pasteFromMenu(_ sender: Any?) {
        if webView.deferPaste { deferredPaste(); return }
        NSApplication.shared.sendAction(NSSelectorFromString("paste:"), to: nil, from: sender)
    }

    private func deferredPaste() {
        deferredRequests += 1
        // Unlike saving event.clipboardData in JavaScript, this actually reads
        // the OS pasteboard after the old one-second restoration deadline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  self.activeField == "delayedRead" else { return }
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            let data = try! JSONSerialization.data(withJSONObject: ["text": text])
            let json = String(data: data, encoding: .utf8)!
            self.webView.evaluateJavaScript("window.fixture.deferredInsert(\(json))") { _, _ in }
        }
    }

    private func receiveCommand() {
        guard loaded, !busy,
              let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              command["token"] as? String == token,
              let id = command["id"] as? Int, id != lastID else { return }
        lastID = id
        if command["quit"] as? Bool == true { NSApplication.shared.terminate(nil); return }
        busy = true
        if let field = command["field"] as? String {
            activeField = field
            webView.deferPaste = field == "delayedRead"
            deferredRequests = 0
        }
        if command["focus"] as? Bool == true {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(webView)
        }
        webView.evaluateJavaScript("window.fixture.command(\(String(data: data, encoding: .utf8)!))") { [weak self] result, error in
            guard let self else { return }
            var reply = (result as? [String: Any]) ?? [:]
            reply["id"] = id
            reply["token"] = self.token
            reply["pid"] = ProcessInfo.processInfo.processIdentifier
            reply["engine"] = "WebKit"
            reply["appActive"] = NSApplication.shared.isActive
            reply["keyWindow"] = self.window.isKeyWindow
            reply["nativeDeferredRequests"] = self.deferredRequests
            if let error { reply["error"] = error.localizedDescription }
            do {
                try JSONSerialization.data(withJSONObject: reply).write(
                    to: self.directory.appendingPathComponent("reply.json"), options: .atomic)
            } catch { fputs("Web fixture reply failed: \(error)\n", stderr) }
            self.busy = false
        }
    }

    private static let html = try! String(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("WebInsertionFixture.html"), encoding: .utf8)
}

@main struct WebInsertionFixture {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = WebFixtureController(directory: URL(fileURLWithPath: CommandLine.arguments[1]), token: CommandLine.arguments[2])
        controller.start()
        withExtendedLifetime(controller) { app.run() }
    }
}
