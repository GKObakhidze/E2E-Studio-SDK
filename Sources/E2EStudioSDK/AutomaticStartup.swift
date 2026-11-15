import Foundation

/// C initializer bridge. No application import, delegate hook, or runtime method replacement is needed.
@_cdecl("E2EStudioSDKAutomaticStart")
public func e2eStudioSDKAutomaticStart() {
    #if DEBUG
    let environment = ProcessInfo.processInfo.environment
    guard let token = environment["E2E_SDK_TOKEN"], token.utf8.count >= 32,
          let port = environment["E2E_SDK_PORT"].flatMap(UInt16.init), port >= 1024 else { return }
    DispatchQueue.main.async { E2EStudioSDK.startIfRequested() }
    #endif
}
