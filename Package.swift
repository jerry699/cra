// swift-tools-version:5.10
import PackageDescription

// CEF (Chromium Embedded Framework) lives in vendor/cef, fetched by
// scripts/fetch-cef.sh, with its C++ wrapper built by CMake into
// vendor/cef/build/libcef_dll_wrapper. A build for the other CPU (scripts/build.sh with
// CRA_ARCH) points CRA_CEF_DIR at that CPU's copy, vendor/cef-<arch>.
let cefRoot = Context.environment["CRA_CEF_DIR"] ?? "\(Context.packageDirectory)/vendor/cef"

// Same flags CEF uses for its own wrapper (vendor/cef/cmake/cef_variables.cmake),
// so the ABI of the wrapper classes matches.
let cefCXXFlags: [String] = [
    "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics",
    "-fobjc-call-cxx-cdtors", "-fno-strict-aliasing",
    "-Wno-unused-parameter", "-Wno-deprecated-declarations",
    "-I", cefRoot,
]

let cefLinkerFlags: [String] = [
    "-L\(cefRoot)/build/libcef_dll_wrapper",
]

// Cra builds on Chrome's own framework (docs/chromium-engine.md; CRA_ENGINE=cef builds on CEF instead): CraCEF is
// then only its header, implemented inside the framework, which CRA_ENGINE_FRAMEWORKS holds (vendor/engine from
// scripts/fetch-engine.sh by default, or the Cra.app/Contents/Frameworks of a scripts/build-chromium.sh build).
// No CraHelper: Chrome's own helpers come with the framework.
let chromiumEngine = Context.environment["CRA_ENGINE"] != "cef"
let engineFrameworks = Context.environment["CRA_ENGINE_FRAMEWORKS"] ?? "\(Context.packageDirectory)/vendor/engine"

// Sparkle, the updater framework Arc ships, lives in vendor/sparkle (scripts/fetch-sparkle.sh);
// scripts/build.sh copies Sparkle.framework into Cra.app/Contents/Frameworks.
let sparkleRoot = "\(Context.packageDirectory)/vendor/sparkle"

// llama.cpp's static libraries, built for the host CPU (x86_64 + AVX2/FMA on Intel) by
// scripts/build-llama.sh with the same macOS 14 deployment target as the app (Accelerate,
// Metal off): the local model process. scripts/build.sh puts the helper in
// Cra.app/Contents/MacOS.
let llamaRoot = "\(Context.packageDirectory)/vendor/llama.cpp"
let llamaBuild = Context.environment["CRA_LLAMA_BUILD"] ?? "\(llamaRoot)/build"

// whisper.cpp's static libraries, built for the host CPU by scripts/build-whisper.sh
// (Accelerate for BLAS, Metal off): the transcription process. Same layout as llama's.
let whisperRoot = "\(Context.packageDirectory)/vendor/whisper.cpp"
let whisperBuild = Context.environment["CRA_WHISPER_BUILD"] ?? "\(whisperRoot)/build"

// P3-R2 本地补丁: the products/targets conditional concatenation broke Swift 6.2's
// type-checker on Intel (multi-platform manifest, 346-commit upstream sync) — hoisted
// into statements. The engine targets are decided here, the rest appended below.
var craTargets: [Target] = [
    .executableTarget(name: "CraPluginHost", path: "Sources/CraPluginHost",
                      linkerSettings: [.linkedFramework("JavaScriptCore")]),
    // Local model process: llama.cpp's static libraries, no network, exits when idle.
    .executableTarget(
        name: "CraInferenceHelper",
        path: "Sources/CraInferenceHelper",
        cxxSettings: [.unsafeFlags([
            "-I", "\(llamaRoot)/include",
            "-I", "\(llamaRoot)/ggml/include",
            "-O2",
        ])],
        linkerSettings: [
            .unsafeFlags([
                // Explicit .a paths: the linker reads "-llama" as -l + "lama".
                "\(llamaBuild)/src/libllama.a",
                "\(llamaBuild)/ggml/src/libggml.a",
                "\(llamaBuild)/ggml/src/libggml-cpu.a",
                "\(llamaBuild)/ggml/src/ggml-blas/libggml-blas.a",
                "\(llamaBuild)/ggml/src/libggml-base.a",
                "-framework", "Accelerate", "-framework", "Foundation",
            ]),
            .linkedLibrary("c++"),
        ]
    ),
    // Transcription process: whisper.cpp's static libraries, no network, one-shot.
    .executableTarget(
        name: "CraWhisper",
        path: "Sources/CraWhisper",
        cxxSettings: [.unsafeFlags([
            "-I", "\(whisperRoot)/include",
            "-O2",
        ])],
        linkerSettings: [
            .unsafeFlags([
                "\(whisperBuild)/src/libwhisper.a",
                "\(whisperBuild)/ggml/src/libggml.a",
                "\(whisperBuild)/ggml/src/libggml-base.a",
                "\(whisperBuild)/ggml/src/libggml-cpu.a",
                "\(whisperBuild)/ggml/src/ggml-blas/libggml-blas.a",
                "-framework", "Accelerate", "-framework", "Foundation",
            ]),
            .linkedLibrary("c++"),
        ]
    ),
]

