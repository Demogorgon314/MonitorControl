// swift-tools-version: 5.5
import PackageDescription

let package = Package(
  name: "RemoteControlCorePackage",
  platforms: [
    .macOS(.v10_14),
  ],
  products: [
    .library(name: "RemoteControlCore", targets: ["RemoteControlCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio", .upToNextMinor(from: "2.40.0")),
  ],
  targets: [
    .target(
      name: "RemoteControlCore",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ],
      path: "MonitorControl/Support/RemoteControl",
      exclude: [
        "RemoteControlServer.swift",
        "RemoteControlTokenStore.swift",
        "RemoteDisplayController.swift",
      ],
      sources: [
        "RemoteAPIModels.swift",
        "RemoteAPIRequestParser.swift",
        "RemoteAPIRouter.swift",
        "RemoteInputSourceCatalog.swift",
        "RemoteNIORequestHandler.swift",
      ]
    ),
    .testTarget(
      name: "RemoteControlCoreTests",
      dependencies: [
        "RemoteControlCore",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOEmbedded", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      path: "MonitorControlTests/RemoteControl"
    ),
  ]
)
