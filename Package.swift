// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnyKeyMic",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "anykey-mic", targets: ["AnyKeyMic"])],
    targets: [
        .target(name: "MicCore"),
        .target(name: "CNative", sources: ["native.c", "hid_backend.c", "process.c", "service_windows.c", "keyinject.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("vendor/hidapi/hidapi")],
            linkerSettings: [
                .linkedLibrary("setupapi", .when(platforms: [.windows])),
                .linkedLibrary("hid", .when(platforms: [.windows])),
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                .linkedLibrary("user32", .when(platforms: [.windows])),
                .linkedLibrary("advapi32", .when(platforms: [.windows])),
                .linkedLibrary("shell32", .when(platforms: [.windows])),
                .linkedLibrary("uuid", .when(platforms: [.windows])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.macOS])),
                .linkedFramework("ApplicationServices", .when(platforms: [.macOS]))
            ]),
        .executableTarget(name: "AnyKeyMic", dependencies: ["MicCore", "CNative"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                                          .when(platforms: [.windows]))]),
        .testTarget(name: "MicCoreTests", dependencies: ["MicCore"])
    ],
    swiftLanguageModes: [.v5],
    cLanguageStandard: .c11
)