if chromiumEngine {
    // The bridge lives in Chrome's framework (engine/chromium/cra/bridge.mm); this target is its header.
    craTargets.append(.target(
        name: "CraCEF",
        path: "Sources/CraCEF",
        exclude: ["CraCEF.mm", "CraContentBlocker.h"],
        sources: ["ChromiumEngine.m"],
        publicHeadersPath: "include",
        linkerSettings: [
            .unsafeFlags(["-F", engineFrameworks, "-Xlinker", "-needed_framework", "-Xlinker", "Cra Framework"]),
            .linkedFramework("AppKit"),
        ]
    ))
} else {
    // Objective-C++ bridge between Swift and CEF.
    craTargets.append(.target(
        name: "CraCEF",
        path: "Sources/CraCEF",
        exclude: ["ChromiumEngine.m"],
        publicHeadersPath: "include",
        cxxSettings: [.unsafeFlags(cefCXXFlags + ["-fobjc-arc"])],
        linkerSettings: [
            // Cra links the framework at launch, like the helpers (Sources/CraHelper/main.cc).
            .unsafeFlags(cefLinkerFlags + ["-F", "\(cefRoot)/Release", "-Xlinker", "-needed_framework",
                                           "-Xlinker", "Chromium Embedded Framework"]),
            .linkedLibrary("cef_dll_wrapper"),
            .linkedFramework("AppKit"),
            .linkedFramework("IOSurface"),
        ]
    ))
    // Subprocess executable (renderer, GPU, utility...). Bundled five
    // times as "Cra Helper*.app" inside Cra.app/Contents/Frameworks.
    craTargets.append(.executableTarget(
        name: "CraHelper",
        path: "Sources/CraHelper",
        exclude: ["ChromiumEmbeddedFramework.tbd"],
        cxxSettings: [.unsafeFlags(cefCXXFlags)],
        linkerSettings: [
            // The framework is a launch-time dependency, not a dlopen (main.cc says why).
            .unsafeFlags(cefLinkerFlags + ["-Xlinker", "-needed_library", "-Xlinker",
                "\(Context.packageDirectory)/Sources/CraHelper/ChromiumEmbeddedFramework.tbd"]),
            .linkedLibrary("cef_dll_wrapper"),
            .linkedFramework("AppKit"),
            .linkedFramework("IOSurface"),
        ]
    ))
}

// Products, built from the target decisions above.
var craProducts: [Product] = [
    .executable(name: "Cra", targets: ["Cra"]),
]
if !chromiumEngine {
    craProducts.append(.executable(name: "CraHelper", targets: ["CraHelper"]))
}
craProducts += [
    .executable(name: "CraPluginHost", targets: ["CraPluginHost"]),
    // Started by Cra for Tidy Tab Titles on a Mac without Apple Intelligence.
    .executable(name: "CraInferenceHelper", targets: ["CraInferenceHelper"]),
    // Started by Cra for transcription of downloaded audio/video.
    .executable(name: "CraWhisper", targets: ["CraWhisper"]),
    // Loaded by the Dock, not by Cra; scripts/build.sh wraps it in
    // Cra.app/Contents/PlugIns/CraDockTile.docktileplugin.
    .library(name: "CraDockTile", type: .dynamic, targets: ["CraDockTile"]),
]

// Dock tile plug-in: keeps the icon picked in Settings after Cra quits.
craTargets.append(.target(
    name: "CraDockTile",
    path: "Sources/CraDockTile",
    linkerSettings: [.linkedFramework("AppKit")]
))
// The browser itself: AppKit window, SwiftUI sidebar and command bar.
craTargets.append(.executableTarget(
    name: "Cra",
    dependencies: ["CraCEF", .product(name: "CraCore", package: "CraCore")],
    path: "Sources/Cra",
    swiftSettings: [.unsafeFlags(["-F", sparkleRoot]), .unsafeFlags(["-Onone"], .when(configuration: .debug))],
    linkerSettings: [.unsafeFlags(["-F", sparkleRoot, "-framework", "Sparkle",
                                   "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
))

let package = Package(
    name: "Cra",
    platforms: [.macOS(.v14)],
    products: craProducts,
    // Models and decisions that need no AppKit or CEF, with tests that run without vendor/cef.
    dependencies: [.package(path: "Packages/CraCore")],
    targets: craTargets,
    swiftLanguageVersions: [.v5],
    cxxLanguageStandard: .cxx20
)
