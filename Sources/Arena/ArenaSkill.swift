import Foundation

/// The same bundled files serve both clients; installation preserves local edits.
enum ArenaSkill {
    private static func files() throws -> [String: Data] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        // resourceURL resolves both flat and structured bundles; bundleURL only found the flat one.
        guard let root = bundle.resourceURL?.appendingPathComponent("Resources/arena") else {
            throw ArenaError.invalid("Arena skill is missing from this build.")
        }
        return try Dictionary(uniqueKeysWithValues: ["SKILL.md", "agents/openai.yaml"].map {
            ($0, try Data(contentsOf: root.appendingPathComponent($0)))
        })
    }

    static func isInstalled(at directory: URL) throws -> Bool {
        var complete = true
        for (path, expected) in try files() {
            let file = directory.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: file.path) {
                guard try Data(contentsOf: file) == expected else {
                    throw ArenaError.invalid("Existing skill differs. Your files were preserved; review the skill folder before installing.")
                }
            } else { complete = false }
        }
        return complete
    }

    static func install(at directory: URL) throws {
        if try isInstalled(at: directory) { return }
        for (path, data) in try files() {
            let file = directory.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Refuse a file that appeared after the check rather than replacing it.
            try data.write(to: file, options: .withoutOverwriting)
        }
        guard try isInstalled(at: directory) else { throw ArenaError.invalid("Skill installation is incomplete. Try installing again.") }
    }
}
