// swift-tools-version:6.0
import Foundation
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]
// The test runner is a plain executable; embedding Info.plist gives it the app's document types.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "QuickMark",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "QuickMarkKit", swiftSettings: swift5),
        .executableTarget(name: "QuickMark", dependencies: ["QuickMarkKit"], swiftSettings: swift5),
        // `swift run QuickMarkTests`. An executable rather than a test target, because the
        // Command Line Tools ship neither XCTest nor a loadable Swift Testing.
        .executableTarget(
            name: "QuickMarkTests", dependencies: ["QuickMarkKit"], path: "Tests/QuickMarkTests",
            swiftSettings: swift5,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]),
    ]
)
