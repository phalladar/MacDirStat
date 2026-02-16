enum FileExtensionMap {
    static func category(for extension: String) -> FileCategory {
        extensionMap[`extension`.lowercased()] ?? .other
    }

    private static let extensionMap: [String: FileCategory] = {
        var map = [String: FileCategory]()

        let documents = [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            "txt", "rtf", "csv", "pages", "numbers", "key",
            "odt", "ods", "odp", "epub", "md", "markdown",
            "tex", "log", "nfo", "readme"
        ]

        let images = [
            "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif",
            "svg", "webp", "ico", "icns", "heic", "heif",
            "raw", "cr2", "nef", "arw", "dng", "psd", "ai",
            "sketch", "fig", "xcf"
        ]

        let video = [
            "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm",
            "m4v", "mpg", "mpeg", "3gp", "ts", "vob", "ogv"
        ]

        let audio = [
            "mp3", "wav", "aac", "flac", "ogg", "wma", "m4a",
            "aiff", "aif", "opus", "alac", "mid", "midi"
        ]

        let code = [
            "swift", "h", "m", "mm", "c", "cpp", "cc", "cxx",
            "py", "js", "ts", "jsx", "tsx", "html", "css", "scss",
            "java", "kt", "go", "rs", "rb", "php", "sh", "zsh",
            "bash", "json", "xml", "yaml", "yml", "toml",
            "sql", "r", "lua", "pl", "pm", "dart", "vue",
            "svelte", "zig", "nim", "ex", "exs", "erl",
            "hs", "ml", "fs", "clj", "scala", "groovy",
            "makefile", "cmake", "dockerfile",
            "gitignore", "gitattributes", "editorconfig",
            "xcodeproj", "xcworkspace", "pbxproj", "storyboard", "xib"
        ]

        let archives = [
            "zip", "tar", "gz", "bz2", "xz", "7z", "rar",
            "dmg", "iso", "pkg", "deb", "rpm", "jar", "war",
            "tgz", "tbz2", "lz", "lzma", "zst", "cab", "sit"
        ]

        let applications = [
            "app", "exe", "msi", "apk", "ipa",
            "dylib", "so", "dll", "framework",
            "bundle", "kext", "plugin", "wasm"
        ]

        let system = [
            "plist", "entitlements", "mobileprovision",
            "cer", "p12", "keychain", "lock",
            "ds_store", "localized", "strings"
        ]

        let caches = [
            "cache", "tmp", "temp", "swp", "swo",
            "o", "obj", "pyc", "pyo", "class",
            "dSYM", "ipa", "xcarchive"
        ]

        for ext in documents { map[ext] = .documents }
        for ext in images { map[ext] = .images }
        for ext in video { map[ext] = .video }
        for ext in audio { map[ext] = .audio }
        for ext in code { map[ext] = .code }
        for ext in archives { map[ext] = .archives }
        for ext in applications { map[ext] = .applications }
        for ext in system { map[ext] = .system }
        for ext in caches { map[ext] = .caches }

        return map
    }()
}
