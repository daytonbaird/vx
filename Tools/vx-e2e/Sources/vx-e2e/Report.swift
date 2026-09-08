import Foundation

/// Turns a run's results into a console table, `report.md`, and `summary.json`.
///
/// The JSON exists so CI (or `verify.sh`) can key off the run without scraping the
/// markdown; the markdown exists so a human opening the artifact dir sees what
/// happened without running anything.
enum Report {
    static func console(_ results: [ScenarioResult], outDir: URL, totalDuration: TimeInterval) -> String {
        var lines: [String] = []
        let nameWidth = max(12, results.map(\.name.count).max() ?? 12)
        lines.append("")
        lines.append("  " + "SCENARIO".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  STATUS   TIME")
        lines.append("  " + String(repeating: "-", count: nameWidth + 17))
        for result in results {
            let name = result.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let status = result.status.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
            let time = String(format: "%6.1fs", result.duration)
            lines.append("  \(name)  \(status) \(time)")
            if result.status != .passed, !result.message.isEmpty {
                for messageLine in result.message.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("      \(messageLine)")
                }
            }
        }
        let passed = results.filter { $0.status == .passed }.count
        let failed = results.filter { $0.status == .failed }.count
        let skipped = results.filter { $0.status == .skipped }.count
        lines.append("")
        lines.append(String(format: "  %d passed, %d failed, %d skipped in %.1fs", passed, failed, skipped, totalDuration))
        lines.append("  artifacts: \(outDir.path)")
        return lines.joined(separator: "\n")
    }

    static func markdown(_ results: [ScenarioResult], outDir: URL, totalDuration: TimeInterval) -> String {
        var lines = ["# vx-e2e run", ""]
        lines.append("- Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append(String(format: "- Duration: %.1fs", totalDuration))
        lines.append("- Artifacts: `\(outDir.path)`")
        lines.append("")
        lines.append("| Scenario | Status | Time |")
        lines.append("|---|---|---|")
        for result in results {
            lines.append("| `\(result.name)` | \(result.status.rawValue) | \(String(format: "%.1fs", result.duration)) |")
        }
        lines.append("")
        for result in results where result.status != .passed || !result.artifacts.isEmpty {
            lines.append("## \(result.name) — \(result.status.rawValue)")
            lines.append("")
            if !result.message.isEmpty {
                lines.append("```")
                lines.append(result.message)
                lines.append("```")
                lines.append("")
            }
            if !result.artifacts.isEmpty {
                lines.append("Artifacts:")
                for artifact in result.artifacts {
                    let relative = artifact.path.hasPrefix(outDir.path)
                        ? String(artifact.path.dropFirst(outDir.path.count + 1))
                        : artifact.path
                    lines.append("- [\(relative)](\(relative))")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func summaryJSON(_ results: [ScenarioResult], totalDuration: TimeInterval) -> String {
        let payload: [String: Any] = [
            "totalDuration": totalDuration,
            "passed": results.filter { $0.status == .passed }.count,
            "failed": results.filter { $0.status == .failed }.count,
            "skipped": results.filter { $0.status == .skipped }.count,
            "scenarios": results.map { result in
                [
                    "name": result.name,
                    "status": result.status.rawValue,
                    "duration": result.duration,
                    "message": result.message,
                    "artifacts": result.artifacts.map(\.path)
                ] as [String: Any]
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func write(_ results: [ScenarioResult], outDir: URL, totalDuration: TimeInterval) -> [URL] {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let md = outDir.appendingPathComponent("report.md")
        let json = outDir.appendingPathComponent("summary.json")
        try? markdown(results, outDir: outDir, totalDuration: totalDuration).write(to: md, atomically: true, encoding: .utf8)
        try? summaryJSON(results, totalDuration: totalDuration).write(to: json, atomically: true, encoding: .utf8)
        return [md, json]
    }
}
