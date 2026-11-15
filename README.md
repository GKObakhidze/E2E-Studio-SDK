# E2E Studio SDK · 0.2.0 preview

SDK integration for debug/test applications. Android and iOS share this public repository, version and protocol. Licensed under MIT.

## Android — one dependency

In the app module's `build.gradle.kts`:

```kotlin
debugImplementation("io.github.gkobakhidze:e2e-studio-sdk:0.2.0")
```

Standard Android projects already use `mavenCentral()`. If your project uses a custom repository configuration, include Maven Central in its dependency repositories. No Gradle plugin, GitHub credential, Application hook or Activity change is required. Custom QA build types can use the corresponding dependency configuration instead of Debug.

Build and install Debug, then launch it through E2E Studio. The manifest provider activates the SDK automatically, only in a debuggable application with Studio's session arguments.

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

## Offline and first-publication fallback

Studio can export a local Swift package and Android AAR. While a new Android version is waiting for Maven Central publication, the version-tagged GitHub Maven repository is also usable without credentials:

```kotlin
// settings.gradle.kts → dependencyResolutionManagement.repositories
maven {
    url = uri("https://raw.githubusercontent.com/GKObakhidze/E2E-Studio-SDK/v0.2.0/maven")
    content { includeGroup("io.github.gkobakhidze") }
}
```

The fallback is optional and requires that the version tag exists; it is not needed once the version is available in Maven Central. No user-level/global Gradle configuration is installed by Studio.
