import Foundation

/// Lightweight, forgiving accessor for YouTube's deeply nested JSON.
struct J {
    let value: Any?

    init(_ value: Any?) { self.value = value }

    init(data: Data) throws {
        value = try JSONSerialization.jsonObject(with: data)
    }

    subscript(key: String) -> J { J((value as? [String: Any])?[key]) }
    subscript(index: Int) -> J {
        guard let a = value as? [Any], index >= 0, index < a.count else { return J(nil) }
        return J(a[index])
    }

    var exists: Bool { value != nil && !(value is NSNull) }
    var string: String? { value as? String }
    var bool: Bool? { value as? Bool }
    var int: Int? { (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) }
    var double: Double? { (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) }
    var array: [J] { (value as? [Any])?.map(J.init) ?? [] }
    var dict: [String: Any]? { value as? [String: Any] }
    var keys: [String] { dict.map { Array($0.keys) } ?? [] }
    var last: J { array.last ?? J(nil) }

    /// Text from any of YouTube's text shapes: `simpleText`, `runs`, `content`, or a plain string.
    var text: String? {
        if let s = value as? String { return s }
        if let s = self["simpleText"].string { return s }
        if let s = self["content"].string { return s }
        let runs = self["runs"].array
        if !runs.isEmpty {
            let joined = runs.compactMap { $0["text"].string }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// Largest thumbnail URL from `thumbnails` or `sources` arrays.
    var thumbnailURL: URL? {
        let list = self["thumbnails"].array + self["sources"].array
        guard var s = list.last?["url"].string else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    /// Depth-first search for the first value stored under `key`.
    func first(_ key: String, maxDepth: Int = 40) -> J {
        var stack: [(Any, Int)] = [(value as Any, 0)]
        while let (node, depth) = stack.popLast() {
            if let d = node as? [String: Any] {
                if let hit = d[key] { return J(hit) }
                if depth < maxDepth { for v in d.values { stack.append((v, depth + 1)) } }
            } else if let a = node as? [Any], depth < maxDepth {
                for v in a.reversed() { stack.append((v, depth + 1)) }
            }
        }
        return J(nil)
    }

    /// All values stored under `key`, in document order.
    func all(_ key: String) -> [J] {
        var out: [J] = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                for (k, v) in d {
                    if k == key { out.append(J(v)) } else { walk(v) }
                }
            } else if let a = node as? [Any] {
                a.forEach(walk)
            }
        }
        if let v = value { walk(v) }
        return out
    }
}
