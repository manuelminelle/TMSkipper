import Foundation

/// A regenerable folder and the sentinel files that prove it is generated.
///
/// The folder is excluded only when at least one sentinel matches in the directory
/// that contains it (the "base" directory).
public struct Rule: Codable, Sendable, Equatable {
    /// Unique identifier. Used in the config file and stored on excluded folders.
    public var id: String
    /// Folder to exclude, relative to the base directory. May contain "/" (e.g. ".vercel/output").
    public var folder: String
    /// Sentinels, relative to the base directory. Supported forms:
    /// - `package.json`: the file or folder exists;
    /// - `next.config.*`: a "*" wildcard, matched against the base directory's entries;
    /// - `.vercel/project.json`: a nested path;
    /// - `package.json#next`: a package.json that declares the dependency "next".
    public var sentinels: [String]
    /// Human-readable ecosystem name, shown by `tmskipper rules`.
    public var ecosystem: String

    public init(id: String, folder: String, sentinels: [String], ecosystem: String) {
        self.id = id
        self.folder = folder
        self.sentinels = sentinels
        self.ecosystem = ecosystem
    }

    /// Path components of `folder`.
    public var folderComponents: [String] {
        folder.split(separator: "/").map(String.init)
    }

    /// Returns a description of what is wrong with the rule, or nil if it is valid.
    public func validationError() -> String? {
        if id.isEmpty || id == Rule.guardedMarker || id == Rule.cacheDirTagID {
            return "invalid or reserved id \"\(id)\""
        }
        let components = folderComponents
        if folder.hasPrefix("/") || components.isEmpty {
            return "rule \(id): folder must be a relative path"
        }
        if components.contains(where: { $0 == "." || $0 == ".." || $0 == ".git" || $0.contains("*") }) {
            return "rule \(id): folder must not contain \".\", \"..\", \".git\" or wildcards"
        }
        if sentinels.isEmpty || sentinels.contains(where: \.isEmpty) {
            return "rule \(id): at least one non-empty sentinel is required"
        }
        return nil
    }
}

extension Rule {
    /// Id of the built-in rule for folders tagged with a valid CACHEDIR.TAG.
    public static let cacheDirTagID = "cachedir-tag"
    /// Marker stored on guarded global paths.
    public static let guardedMarker = "guarded"

