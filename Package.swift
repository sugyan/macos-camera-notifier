// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "camera-notifier",
  platforms: [
    .macOS(.v10_15)
  ],
  products: [
    .executable(
      name: "camera-notifier",
      targets: ["camera-notifier"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0")
  ],
  targets: [
    .executableTarget(
      name: "camera-notifier",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      path: "Sources"
    )
  ]
)
