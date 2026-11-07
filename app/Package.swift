// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "E900Control", platforms: [.macOS(.v13)], products: [.executable(name: "E900Control", targets: ["E900Control"])], targets: [.executableTarget(name: "E900Control"), .testTarget(name: "E900ControlTests", dependencies: ["E900Control"])])
