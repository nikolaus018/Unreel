import Foundation

struct CaptionTrack: Hashable, Identifiable, Codable {
    var id: String { lang + "|" + kind }
    let lang: String
    let kind: String     // "asr" for auto-generated
    let name: String
    var isAuto: Bool { kind == "asr" }
}

struct CaptionCue: Hashable {
    let start: Double
    let end: Double
    let text: String
}

enum CaptionParser {
    /// Parses YouTube's json3 caption format into cues.
    static func json3(_ text: String) -> [CaptionCue] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }
        var cues: [CaptionCue] = []
        for e in events {
            guard let segs = e["segs"] as? [[String: Any]],
                  let startMs = (e["tStartMs"] as? NSNumber)?.doubleValue else { continue }
            let duration = (e["dDurationMs"] as? NSNumber)?.doubleValue ?? 2000
            let line = segs.compactMap { $0["utf8"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            cues.append(CaptionCue(start: startMs / 1000, end: (startMs + duration) / 1000, text: line))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Text to show at time `t`: the (at most two) newest cues that are active.
    static func text(at t: Double, in cues: [CaptionCue]) -> String? {
        guard !cues.isEmpty else { return nil }
        // Binary search for the last cue starting at or before t.
        var lo = 0, hi = cues.count - 1, idx = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { idx = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard idx >= 0 else { return nil }
        var lines: [String] = []
        var i = idx
        while i >= 0 && lines.count < 2 && idx - i < 12 {
            let c = cues[i]
            if c.end > t, !lines.contains(c.text) { lines.insert(c.text, at: 0) }
            i -= 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
