# E2E Studio SDK · 0.2.0 preview

SDK integration for debug/test applications. Android and iOS share this public repository, version and protocol. Licensed under MIT.

## Android — one setup line

Add this line after `plugins { ... }` in the app module's `build.gradle.kts`:

```kotlin
apply(from = "https://raw.githubusercontent.com/GKObakhidze/E2E-Studio-SDK/v0.2.0/android/e2e-studio-sdk.gradle")
```

For Groovy `build.gradle`, the equivalent is:

```groovy
apply from: "https://raw.githubusercontent.com/GKObakhidze/E2E-Studio-SDK/v0.2.0/android/e2e-studio-sdk.gradle"
```

Build and install Debug, then launch it through E2E Studio. This Gradle script plugin adds the SDK only to `debugImplementation`. The Android manifest provider starts it automatically in a debuggable application with Studio's session arguments. No Application/Activity edits, repository blocks, publishing accounts, tokens or global Gradle configuration are required.

The plugin downloads this repository's versioned AAR to Gradle's cache, verifies its pinned SHA-256 and reuses it for subsequent/offline builds. The initial script/SDK download needs network access. Your other application dependencies have their normal build requirements. Product flavors inheriting the Debug build type use the same dependency. Apply the setup in an Android **application** module, not the root project or a library module.

The release artefacts are hosted in this public Git repository. No Maven Central, GitHub Packages or paid registry is required. This repository also retains a Maven-layout copy for teams that prefer their own repository configuration.

## iOS — add the Swift package

1. In Xcode: File → Add Package Dependencies.
2. Add `https://github.com/GKObakhidze/E2E-Studio-SDK.git` and select version **0.2.0**.
3. Link the **E2EStudioSDK** product to the test app target. Build Debug for iOS Simulator.

That completes application integration: no SDK import, startup call, AppDelegate/SwiftUI App edit or Info.plist flag is needed. The linked package schedules automatic startup on the main queue and requires Studio's session environment. The existing `startIfRequested()` API remains compatible with older explicit integrations and will not start a second server.

This preview supports iOS Simulator. SwiftUI/WebView UI and iOS gestures continue with System Driver in Auto mode; automatic startup does not change operation coverage. SDK startup is compiled out in Release. To omit SDK code entirely from production, leave the product out of the production app target (use a separate SDK-enabled test target).

## Verify in Studio

Set the app's package/bundle identifier in Applications, leave **Auto — In-app SDK preferred**, and launch the app from a scenario or Inspector. Observe the actual driver and reason; choosing Auto alone does not prove SDK use. Missing SDK or unsupported operations automatically use System Driver. SDK-only is available for diagnostics and explicitly fails for unsupported actions.

Supported SDK operations: native Android Views/UIKit hierarchy and input; Android native taps. Unsupported UI/gestures/system prompts use the existing platform driver. `handleSystemPrompts()` can dismiss recognized password suggestions during a scenario; permission decisions remain explicit.

Listeners bind loopback and require a per-session credential. A normal launch without the session environment opens no SDK listener. Use SDK-enabled builds for development/QA; omit the dependency from production distributions.

## Offline alternative

Studio can export a local Swift package and Android AAR. For an entirely offline Android integration, put the exported AAR in the app's `libs` directory and add:

```kotlin
debugImplementation(files("libs/e2e-studio-sdk-0.2.0.aar"))
```

Choose either the setup plugin or a manual dependency; do not add both. SDK source is MIT-licensed, and operation is local between Studio and the device. No subscription or runtime cloud service is involved.
