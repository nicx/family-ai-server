// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FamilyAIServer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-auth.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/webauthn-swift.git", from: "1.0.0-beta.1"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "FamilyAICore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdBcrypt", package: "hummingbird-auth"),
                .product(name: "WebAuthn", package: "webauthn-swift"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            path: "Sources/FamilyAICore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "FamilyAIServer",
            dependencies: ["FamilyAICore"],
            path: "Sources/FamilyAIServer"
        ),
        // Self-contained checks: `swift run FamilyAIChecks` (XCTest/Testing macros are not
        // available with the Command Line Tools alone).
        .executableTarget(
            name: "FamilyAIChecks",
            dependencies: ["FamilyAICore"],
            path: "Tests/FamilyAIChecks"
        ),
    ],
    swiftLanguageModes: [.v5]
)
