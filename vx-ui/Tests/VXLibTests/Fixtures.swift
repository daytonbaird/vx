import Foundation

/// Resolves the shared audio fixtures at `app/fixtures/audio/`. Located relative to this
/// source file rather than a bundle resource so the fixtures stay outside the Swift package.
enum Fixtures {
    /// `.../app/fixtures/audio/<name>.wav`
    static func url(_ name: String) -> URL {
        audioDirectory.appendingPathComponent("\(name).wav")
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    private static var audioDirectory: URL {
        // <app>/vx-ui/Tests/VXLibTests/Fixtures.swift -> <app>
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures/audio")
    }
}
