import Foundation

public enum SessionDiscovery {
    /// Directories that hold Claude-internal transcripts we never want to surface as sessions.
    private static let skippedDirectoryNames: Set<String> = ["subagents", "memory"]

    /// Recursively finds `*.jsonl` files under `root` with mtime ≥ `cutoff`. `maxDepth` is the
    /// deepest allowed file depth in path components below `root` (Claude `<dir>/<uuid>.jsonl` = 2,
    /// Codex `YYYY/MM/DD/x.jsonl` = 4); deeper subtrees are pruned, as are hidden entries and
    /// directories named "subagents" or "memory". Results are sorted by path for determinism.
    public static func recentSessionFiles(root: URL, modifiedAfter cutoff: Date, maxDepth: Int) -> [URL] {
        let base = root.standardizedFileURL
        let rootDepth = base.pathComponents.count
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let depth = item.standardizedFileURL.pathComponents.count - rootDepth
            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true {
                if skippedDirectoryNames.contains(item.lastPathComponent) || depth >= maxDepth {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  depth <= maxDepth,
                  item.pathExtension == "jsonl",
                  let modified = values.contentModificationDate,
                  modified >= cutoff
            else { continue }
            results.append(item)
        }
        return results.sorted { $0.path < $1.path }
    }
}
