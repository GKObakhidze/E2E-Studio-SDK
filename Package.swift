// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "E2EStudioSDK", platforms: [.iOS(.v15)],
    products: [.library(name: "E2EStudioSDK", targets: ["E2EStudioSDK"])],
    targets: [.target(name: "E2EStudioSDK", dependencies: ["E2EStudioBootstrap"]),
              .target(name: "E2EStudioBootstrap", publicHeadersPath: "include")])
