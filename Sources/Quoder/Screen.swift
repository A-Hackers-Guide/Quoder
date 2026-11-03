import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// Seeing and using the screen. The model reads text only, so the screen is
/// described to it as text: what's written where (OCR) and which controls
/// exist where (accessibility). Coordinates are screen points from the top
/// left of the main display, the same ones click() takes.
enum Screen {
    // MARK: permissions

    static var canControl: Bool { AXIsProcessTrusted() }
    static var canSee: Bool { CGPreflightScreenCaptureAccess() }

    static func askToControl() {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opt)
    }
    static func askToSee() { _ = CGRequestScreenCaptureAccess() }

    // MARK: reading the screen

    /// Every piece of text on the main display, with where it is.
    static func text() async throws -> String {
        guard canSee else { throw ToolError("Quoder needs Screen Recording permission: System Settings → Privacy & Security → Screen & System Audio Recording.") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ToolError("No display found")
        }
        let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let cfg = SCStreamConfiguration()
        cfg.width = display.width * 2; cfg.height = display.height * 2
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([req])
        let w = Double(display.width), h = Double(display.height)
        var lines: [(y: Int, x: Int, s: String)] = []
        for obs in req.results ?? [] {
            guard let t = obs.topCandidates(1).first?.string else { continue }
            let b = obs.boundingBox  // normalized, origin bottom left
            let x = Int((b.midX * w).rounded()), y = Int(((1 - b.midY) * h).rounded())
            lines.append((y, x, t))
        }
        lines.sort { abs($0.y - $1.y) < 6 ? $0.x < $1.x : $0.y < $1.y }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        var out = "Screen \(Int(w))x\(Int(h)) points, frontmost app: \(front)\nText on screen (\"text\" @ x,y = its center):\n"
        // Kept short: every line costs the model reading time.
        for l in lines.prefix(160) { out += "\"\(l.s)\" @ \(l.x),\(l.y)\n" }
        if lines.count > 160 { out += "(\(lines.count - 160) more pieces of text not shown)\n" }
        return out
    }

    /// Controls in the frontmost app's windows (buttons, fields, menus...).
    static func elements() throws -> String {
        guard canControl else { throw ToolError("Quoder needs Accessibility permission: System Settings → Privacy & Security → Accessibility.") }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ToolError("No frontmost app") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var out = "Frontmost app: \(app.localizedName ?? "?")\nControls (role \"label\" @ x,y = center, w x h):\n"
        var count = 0
        let wanted: Set<String> = ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                                   "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTab", "AXComboBox",
                                   "AXSlider", "AXCell", "AXRow", "AXStaticText", "AXImage", "AXSearchField", "AXDisclosureTriangle"]
        func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
            var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 14, count < 120 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if wanted.contains(role) {
                let label = [attr(e, kAXTitleAttribute) as? String, attr(e, kAXDescriptionAttribute) as? String,
                             attr(e, kAXValueAttribute) as? String, attr(e, kAXHelpAttribute) as? String]
                    .compactMap { $0 }.first { !$0.isEmpty } ?? ""
                var p = CGPoint.zero, s = CGSize.zero
                if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
                if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
                if s.width > 0, s.height > 0, !(role == "AXStaticText" && label.isEmpty) {
                    out += "\(role.dropFirst(2)) \"\(label.prefix(80))\" @ \(Int(p.x + s.width / 2)),\(Int(p.y + s.height / 2)) (\(Int(s.width))x\(Int(s.height)))\n"
                    count += 1
                }
            }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
        }
        if let menu = attr(ax, kAXMenuBarAttribute) { walk(menu as! AXUIElement, 12) }  // top-level menu names only
        for w in (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
        if count == 0 { out += "(none found; try screen_text)\n" }
        return out
    }

    // MARK: using the screen

    static func click(x: Double, y: Double, button: String, count: Int) throws {
        guard canControl else { throw ToolError("Quoder needs Accessibility permission to click.") }
        let p = CGPoint(x: x, y: y)
        let right = button == "right"
        let (down, up): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        for i in 1...max(1, min(count, 3)) {
            for t in [down, up] {
                let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: right ? .right : .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e?.post(tap: .cghidEventTap)
                usleep(30_000)
            }
        }
    }

    static func type(_ text: String) throws {
        guard canControl else { throw ToolError("Quoder needs Accessibility permission to type.") }
        let chars = Array(text.utf16)
        var i = 0
        while i < chars.count {
            let chunk = Array(chars[i..<min(i + 16, chars.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
            usleep(15_000)
            i += 16
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
    ]

    /// Presses a combination like "cmd+shift+t", "return" or "ctrl+c".
    static func press(_ combo: String) throws {
        guard canControl else { throw ToolError("Quoder needs Accessibility permission to press keys.") }
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default:
                guard let k = keyCodes[part] else { throw ToolError("Unknown key \"\(part)\"") }
                key = k
            }
        }
        guard let k = key else { throw ToolError("No key in \"\(combo)\"") }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    static func scroll(dy: Int) throws {
        guard canControl else { throw ToolError("Quoder needs Accessibility permission to scroll.") }
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(-dy), wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }
}
