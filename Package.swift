// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pesty-Alvie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pesty-Alvie", targets: ["Pesty"])
    ],
    targets: [
        .executableTarget(
            name: "Pesty",
            path: "Sources/Pesty",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "PestyTests",
            dependencies: ["Pesty"],
            path: "Tests/PestyTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
