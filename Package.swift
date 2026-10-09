// swift-tools-version:5.10
import PackageDescription

// SCROLLINATOR_APPSTORE=1 builds the Mac App Store flavor: it records AAC (.m4a) with Apple's
// encoder, so it leaves out the LGPL LAME MP3 encoder. build.sh sets it for `./build.sh appstore`.
let appStore = Context.environment["SCROLLINATOR_APPSTORE"] == "1"

let package = Package(
    name: "Scrollinator",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Scrollinator",
            dependencies: appStore ? [] : ["CLame"],
            path: "Sources/Scrollinator"
        ),
        // The LAME MP3 encoder, built by scripts/build-lame.sh into vendor/lame (build.sh runs it).
        .target(
            name: "CLame",
            path: "Sources/CLame",
            linkerSettings: [
                .unsafeFlags(["-L", Context.packageDirectory + "/vendor/lame/lib"]),
                .linkedLibrary("mp3lame"),
            ]
        ),
    ]
)
