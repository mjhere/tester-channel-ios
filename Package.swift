// swift-tools-version: 5.9
import PackageDescription

/// 1000 Fans — iOS client.
///
/// D15: open source, like the web client, because this is the file a customer's
/// mobile team reads before they agree to ship it.
///
/// No dependencies, on purpose. A feedback panel is not worth a dependency graph
/// in somebody else's app, and everything here is Foundation and SwiftUI.
let package = Package(
    name: "TesterChannel",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "TesterChannel", targets: ["TesterChannel"]),
    ],
    targets: [
        .target(name: "TesterChannel", path: "Sources/TesterChannel"),
    ]
)
