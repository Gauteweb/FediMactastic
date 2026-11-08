// swift-tools-version:5.10
import PackageDescription

// FediMactastic: macOS-utgaven av Feditastic. Bygges med ./build-app.sh (krever bare Command Line Tools).
let package = Package(
    name: "FediMactastic",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FediMactastic",
            path: "Sources/FediMactastic"
        ),
    ]
)
