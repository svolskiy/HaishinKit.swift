// swift-tools-version:6.0
import PackageDescription

// A macOS demo app for the shared-encoder pipeline (MediaEncoder -> N RTMPStreams).
// Run from this directory with `swift run`, or open Package.swift in Xcode.
let package = Package(
    name: "MultiStreamDemo",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "MultiStreamDemo",
            // By-name dependencies resolve to the products of the parent package whatever its folder is called.
            dependencies: [
                "HaishinKit",
                "RTMPHaishinKit"
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ],
            linkerSettings: [
                // Embeds Info.plist (camera/microphone usage descriptions) into the unbundled executable,
                // otherwise macOS refuses to prompt for camera access.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Info.plist"
                ])
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
