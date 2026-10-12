import AppKit
import CoreServices

/// Synthetic feasibility check only. No audio, global keyboard events,
/// Accessibility access, or production model processes are involved.
final class StoreProbeProvider: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(2) }
    }

    @objc func provideProbeText(_ pasteboard: NSPasteboard, userData: String?,
                               error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let denied = userData.map { FileManager.default.contents(atPath: $0) == nil } ?? false
        let payload: [String: Any] = ["text": "Text returned by the sandboxed provider.",
                                      "outsideMarkerReadDenied": denied]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            pasteboard.clearContents()
            guard let text = String(data: data, encoding: .utf8),
                  pasteboard.setString(text, forType: .string) else {
                errorPointer.pointee = "The private service pasteboard could not receive the probe." as NSString
                return
            }
        } catch {
            errorPointer.pointee = "The synthetic service response could not be encoded." as NSString
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}

@main
enum AppStoreServicesProbe {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        if CommandLine.arguments.count == 3, ["--consumer", "--store-consumer", "--store-runtime-consumer"].contains(CommandLine.arguments[1]) {
            application.finishLaunching()
            do { try consume(provider: URL(fileURLWithPath: CommandLine.arguments[2]), storeEdition: CommandLine.arguments[1] != "--consumer", runtime: CommandLine.arguments[1] == "--store-runtime-consumer") }
            catch { fputs("Services probe failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let provider = StoreProbeProvider()
        application.delegate = provider
        application.run()
        withExtendedLifetime(provider) {}
    }

    static func consume(provider: URL, storeEdition: Bool = false, runtime: Bool = false) throws {
        guard let bundle = Bundle(url: provider),
              let services = bundle.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]],
              let menu = services.first?["NSMenuItem"] as? [String: String],
              let name = menu["default"] else { throw failure("The provider specification is missing.") }
        let registration = LSRegisterURL(provider as CFURL, true)
        guard registration == noErr else { throw failure("Launch Services registration failed (\(registration)).") }
        NSUpdateDynamicServices()
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var performed = false
        let registrationDeadline = Date().addingTimeInterval(8)
        repeat {
            performed = NSPerformService(name, pasteboard)
            if performed { break }
            NSUpdateDynamicServices()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        } while Date() < registrationDeadline
        guard performed, let text = pasteboard.string(forType: .string) else {
            throw failure("The cross-process Services request did not return text.")
        }
        let returnedText: String
        if storeEdition {
            guard runtime ? (text.lowercased().contains("local dictation") && text.lowercased().contains("private"))
                          : text == "Text returned by the Store edition." else { throw failure("The Store modal did not return its expected fixture.") }
            returnedText = text
        } else {
            guard let data = text.data(using: .utf8), let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = payload["text"] as? String, payload["outsideMarkerReadDenied"] as? Bool == true else {
                throw failure("The provider could read the outside marker; sandbox enforcement was not demonstrated.")
            }
            returnedText = value
        }

        // This is the standard AppKit requestor operation documented by Apple.
        // It exercises an owned synthetic editor, not an existing user window.
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.makeFirstResponder(editor)
        editor.isEditable = true
        editor.string = "Draft: "
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        let legacyString = NSPasteboard.PasteboardType(rawValue: "NSStringPboardType")
        let candidateTypes: [NSPasteboard.PasteboardType] = [.string, legacyString]
        let requestorType = candidateTypes.first {
            editor.validRequestor(forSendType: nil, returnType: $0) != nil
        }
        guard let requestorType else {
            throw failure("The AppKit editor does not accept a return-only text service.")
        }
        pasteboard.clearContents()
        pasteboard.setString(returnedText, forType: .string)
        guard editor.readSelection(from: pasteboard), editor.string == "Draft: " + returnedText else {
            throw failure("The AppKit requestor could not insert the returned text at its caret.")
        }
        var result: [String: Any] = ["sandboxProviderRoundTrip": true, "appKitCaretInsertion": true,
            "recordedAudio": false, "usedAccessibility": false,
            "postedGlobalInput": false, "usedGeneralClipboard": false,
            "requestorReturnType": requestorType.rawValue, "storeModalRoundTrip": storeEdition, "storeRuntimeThroughModal": runtime]
        if !storeEdition { result["outsideMarkerReadDenied"] = true }
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "LocalDictationServicesProbe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
