import UIKit
import WebKit
import Foundation
import Darwin

/// UIKit test-build SDK. Controls use public UIKit actions; raw gestures remain with System Driver.
public enum E2EStudioSDK {
    private static var server: SDKServer?
    @MainActor public static func startIfRequested() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard server == nil, let token = env["E2E_SDK_TOKEN"], token.utf8.count >= 32,
              let port = env["E2E_SDK_PORT"].flatMap(UInt16.init), port >= 1024 else { return }
        let instance = SDKServer(port: port, token: token)
        server = instance
        instance.start()
        #endif
    }
}

private struct SDKError: Error {
    let message: String
    let code: String
    init(_ message: String, code: String = "OPERATION_FAILED") { self.message = message; self.code = code }
}
private final class SDKRequest {
    private let lock = NSLock()
    private var cancelled = false
    func begin() -> Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
private final class SDKServer {
    let port: UInt16
    let token: String
    init(port: UInt16, token: String) { self.port = port; self.token = token }
    func start() {
        DispatchQueue(label: "dev.e2estudio.sdk").async { [self] in
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            guard listener >= 0 else { return }
            defer { close(listener) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, listen(listener, 4) == 0 else { return }
            while true {
                let client = accept(listener,nil,nil)
                if client < 0 { return }
                var timeout = timeval(tv_sec: 5,tv_usec: 0)
                setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                var noSignal: Int32 = 1
                setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
                serve(client)
                close(client)
            }
        }
    }
    private func line(_ fd: Int32) -> String? {
        var data = Data(), byte: UInt8 = 0
        while data.count < 8192 {
            guard recv(fd,&byte,1,0) == 1 else { return nil }
            if byte == 10 { return String(data: data,encoding: .utf8) }
            if byte != 13 { data.append(byte) }
        }
        return nil
    }
    private func serve(_ fd: Int32) {
        guard let first = line(fd)?.split(separator: " "), first.count >= 2 else { return }
        var auth = "", size = 0, count = 0
        while let header = line(fd), !header.isEmpty {
            count += 1; if count > 32 { return }
            let pieces = header.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2 {
                let value = pieces[1].trimmingCharacters(in: .whitespaces)
                if pieces[0].lowercased() == "authorization" { auth = value }
                if pieces[0].lowercased() == "content-length" { size = Int(value) ?? -1 }
            }
        }
        guard auth == "Bearer \(token)" else { respond(fd,401,["error":"Unauthorized"]); return }
        guard size >= 0 && size <= 1_048_576 else { respond(fd,413,["error":"Request too large"]); return }
        var data = Data(count: size), received = 0
        while received < size {
            let n = data.withUnsafeMutableBytes { recv(fd,$0.baseAddress!.advanced(by: received),size-received,0) }
            if n <= 0 { return }; received += n
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] ?? [:]
        let done = DispatchSemaphore(value: 0), request = SDKRequest()
        var result: Result<Any,Error>?
        let method = String(first[0]), path = String(first[1])
        DispatchQueue.main.async {
            guard request.begin() else { return }
            result = Result { try self.handle(method,path,body) }; done.signal()
        }
        guard done.wait(timeout: .now()+3) == .success else {
            request.cancel(); respond(fd,504,["error":"UI thread did not respond; action is not retried"]); return
        }
        switch result {
        case .success(let value): respond(fd,200,["value":value])
        case .failure(let error):
            let e = error as? SDKError
            respond(fd,422,["error":e?.message ?? "SDK operation failed","code":e?.code ?? "OPERATION_FAILED"])
        case nil: respond(fd,500,["error":"SDK operation failed"])
        }
    }
    private func respond(_ fd: Int32,_ status: Int,_ body: [String:Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        let header = "HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        let bytes = Data(header.utf8)+payload
        var sent = 0
        bytes.withUnsafeBytes { buffer in
            while sent < bytes.count {
                let n = send(fd,buffer.baseAddress!.advanced(by: sent),bytes.count-sent,0)
                if n <= 0 { return }; sent += n
            }
        }
    }
    @MainActor private func windows() -> [UIWindow] {
        let sceneWindows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        // Apps with the legacy UIApplicationDelegate lifecycle have no UIWindowScene.
        let candidates = sceneWindows.isEmpty ? UIApplication.shared.windows : sceneWindows
        return candidates.filter { !$0.isHidden && $0.alpha > 0.01 }
    }
    @MainActor private func hasWebView(_ view: UIView) -> Bool {
        view is WKWebView || view.subviews.contains(where: hasWebView)
    }
    @MainActor private func hasSwiftUIController(_ controller: UIViewController) -> Bool {
        guard controller.isViewLoaded, let view = controller.viewIfLoaded,
              view.window != nil, !view.isHidden else { return false }
        var mirror: Mirror? = Mirror(reflecting: controller)
        while let current = mirror {
            if String(describing: current.subjectType).hasPrefix("UIHostingController<") { return true }
            mirror = current.superclassMirror
        }
        return controller.children.contains(where: hasSwiftUIController)
            || controller.presentedViewController.map(hasSwiftUIController) == true
    }
    @MainActor private func hasUnsupportedUI(_ window: UIWindow) -> Bool {
        if hasWebView(window) { return true }
        if #available(iOS 18.1, *) { return false }
        return window.rootViewController.map(hasSwiftUIController) == true
    }
    @MainActor private func handle(_ method: String,_ path: String,_ body: [String:Any]) throws -> Any {
        let views = windows()
        let ready = UIApplication.shared.applicationState == .active && !views.isEmpty
        if method == "GET" && path == "/status" {
            let supported = !views.isEmpty && !views.contains(where: hasUnsupportedUI)
            return ["product":"e2e-studio-inapp-sdk","protocol":1,"version":"0.2.0","platform":"ios",
                    "revision":"swiftui-actions-preview.1",
                    "appId":Bundle.main.bundleIdentifier ?? "", "ready":ready,
                    "capabilities":supported ? ["hierarchy","tap","tap-check","type","clear","keyboard-hide"] : []] as [String:Any]
        }
        if method == "GET" && path == "/diagnostics" {
            return ["fields": views.flatMap { diagnosticFields($0) }]
        }
        guard ready else { throw SDKError("Application is not the foreground app",code:"NOT_FOREGROUND") }
        guard !views.contains(where:hasUnsupportedUI) else { throw SDKError("WebView or SwiftUI on this OS requires System Driver",code:"UNSUPPORTED_UI") }
        if method == "GET" && path == "/hierarchy" {
            let frame = views.first!.screen.bounds
            var seen=Set<ObjectIdentifier>()
            let swiftUI=views.contains { $0.rootViewController.map(hasSwiftUIController) == true }
            let children=swiftUI ? views.compactMap { semanticNode($0,0,&seen) } : views.map { node($0,0) }
            return ["root":["className":"Application","bounds":bounds(frame),"children":children],
                    "screenSize":["width":Int(frame.width),"height":Int(frame.height)]] as [String:Any]
        }
        guard method == "POST" else { throw SDKError("Unsupported SDK operation") }
        if path == "/tap-check" {
            // Read-only negotiation: Auto can choose System before any action is dispatched.
            let supported=tapTarget(views, body) != nil || accessibilityTapTarget(views, body) != nil
            return ["supported": supported, "blocked":!supported && expectedTargetExists(views,body),
                    "pending": views.contains { $0.rootViewController.map(isTransitioning) == true }]
        }
        if path == "/tap" {
            guard let target = tapTarget(views, body) else {
                guard let element=accessibilityTapTarget(views,body) else { throw SDKError("Target needs a System Driver gesture; select Auto", code:"UNSUPPORTED_ACTION") }
                guard element.accessibilityActivate() else { throw SDKError("Accessibility element did not activate; action was not replayed") }
                return true
            }
            if let field = target as? UITextField {
                guard field.becomeFirstResponder() else { throw SDKError("Input declined keyboard focus") }
            } else if let text = target as? UITextView {
                guard text.becomeFirstResponder() else { throw SDKError("Input declined keyboard focus") }
            } else if let toggle = target as? UISwitch {
                toggle.setOn(!toggle.isOn, animated:false); toggle.sendActions(for:.valueChanged)
            } else if let button = target as? UIButton {
                let event: UIControl.Event = button.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside
                button.sendActions(for:event)
            }
            return true
        }
        if path == "/keyboard-hide" { views.forEach { $0.endEditing(true) }; return true }
        guard let view = views.compactMap({ responder($0) }).first, let input = view as? UIKeyInput else { throw SDKError("Focus an editable UIKit text field first") }
        if path == "/type", let text = body["text"] as? String { input.insertText(text); return true }
        if path == "/clear" {
            guard let textInput = view as? UITextInput else { throw SDKError("Focused field does not support text selection") }
            textInput.selectedTextRange = textInput.textRange(from:textInput.beginningOfDocument,to:textInput.endOfDocument)
            input.deleteBackward(); return true
        }
        throw SDKError("Unsupported SDK operation")
    }
    /// Resolve only controls whose public activation has known semantics. No private touch injection,
    /// accessibilityActivate guessing, or mutation happens during capability negotiation.
    @MainActor private func tapTarget(_ windows: [UIWindow], _ body: [String:Any]) -> UIView? {
        guard let x = body["x"] as? NSNumber, let y = body["y"] as? NSNumber,
              x.doubleValue.isFinite, y.doubleValue.isFinite else { return nil }
        let point = CGPoint(x:x.doubleValue, y:y.doubleValue)
        for window in windows.sorted(by: { $0.windowLevel > $1.windowLevel }) {
            guard let hit = window.hitTest(window.convert(point, from:nil), with:nil) else { continue }
            var current: UIView? = hit
            while let view = current {
                if let field = view as? UITextField { return field.isEnabled && matchesTarget(field,body) ? field : nil }
                if let text = view as? UITextView { return text.isEditable && matchesTarget(text,body) ? text : nil }
                if let toggle = view as? UISwitch { return toggle.isEnabled && matchesTarget(toggle,body) ? toggle : nil }
                if let button = view as? UIButton {
                    return button.isEnabled && matchesTarget(button,body) && !button.allControlEvents.intersection([.touchUpInside,.primaryActionTriggered]).isEmpty ? button : nil
                }
                // Standard controls own internal decoration/recognizer views (including UISwitch).
                // Activate the nearest supported ancestor, never a view behind the hit-test result.
                current = view.superview
            }
            return nil
        }
        return nil
    }
    @MainActor private func isTransitioning(_ controller: UIViewController) -> Bool {
        controller.isBeingPresented || controller.isBeingDismissed || controller.transitionCoordinator != nil
            || controller.children.contains(where:isTransitioning)
            || controller.presentedViewController.map(isTransitioning) == true
    }
    @MainActor private func accessibilityTapTarget(_ windows: [UIWindow],_ body: [String:Any]) -> NSObject? {
        guard #available(iOS 18.1, *), let x=body["x"] as? NSNumber, let y=body["y"] as? NSNumber,
              x.doubleValue.isFinite, y.doubleValue.isFinite else { return nil }
        let point=CGPoint(x:x.doubleValue,y:y.doubleValue)
        for window in windows.sorted(by:{ $0.windowLevel > $1.windowLevel }) {
            guard window.hitTest(window.convert(point,from:nil),with:nil) != nil else { continue }
            guard let element=window.accessibilityHitTest(point,event:nil) as? NSObject,
                  element.isAccessibilityElement, element.accessibilityFrame.contains(point),
                  matchesTarget(element,body),
                  element.accessibilityTraits.contains(.button), !element.accessibilityTraits.contains(.notEnabled) else { return nil }
            return element
        }
        return nil
    }
    @MainActor private func matchesTarget(_ object: NSObject,_ body: [String:Any]) -> Bool {
        if let id=body["targetId"] as? String, !id.isEmpty { return accessibilityID(object)==id }
        if let label=body["targetLabel"] as? String, !label.isEmpty {
            return [object.accessibilityLabel,(object as? UIButton)?.currentTitle,(object as? UILabel)?.text,(object as? UITextField)?.placeholder].contains { $0==label }
        }
        return true
    }
    @MainActor private func expectedTargetExists(_ windows: [UIWindow],_ body: [String:Any]) -> Bool {
        guard body["targetId"] != nil || body["targetLabel"] != nil,
              let x=body["x"] as? NSNumber, let y=body["y"] as? NSNumber else { return false }
        let point=CGPoint(x:x.doubleValue,y:y.doubleValue)
        var seen=Set<ObjectIdentifier>()
        func visit(_ object: NSObject,_ depth: Int) -> Bool {
            guard depth < 60, seen.count < 5000, seen.insert(ObjectIdentifier(object)).inserted else { return false }
            let view=object as? UIView
            let frame=view.map { $0.convert($0.bounds,to:nil) } ?? object.accessibilityFrame
            let active=view.map { !$0.isHidden && $0.alpha > 0.01 && $0.window != nil } ?? object.isAccessibilityElement
            let control=object is UITextField || object is UITextView || object is UIButton || object is UISwitch || object.accessibilityTraits.contains(.button)
            if active && control && frame.contains(point) && matchesTarget(object,body) { return true }
            let children=semanticChildren(object) + ((object as? UIView)?.subviews.map { $0 as NSObject } ?? [])
            return children.contains { visit($0,depth+1) }
        }
        return windows.contains { visit($0,0) }
    }
    /// Public automation/accessibility containers expose SwiftUI's virtual elements alongside
    /// UIKit representables. No SwiftUI reflection, private selectors or app view changes.
    @MainActor private func semanticChildren(_ object: NSObject) -> [NSObject] {
        if #available(iOS 17.0, *), let elements=object.automationElements, !elements.isEmpty { return elements.compactMap { $0 as? NSObject } }
        if let elements=object.accessibilityElements, !elements.isEmpty { return elements.compactMap { $0 as? NSObject } }
        let count=object.accessibilityElementCount()
        if count > 0 && count < 5000 { return (0..<count).compactMap { object.accessibilityElement(at:$0) as? NSObject } }
        if object.isAccessibilityElement { return [] }
        return (object as? UIView)?.subviews ?? []
    }
    @MainActor private func semanticNode(_ object: NSObject,_ depth: Int,_ seen: inout Set<ObjectIdentifier>) -> [String:Any]? {
        guard depth < 60, seen.count < 5000, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
        var result: [String:Any]
        if let view=object as? UIView {
            result=nodeAttributes(view)
        } else {
            let traits=object.accessibilityTraits, rect=object.accessibilityFrame
            let button=traits.contains(.button)
            result=["className":button ? "SwiftUI.Button" : "SwiftUI.Text", "bounds":bounds(rect),
                    "visible":!rect.isEmpty && rect.intersects(UIScreen.main.bounds), "enabled":!traits.contains(.notEnabled),
                    "clickable":button, "role":button ? "button" : "text"]
            if let label=object.accessibilityLabel { result["text"]=label;result["label"]=label }
            if #available(iOS 18.1, *), let field=object.accessibilityTextInputResponder as? UITextField {
                result["className"]="SwiftUI.TextField";result["role"]="textbox";result["clickable"]=field.isEnabled
                result["value"]=field.isSecureTextEntry ? "" : field.text;result["hint"]=field.placeholder
                result["focused"]=field.isFirstResponder;result.removeValue(forKey:"text")
            }
        }
        if let id=accessibilityID(object), !id.isEmpty { result["id"]=id }
        result["children"]=semanticChildren(object).compactMap { semanticNode($0,depth+1,&seen) }
        return result
    }
    /// Debugging metadata only; secure text is never returned.
    @MainActor private func accessibilityID(_ object: NSObject) -> String? {
        // Some framework-vended objects implement the public getter without declaring protocol conformance.
        if let identified=object as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
        let getter=NSSelectorFromString("accessibilityIdentifier")
        return object.responds(to:getter) ? object.perform(getter)?.takeUnretainedValue() as? String : nil
    }
    @MainActor private func diagnosticFields(_ view: UIView) -> [[String:Any]] {
        var fields: [[String:Any]] = []
        if let field = view as? UITextField {
            fields.append(["id": field.accessibilityIdentifier ?? "", "length": field.text?.count ?? 0,
                           "focused": field.isFirstResponder, "secure": field.isSecureTextEntry])
        }
        return fields + view.subviews.flatMap(diagnosticFields)
    }
    @MainActor private func responder(_ view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        return view.subviews.compactMap(responder).first
    }
    private func coordinate(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -1_000_000), 1_000_000))
    }
    @MainActor private func bounds(_ r: CGRect) -> [String:Int] {
        ["left":coordinate(r.minX),"top":coordinate(r.minY),"right":coordinate(r.maxX),"bottom":coordinate(r.maxY)]
    }
    @MainActor private func node(_ view: UIView,_ depth: Int) -> [String:Any] {
        var result=nodeAttributes(view)
        result["children"] = depth < 60 ? view.subviews.map { node($0,depth+1) } : []
        return result
    }
    @MainActor private func nodeAttributes(_ view: UIView) -> [String:Any] {
        let rect = view.convert(view.bounds,to:nil)
        var result: [String:Any] = ["className":String(describing:type(of:view)),"bounds":bounds(rect),"enabled":(view as? UIControl)?.isEnabled ?? true,
            "visible":!view.isHidden && view.alpha > 0.01 && view.window != nil && rect.intersects(view.window?.bounds ?? .zero),"focused":view.isFirstResponder]
        if let id = view.accessibilityIdentifier { result["id"] = id }
        if let label = view.accessibilityLabel { result["label"] = label }
        if let label = view as? UILabel { result["text"] = label.text }
        if let field = view as? UITextField { result["value"] = field.isSecureTextEntry ? "" : field.text; result["hint"] = field.placeholder; result["clickable"] = field.isEnabled }
        if let text = view as? UITextView { result["value"] = text.isSecureTextEntry ? "" : text.text; result["clickable"] = text.isEditable }
        if let toggle = view as? UISwitch { result["checked"] = toggle.isOn; result["value"] = toggle.isOn ? "1" : "0"; result["clickable"] = toggle.isEnabled }
        if let button = view as? UIButton { result["text"] = button.currentTitle; result["clickable"] = true; result["enabled"] = button.isEnabled }
        return result
    }
}
