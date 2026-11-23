// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowBatchStudio",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FlowBatchCore", targets: ["FlowBatchCore"]),
        .executable(name: "FlowBatchJSWorker", targets: ["FlowBatchJSWorker"]),
        .executable(name: "FlowBatchStudio", targets: ["FlowBatchStudio"])
    ],
    targets: [
        .target(
            name: "CZlib",
            path: "Sources/CZlib",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "FlowBatchCore",
            dependencies: ["CZlib"],
            path: "Sources/FlowBatchCore",
            linkerSettings: [
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Photos"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Metal"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "FlowBatchJSWorker",
            path: "Sources/FlowBatchJSWorker",
            linkerSettings: [
                .linkedFramework("JavaScriptCore")
            ]
        ),
        .executableTarget(
            name: "FlowBatchStudio",
            dependencies: ["FlowBatchCore"],
            path: "Sources/FlowBatchStudio",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreImage")
            ]
        ),
        .testTarget(
            name: "FlowBatchCoreTests",
            dependencies: ["FlowBatchCore"],
            path: "Tests/FlowBatchCoreTests"
        )
    ]
)
