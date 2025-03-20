// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacOS-hello",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MacOS-hello",
            path: "src"
        )
    ]
)
