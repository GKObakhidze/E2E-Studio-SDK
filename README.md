# E2E Studio SDK · 0.3.2 preview

SDK integration for debug/test applications. Android and iOS share this public repository, version and protocol. Licensed under MIT.

## Android — one setup line

Add this line after `plugins { ... }` in the app module's `build.gradle.kts`:

```kotlin
apply(from = "https://raw.githubusercontent.com/GKObakhidze/E2E-Studio-SDK/v0.3.2/android/e2e-studio-sdk.gradle")
```

For Groovy `build.gradle`, the equivalent is:

```groovy
apply from: "https://raw.githubusercontent.com/GKObakhidze/E2E-Studio-SDK/v0.3.2/android/e2e-studio-sdk.gradle"
```

Build and install Debug, then launch it through E2E Studio. This Gradle script plugin adds the SDK only to `debugImplementation`. The Android manifest provider starts it automatically in a debuggable application with Studio's session arguments. No Application/Activity edits, repository blocks, publishing accounts, tokens or global Gradle configuration are required.

The plugin downloads this repository's versioned AAR to Gradle's cache, verifies its pinned SHA-256 and reuses it for subsequent/offline builds. The initial script/SDK download needs network access. Your other application dependencies have their normal build requirements. Product flavors inheriting the Debug build type use the same dependency. Apply the setup in an Android **application** module, not the root project or a library module.

The release artefacts are hosted in this public Git repository. No Maven Central, GitHub Packages or paid registry is required. This repository also retains a Maven-layout copy for teams that prefer their own repository configuration.

## iOS — add the Swift package

1. In Xcode: File → Add Package Dependencies.
2. Add `https://github.com/GKObakhidze/E2E-Studio-SDK.git` and select version **0.3.2**.
3. Link the **E2EStudioSDK** product to the test app target. Build Debug for iOS Simulator.

That completes application integration: no SDK import, startup call, AppDelegate/SwiftUI App edit or Info.plist flag is needed. The linked package schedules automatic startup on the main queue and requires Studio's session environment. The existing `startIfRequested()` API remains compatible with older explicit integrations and will not start a second server.

This preview supports iOS Simulator. UIKit controls and standard SwiftUI controls on iOS 18.1+ support SDK hierarchy, focus, typing/clearing, buttons and toggles. SwiftUI uses public automation/accessibility containers and activation; no application view adapters or initialization code are needed. Older iOS SwiftUI, WebView, arbitrary gestures and unsupported custom controls use System Driver in Auto. Native/system alerts use the explicit system alert/prompt commands. SDK startup is compiled out in Release. To omit SDK code entirely from production, leave the product out of the production app target (use a separate SDK-enabled test target).

## Verify in Studio

Set the app's package/bundle identifier in Applications, leave **Auto — In-app SDK preferred**, and launch the app from a scenario or Inspector. Observe the actual driver and reason; choosing Auto alone does not prove SDK use. Missing SDK or unsupported operations automatically use System Driver. SDK-only is available for diagnostics and explicitly fails for unsupported actions.

Supported SDK operations: native Android Views/UIKit hierarchy and input, native Android taps, UIKit control activation and standard SwiftUI controls on iOS 18.1+. Unsupported UI/gestures/system prompts use the existing platform driver. `handleSystemPrompts()` can dismiss recognized password suggestions during a scenario; permission decisions remain explicit.

Listeners bind loopback and require a per-session credential. A normal launch without the session environment opens no SDK listener. Use SDK-enabled builds for development/QA; omit the dependency from production distributions.

## Offline alternative

Studio can export a local Swift package and Android AAR. For an entirely offline Android integration, put the exported AAR in the app's `libs` directory and add:

```kotlin
debugImplementation(files("libs/e2e-studio-sdk-0.3.2.aar"))
```

Choose either the setup plugin or a manual dependency; do not add both. SDK source is MIT-licensed, and operation is local between Studio and the device. No subscription or runtime cloud service is involved.


SDK 0.3.2 adds a token-protected connection over the private USB tunnel for real iPhones in Debug builds. SDK 0.3.1 was verified on iOS 26.5 with a pure SwiftUI fixture (TextField/SecureField state bindings, Toggle and Button) and the unchanged BankApp authentication views. BankApp validates an invalid email, registers a local training account and logs out/in three times. App UI commands use the SDK; OS password suggestions and native alert confirmation use System Driver and are logged separately. This does not promise raw touch-event equivalence or support for every custom SwiftUI gesture. A read-only target/identity preflight prevents an overlay from receiving a tap intended for a field underneath it. Sent actions are never replayed after an error.
