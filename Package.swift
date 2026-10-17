// swift-tools-version:5.10
import PackageDescription
import Foundation

// whisper.cpp is compiled to static libraries by scripts/build-whisper.sh.
// They live in vendor/lib and are linked straight into the app binary.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let whisperLibDir = "\(packageRoot)/vendor/lib"

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            linkerSettings: [
                .unsafeFlags(["-L\(whisperLibDir)"]),
                .linkedLibrary("whisper"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-metal"),
                .linkedLibrary("ggml-blas"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Catches Objective-C exceptions from Apple's audio frameworks (Swift can't).
        .target(
            name: "ObjCSafety",
            path: "Sources/ObjCSafety"
        ),
        // Pure logic with no AppKit/audio dependencies, so it can be tested headlessly.
        .target(
            name: "TranscriberCore",
            path: "Sources/TranscriberCore"
        ),
        .executableTarget(
            name: "Transcriber",
            dependencies: ["CWhisper", "TranscriberCore", "ObjCSafety"],
            path: "Sources/Transcriber"
        ),
        .executableTarget(
            name: "SelfTest",
            dependencies: ["TranscriberCore"],
            path: "Sources/SelfTest"
        ),
    ]
)
