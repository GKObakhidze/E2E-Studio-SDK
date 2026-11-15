import UIKit
import WebKit
import Foundation
import Darwin

/// UIKit test-build SDK. Gestures remain with System Driver until an equivalent public-API implementation is validated.
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
        hasWebView(window) || window.rootViewController.map(hasSwiftUIController) == true
    }
    @MainActor private func handle(_ method: String,_ path: String,_ body: [String:Any]) throws -> Any {
        let views = windows()
        let ready = UIApplication.shared.applicationState == .active && !views.isEmpty
        if method == "GET" && path == "/status" {
            let supported = !views.isEmpty && !views.contains(where: hasUnsupportedUI)
            return ["product":"e2e-studio-inapp-sdk","protocol":1,"version":"0.1.0","platform":"ios",
                    "appId":Bundle.main.bundleIdentifier ?? "", "ready":ready,
                    "capabilities":supported ? ["hierarchy","type","clear","keyboard-hide"] : []] as [String:Any]
        }
        if method == "GET" && path == "/diagnostics" {
            return ["fields": views.flatMap { diagnosticFields($0) }]
        }
        guard ready else { throw SDKError("Application is not the foreground app",code:"NOT_FOREGROUND") }
        guard !views.contains(where:hasUnsupportedUI) else { throw SDKError("SwiftUI/WebView requires System Driver in SDK 0.1",code:"UNSUPPORTED_UI") }
        if method == "GET" && path == "/hierarchy" {
            let frame = views.first!.screen.bounds
            return ["root":["className":"Application","bounds":bounds(frame),"children":views.map { node($0,0) }],
                    "screenSize":["width":Int(frame.width),"height":Int(frame.height)]] as [String:Any]
        }
        guard method == "POST" else { throw SDKError("Unsupported SDK operation") }
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
    /// Debugging metadata only; secure text is never returned.
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
        let rect = view.convert(view.bounds,to:nil)
        var result: [String:Any] = ["className":String(describing:type(of:view)),"bounds":bounds(rect),"enabled":(view as? UIControl)?.isEnabled ?? true,
            "visible":!view.isHidden && view.alpha > 0.01 && view.window != nil && rect.intersects(view.window?.bounds ?? .zero),"focused":view.isFirstResponder]
        if let id = view.accessibilityIdentifier { result["id"] = id }
        if let label = view.accessibilityLabel { result["label"] = label }
        if let label = view as? UILabel { result["text"] = label.text }
        if let field = view as? UITextField { result["value"] = field.isSecureTextEntry ? "" : field.text; result["hint"] = field.placeholder }
        if let text = view as? UITextView { result["value"] = text.isSecureTextEntry ? "" : text.text }
        if let button = view as? UIButton { result["text"] = button.currentTitle; result["clickable"] = true; result["enabled"] = button.isEnabled }
        result["children"] = depth < 60 ? view.subviews.map { node($0,depth+1) } : []
        return result
    }
}
