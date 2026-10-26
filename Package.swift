// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dyndns-client",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "dyndns-client", targets: ["DynDNSClient"])],
    targets: [
        .executableTarget(name: "DynDNSClient"),
        .testTarget(name: "DynDNSClientTests", dependencies: ["DynDNSClient"]),
    ]
)
