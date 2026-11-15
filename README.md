# E2E Studio SDK · 0.1.0 preview

In-app automation for **debug/test builds**. Use the native dependency manager; no screen-by-screen instrumentation is required. Studio's **Auto** mode uses supported SDK operations and continues with System Driver when needed.

One **private repository** contains both platform SDKs, with a shared version tag. Your GitHub account needs read access to `GKObakhidze/E2E-Studio-SDK`. Install a published version rather than following a moving branch.

## Android

Add these imports at the top of `settings.gradle.kts`:

```kotlin
import org.gradle.api.credentials.HttpHeaderCredentials
import org.gradle.authentication.http.HttpHeaderAuthentication
```

Add the private, versioned repository to `dependencyResolutionManagement.repositories` (keep the project's existing repositories):

```kotlin
maven {
    name = "E2EStudioSDK"
    url = uri("https://raw.githubusercontent.com/GKObakhidze/E2E-Studio-SDK/v0.1.0/maven")
    content { includeGroup("io.github.gkobakhidze") }
    credentials(HttpHeaderCredentials::class) {
        name = "Authorization"
        value = providers.environmentVariable("E2E_SDK_GITHUB_TOKEN")
            .orElse(providers.gradleProperty("e2eSdkGithubToken"))
            .orNull?.let { "Bearer $it" }
    }
    authentication { create<HttpHeaderAuthentication>("header") }
}
```

Then add one dependency in the app module:

```kotlin
debugImplementation("io.github.gkobakhidze:e2e-studio-sdk:0.1.0")
```

Supply your GitHub credential through `E2E_SDK_GITHUB_TOKEN`, or `e2eSdkGithubToken` in your user-level `~/.gradle/gradle.properties`. Do not put credentials in the project or repository. A fine-grained token needs **Contents: Read** for this repository; an existing GitHub CLI login with private repository access also works:

```sh
E2E_SDK_GITHUB_TOKEN="$(gh auth token)" ./gradlew :app:assembleDebug
```

This repository serves the Maven files directly; it does **not** use GitHub Packages and does not require `read:packages`. Update both the URL tag and the dependency version together when upgrading.

Build/install Debug as usual. Startup is automatic; do not add Application or Activity hooks. Custom test build types can use their own equivalent of `debugImplementation`. Omit this dependency from production configurations. No listener starts without Studio's session launch arguments.

## iOS

In Xcode, sign in with a GitHub account that can read the private repository. Add `https://github.com/GKObakhidze/E2E-Studio-SDK.git` as a package dependency, select **Exact Version: 0.1.0** for reproducible preview integration and link the **E2EStudioSDK** product to your test app target. SwiftPM's package manifest is at the repository root; no separate iOS repository is needed. Add the following to the existing AppDelegate:

```swift
#if DEBUG
import E2EStudioSDK
#endif

// In application(_:didFinishLaunchingWithOptions:):
#if DEBUG
E2EStudioSDK.startIfRequested()
#endif
```

For a SwiftUI app, place the same guarded call in the existing `App.init()` instead. No UI changes are required. SwiftUI operations currently use System Driver; adding the startup call does not make SwiftUI an SDK-supported UI.

Build/install Debug for **iOS Simulator**. The server startup is guarded by `DEBUG` and requires Studio's session environment. SwiftPM links products to Xcode targets; guarded calls alone do not remove a linked package from Release. For strict production exclusion, use a separate test app target and omit the SDK product from the production target.

## Verify in Studio

1. Set the test app's Android package/iOS bundle identifier in Applications.
2. Keep **Auto — In-app SDK preferred** and run a scenario that launches the app.
3. Inspect the actual driver and reason in Inspector / Run results. **In-app SDK only** is available for focused SDK diagnostics.

The preview supports native Android Views and UIKit hierarchy/input. iOS gestures and unsupported UI/actions use System Driver in Auto. SDK-only intentionally fails for unsupported operations. System alerts still require the system driver; use `handleSystemPrompts()` to dismiss recognized password suggestions during a scenario, with explicit `permissions = "allow"` or `"deny"` when desired.

SDK listeners bind loopback and require a fresh Studio session credential. This is a development tool, not an end-user application dependency.
