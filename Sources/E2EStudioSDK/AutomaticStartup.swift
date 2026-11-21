import Foundation

/// C initializer bridge. No application import, delegate hook, or runtime method replacement is needed.
@_cdecl("E2EStudioSDKAutomaticStart")
public func e2eStudioSDKAutomaticStart() {
    #if DEBUG
    let environment = ProcessInfo.processInfo.environment
    // Independent of the SDK session: System Driver runs of an SDK build need it too.
    if environment["E2E_SDK_HIDE_PASSWORD_SUGGESTIONS"] == "1" {
        DispatchQueue.main.async { E2EStudioSDK.hidePasswordSuggestionsIfRequested() }
    }
    guard let token = environment["E2E_SDK_TOKEN"], token.utf8.count >= 32,
          let port = environment["E2E_SDK_PORT"].flatMap(UInt16.init), port >= 1024 else { return }
    DispatchQueue.main.async { E2EStudioSDK.startIfRequested() }
    #endif
}