    /// Default rules. Each one needs a sentinel that only the generating tool creates.
    public static let defaults: [Rule] = [
        // JavaScript / TypeScript
        Rule(id: "node-modules", folder: "node_modules", sentinels: ["package.json"], ecosystem: "Node.js"),
        Rule(id: "next", folder: ".next", sentinels: ["next.config.*", "package.json#next"], ecosystem: "Next.js"),
        Rule(id: "next-export", folder: "out", sentinels: ["next.config.*"], ecosystem: "Next.js static export"),
        Rule(id: "nuxt", folder: ".nuxt", sentinels: ["nuxt.config.*"], ecosystem: "Nuxt"),
        Rule(id: "nuxt-output", folder: ".output", sentinels: ["nuxt.config.*"], ecosystem: "Nuxt"),
        Rule(id: "astro", folder: ".astro", sentinels: ["astro.config.*"], ecosystem: "Astro"),
        Rule(id: "astro-dist", folder: "dist", sentinels: ["astro.config.*"], ecosystem: "Astro"),
        Rule(id: "svelte-kit", folder: ".svelte-kit", sentinels: ["svelte.config.*"], ecosystem: "SvelteKit"),
        Rule(id: "angular-cache", folder: ".angular", sentinels: ["angular.json"], ecosystem: "Angular"),
        Rule(id: "turbo", folder: ".turbo", sentinels: ["turbo.json", "package.json"], ecosystem: "Turborepo"),
        Rule(id: "parcel-cache", folder: ".parcel-cache", sentinels: ["package.json"], ecosystem: "Parcel"),
        Rule(id: "expo", folder: ".expo", sentinels: ["app.json", "app.config.*"], ecosystem: "Expo"),
        Rule(id: "js-coverage", folder: "coverage", sentinels: ["package.json"], ecosystem: "JavaScript test coverage"),
        Rule(id: "wrangler", folder: ".wrangler", sentinels: ["wrangler.toml", "wrangler.json", "wrangler.jsonc"], ecosystem: "Cloudflare Workers"),
        Rule(id: "vercel-output", folder: ".vercel/output", sentinels: ["vercel.json", ".vercel/project.json"], ecosystem: "Vercel"),
        Rule(id: "supabase-temp", folder: "supabase/.temp", sentinels: ["supabase/config.toml"], ecosystem: "Supabase"),
        Rule(id: "supabase-branches", folder: "supabase/.branches", sentinels: ["supabase/config.toml"], ecosystem: "Supabase"),

        // Apple
        Rule(id: "swiftpm-build", folder: ".build", sentinels: ["Package.swift"], ecosystem: "Swift Package Manager"),
        Rule(id: "xcode-derived-data", folder: "DerivedData", sentinels: ["*.xcodeproj", "*.xcworkspace", "Package.swift"], ecosystem: "Xcode"),
        Rule(id: "cocoapods", folder: "Pods", sentinels: ["Podfile"], ecosystem: "CocoaPods"),
        Rule(id: "carthage-build", folder: "Carthage/Build", sentinels: ["Cartfile"], ecosystem: "Carthage"),

        // Android / JVM
        Rule(id: "gradle-build", folder: "build", sentinels: ["build.gradle", "build.gradle.kts"], ecosystem: "Gradle"),
        Rule(id: "gradle-cache", folder: ".gradle", sentinels: ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts", "gradlew"], ecosystem: "Gradle"),
        Rule(id: "gradle-user-home", folder: ".gradle-user", sentinels: ["gradlew"], ecosystem: "Gradle"),
        Rule(id: "kotlin", folder: ".kotlin", sentinels: ["settings.gradle*", "build.gradle*"], ecosystem: "Kotlin"),
        Rule(id: "android-cxx", folder: ".cxx", sentinels: ["build.gradle", "build.gradle.kts"], ecosystem: "Android NDK"),
        Rule(id: "maven-target", folder: "target", sentinels: ["pom.xml"], ecosystem: "Maven"),

        // Rust
        Rule(id: "cargo-target", folder: "target", sentinels: ["Cargo.toml"], ecosystem: "Rust"),

        // Python
        Rule(id: "python-venv", folder: ".venv", sentinels: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock"], ecosystem: "Python"),
        Rule(id: "python-venv-plain", folder: "venv", sentinels: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock"], ecosystem: "Python"),
        Rule(id: "python-pycache", folder: "__pycache__", sentinels: ["*.py"], ecosystem: "Python"),
        Rule(id: "python-tox", folder: ".tox", sentinels: ["tox.ini"], ecosystem: "Python"),

        // Dart / Flutter
        Rule(id: "dart-tool", folder: ".dart_tool", sentinels: ["pubspec.yaml"], ecosystem: "Dart / Flutter"),
        Rule(id: "flutter-build", folder: "build", sentinels: ["pubspec.yaml"], ecosystem: "Flutter"),

        // .NET
        Rule(id: "dotnet-bin", folder: "bin", sentinels: ["*.csproj", "*.fsproj", "*.vbproj"], ecosystem: ".NET"),
        Rule(id: "dotnet-obj", folder: "obj", sentinels: ["*.csproj", "*.fsproj", "*.vbproj"], ecosystem: ".NET"),

        // Other languages
        Rule(id: "elixir-build", folder: "_build", sentinels: ["mix.exs"], ecosystem: "Elixir"),
        Rule(id: "elixir-deps", folder: "deps", sentinels: ["mix.exs"], ecosystem: "Elixir"),
        Rule(id: "zig-cache", folder: ".zig-cache", sentinels: ["build.zig"], ecosystem: "Zig"),
        Rule(id: "zig-out", folder: "zig-out", sentinels: ["build.zig"], ecosystem: "Zig"),
        Rule(id: "haskell-stack", folder: ".stack-work", sentinels: ["stack.yaml"], ecosystem: "Haskell"),
        Rule(id: "haskell-cabal", folder: "dist-newstyle", sentinels: ["cabal.project", "*.cabal"], ecosystem: "Haskell"),
        Rule(id: "terraform", folder: ".terraform", sentinels: ["*.tf"], ecosystem: "Terraform"),
    ]
}
