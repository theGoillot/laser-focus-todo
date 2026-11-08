import Foundation

/// Workflowy-style inline tags (`#acme.io`, `#work`). Same rules as the backend's `tagsIn`.
public enum Tags {
    // A tag starts after a non-word char (or the start), then a letter/digit/_ and may contain . - / inside.
    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[^\p{L}\p{N}_#&/]))#([\p{L}\p{N}_][\p{L}\p{N}_.\-/]*)"#)

    /// Ranges of whole tags including the `#`, trailing punctuation excluded.
    public static func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var r = m.range
            while r.length > 1, ".-/".contains(ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1))) { r.length -= 1 }
            return r.length > 1 ? r : nil
        }
    }

    /// Lowercased, unique tags without the `#`, in order of appearance.
    public static func `in`(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        for r in ranges(in: text) {
            let t = ns.substring(with: NSRange(location: r.location + 1, length: r.length - 1)).lowercased()
            if !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// The tag being typed right before `caret` (UTF-16 offset), without the `#`; nil when the caret is not in a tag.
    public static func partial(in text: String, caret: Int) -> String? {
        let ns = text as NSString
        guard caret <= ns.length else { return nil }
        var i = caret
        while i > 0 {
            let ch = ns.substring(with: NSRange(location: i - 1, length: 1))
            if ch == "#" {
                if i - 1 > 0, let prev = ns.substring(with: NSRange(location: i - 2, length: 1)).unicodeScalars.first,
                   CharacterSet.alphanumerics.contains(prev) || prev == "_" { return nil }
                return ns.substring(with: NSRange(location: i, length: caret - i))
            }
            guard let u = ch.unicodeScalars.first, CharacterSet.alphanumerics.contains(u) || "_.-/".unicodeScalars.contains(u) else { return nil }
            i -= 1
        }
        return nil
    }
}
