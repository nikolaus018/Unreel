import Foundation

/// Rules the in-page engine applies (cosmetic hiding, scriptlets, response rewrites).
/// Field names are short because this is serialized into every page load.
struct PageRules: Codable, Equatable {
    struct Cosmetic: Codable, Equatable {
        var s: String          // selector (may be procedural)
        var d: [String]        // include domains (empty = all YouTube hosts)
        var x: [String]        // exclude domains
    }
    struct Scriptlet: Codable, Equatable {
        var n: String          // canonical scriptlet name
        var a: [String]        // arguments
        var d: [String]
        var x: [String]
    }
    struct Replace: Codable, Equatable {
        var u: String          // JS regex source matched against the request URL
        var f: String          // JS regex source to find
        var fl: String         // regex flags
        var r: String          // replacement
    }
    var cosmetic: [Cosmetic] = []
    var scriptlets: [Scriptlet] = []
    var replaces: [Replace] = []
}

/// Output of parsing one or more filter lists.
struct ParseResult {
    var blocks: [[String: Any]] = []
    var allows: [[String: Any]] = []
    var page = PageRules()

    var networkCount = 0
    var cosmeticCount = 0
    var scriptletCount = 0
    var skipped = 0

    fileprivate var seenNetwork = Set<String>()
    fileprivate var cosmeticExceptions = Set<String>()
    fileprivate var scriptletExceptions = Set<String>()
    fileprivate var disableAllScriptlets = false
    fileprivate var badfilters = Set<String>()

    /// Applies exceptions collected across all lists. Call once after every list was parsed.
    mutating func finalize() {
        if !cosmeticExceptions.isEmpty {
            page.cosmetic.removeAll { cosmeticExceptions.contains($0.s) }
        }
        if disableAllScriptlets {
            page.scriptlets.removeAll()
        } else if !scriptletExceptions.isEmpty {
            page.scriptlets.removeAll { scriptletExceptions.contains(FilterParser.scriptletKey($0.n, $0.a)) }
        }
        // De-duplicate page rules.
        var seenC = Set<String>()
        page.cosmetic = page.cosmetic.filter { seenC.insert($0.s + "|" + $0.d.joined(separator: ",") + "|" + $0.x.joined(separator: ",")).inserted }
        var seenS = Set<String>()
        page.scriptlets = page.scriptlets.filter { seenS.insert(FilterParser.scriptletKey($0.n, $0.a) + "|" + $0.d.joined(separator: ",")).inserted }
        cosmeticCount = page.cosmetic.count
        scriptletCount = page.scriptlets.count + page.replaces.count
    }
}

enum FilterParser {

    /// Hosts the app ever shows as a top-level page. Rules restricted to other sites never apply.
    static let relevantHosts = [
        "m.youtube.com", "www.youtube.com", "youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com",
        "accounts.google.com", "accounts.youtube.com", "consent.youtube.com", "consent.google.com",
    ]

    // MARK: Entry point

    /// Parses a filter list. `trusted` enables `trusted-*` scriptlets and `replace=` rules
    /// (uBlock Origin only honours those from its own lists, and so do we).
    static func parse(_ text: String, trusted: Bool, into result: inout ParseResult) {
        let lines = text.utf8.split(whereSeparator: { $0 == 10 || $0 == 13 }).map { String(decoding: $0, as: UTF8.self) }

        // $badfilter cancels a rule wherever it appears, so collect those first.
        for line in lines where line.contains("badfilter") {
            let target = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",badfilter", with: "")
                .replacingOccurrences(of: "$badfilter,", with: "$")
                .replacingOccurrences(of: "$badfilter", with: "")
            result.badfilters.insert(target)
        }

        var conditions: [Bool] = []   // stack for !#if blocks
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Preprocessor directives used by uBlock lists.
            if line.hasPrefix("!#") {
                if line.hasPrefix("!#if ") {
                    conditions.append(evaluateCondition(String(line.dropFirst(5))))
                } else if line.hasPrefix("!#else") {
                    if let last = conditions.popLast() { conditions.append(!last) }
                } else if line.hasPrefix("!#endif") {
                    _ = conditions.popLast()
                }
                continue
            }
            if conditions.contains(false) { continue }
            if line.hasPrefix("!") || line.hasPrefix("[") { continue }

            parseLine(line, trusted: trusted, into: &result)
        }
    }

    static func parseLine(_ line: String, trusted: Bool, into result: inout ParseResult) {
        // Hosts-file style line ("0.0.0.0 example.com").
        if line.hasPrefix("0.0.0.0 ") || line.hasPrefix("127.0.0.1 ") {
            var host = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? ""
            if let hash = host.firstIndex(of: "#") { host = String(host[..<hash]) }
            host = host.lowercased()
            let ignored: Set<String> = ["localhost", "localhost.localdomain", "local", "broadcasthost", "0.0.0.0", "ip6-localhost"]
            guard !host.isEmpty, !ignored.contains(host), host.contains(".") else { return }
            parseNetwork("||\(host)^", trusted: trusted, into: &result)
            return
        }
        // Comment lines in hosts files.
        if line == "#" || line.hasPrefix("# ") || line.hasPrefix("#\t") { return }

        if let sep = cosmeticSeparator(in: line) {
            parseCosmetic(line, separator: sep, trusted: trusted, into: &result)
            return
        }
        if line.contains("$$") || line.contains("$@$") { result.skipped += 1; return }   // HTML filtering
        parseNetwork(line, trusted: trusted, into: &result)
    }

    // MARK: Cosmetic and scriptlet rules

    private static let separators = ["#@?#", "#@$#", "#@%#", "#@#", "#?#", "#$#", "#%#", "##"]

    private static func cosmeticSeparator(in line: String) -> Range<String.Index>? {
        guard let first = line.firstIndex(of: "#") else { return nil }
        var best: Range<String.Index>?
        for sep in separators {
            if let r = line.range(of: sep, range: first..<line.endIndex) {
                if best == nil || r.lowerBound < best!.lowerBound
                    || (r.lowerBound == best!.lowerBound && sep.count > line[best!].count) {
                    best = r
                }
            }
        }
        // A "#" inside a URL path ("||site.com/#foo") is not a cosmetic separator.
        if let b = best {
            let prefix = line[..<b.lowerBound]
            if prefix.contains("/") || prefix.contains("|") || prefix.contains("^") { return nil }
        }
        return best
    }

    private static func parseCosmetic(_ line: String, separator: Range<String.Index>, trusted: Bool, into result: inout ParseResult) {
        let sep = String(line[separator])
        let domainPart = String(line[..<separator.lowerBound])
        let body = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        if sep.contains("$") || sep.contains("%") { result.skipped += 1; return }   // ABP/AdGuard snippets
        guard !body.isEmpty else { return }

        let isException = sep.contains("@")
        let (includes, excludes) = splitDomains(domainPart, separator: ",")

        // Generic rules (no include domain) are not applied: they are numerous and tuned for
        // ordinary websites. YouTube-specific rules are what matter here.
        let relevantIncludes = includes.filter(isRelevantDomain)
        if isException {
            // Exceptions: honour if generic or relevant.
            guard includes.isEmpty || !relevantIncludes.isEmpty else { return }
            if body.hasPrefix("+js(") {
                if body == "+js()" { result.disableAllScriptlets = !includes.isEmpty }
                else if let (name, args) = parseScriptlet(body) { result.scriptletExceptions.insert(scriptletKey(name, args)) }
            } else {
                result.cosmeticExceptions.insert(body)
            }
            return
        }
        guard !relevantIncludes.isEmpty else { return }

        if body.hasPrefix("+js(") {
            guard let (name, args) = parseScriptlet(body) else { result.skipped += 1; return }
            if name.hasPrefix("trusted-") && !trusted { result.skipped += 1; return }
            guard supportedScriptlets.contains(name) else { result.skipped += 1; return }
            result.page.scriptlets.append(.init(n: name, a: args, d: relevantIncludes, x: excludes))
            return
        }
        if body.hasPrefix("^") { result.skipped += 1; return }   // HTML filters
        result.page.cosmetic.append(.init(s: body, d: relevantIncludes, x: excludes))
    }

    /// Scriptlets implemented by `engine.js`.
    static let supportedScriptlets: Set<String> = [
        "set-constant", "trusted-set-constant",
        "json-prune", "json-prune-fetch-response", "json-prune-xhr-response",
        "trusted-replace-fetch-response", "trusted-replace-xhr-response",
        "abort-on-property-read", "abort-on-property-write", "abort-current-script",
        "no-setTimeout-if", "no-setInterval-if", "nano-setTimeout-booster", "nano-setInterval-booster",
        "addEventListener-defuser", "remove-attr", "remove-class",
        "no-fetch-if", "no-xhr-if", "noeval-if", "set-local-storage-item",
        "remove-node-text", "replace-node-text",
    ]

    static let scriptletAliases: [String: String] = [
        "set": "set-constant", "trusted-set": "trusted-set-constant",
        "aopr": "abort-on-property-read", "aopw": "abort-on-property-write", "acs": "abort-current-script",
        "acis": "abort-current-script", "abort-current-inline-script": "abort-current-script",
        "nostif": "no-setTimeout-if", "prevent-setTimeout": "no-setTimeout-if", "setTimeout-defuser": "no-setTimeout-if",
        "nosiif": "no-setInterval-if", "prevent-setInterval": "no-setInterval-if", "setInterval-defuser": "no-setInterval-if",
        "nano-stb": "nano-setTimeout-booster", "nano-sib": "nano-setInterval-booster",
        "aeld": "addEventListener-defuser", "prevent-addEventListener": "addEventListener-defuser",
        "ra": "remove-attr", "rc": "remove-class",
        "prevent-fetch": "no-fetch-if", "prevent-xhr": "no-xhr-if",
        "prevent-eval-if": "noeval-if",
        "rmnt": "remove-node-text", "rpnt": "replace-node-text", "trusted-rpnt": "replace-node-text",
        "trusted-rpfr": "trusted-replace-fetch-response", "trusted-rpxr": "trusted-replace-xhr-response",
    ]

    static func scriptletKey(_ name: String, _ args: [String]) -> String {
        ([name] + args).joined(separator: ", ")
    }

    /// Parses `+js(name, arg1, arg2)` honouring `\,` escapes.
    static func parseScriptlet(_ body: String) -> (String, [String])? {
        guard body.hasPrefix("+js("), body.hasSuffix(")") else { return nil }
        let inner = String(body.dropFirst(4).dropLast())
        var parts: [String] = []
        var current = ""
        var escaped = false
        for ch in inner {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "," { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\,", with: ",") }
        guard var name = parts.first, !name.isEmpty else { return nil }
        if name.hasSuffix(".js") { name = String(name.dropLast(3)) }
        name = scriptletAliases[name] ?? name
        var args = Array(parts.dropFirst())
        while let last = args.last, last.isEmpty { args.removeLast() }
        // Quoted arguments: '"adPlacements"' -> "adPlacements"
        args = args.map { a in
            if a.count >= 2, (a.hasPrefix("'") && a.hasSuffix("'")) || (a.hasPrefix("`") && a.hasSuffix("`")) {
                return String(a.dropFirst().dropLast())
            }
            return a
        }
        return (name, args)
    }

    // MARK: Network rules

    static let subresourceTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping", "websocket", "other"]

    private static let typeMap: [String: [String]] = [
        "script": ["script"], "image": ["image", "svg-document"], "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "font": ["font"], "media": ["media"], "xmlhttprequest": ["raw"], "xhr": ["raw"],
        "websocket": ["websocket"], "ping": ["ping"], "beacon": ["ping"], "other": ["other"], "object": ["other"],
        "subdocument": ["document"], "frame": ["document"],
    ]

    /// Options we can ignore without changing what a rule blocks in a meaningful way.
    private static let ignorableOptions: Set<String> = ["important", "all", "match-case", "strict1p", "strict3p", "1p", "3p",
                                                        "first-party", "third-party", "~third-party", "~first-party", "~1p", "~3p",
                                                        "xml", "object-subrequest", "~object", "~object-subrequest", "genericblock", "~media", "~image"]

    static func parseNetwork(_ input: String, trusted: Bool, into result: inout ParseResult) {
        var line = input
        var isException = false
        if line.hasPrefix("@@") { isException = true; line.removeFirst(2) }

        var pattern = line
        var options: [String] = []
        if let idx = optionsDollarIndex(in: line) {
            pattern = String(line[..<idx])
            options = splitOptions(String(line[line.index(after: idx)...]))
        }
        if result.badfilters.contains(input) { return }

        var types = Set<String>()
        var negTypes = Set<String>()
        var loadType: String?
        var includes: [String] = []
        var excludes: [String] = []
        var caseSensitive = false
        var replace: String?
        var isDocument = false

        for opt in options {
            let lower = opt.lowercased()
            if lower == "badfilter" { return }
            if lower.hasPrefix("domain=") || lower.hasPrefix("from=") {
                let value = String(lower.split(separator: "=", maxSplits: 1).last ?? "")
                let (inc, exc) = splitDomains(value, separator: "|")
                includes += inc; excludes += exc
                continue
            }
            if lower.hasPrefix("replace=") {
                guard trusted else { result.skipped += 1; return }
                replace = String(opt.dropFirst("replace=".count))
                continue
            }
            if lower.hasPrefix("redirect=") || lower.hasPrefix("rewrite=") { continue }   // block instead
            if lower.hasPrefix("redirect-rule=") { result.skipped += 1; return }
            switch lower {
            case "third-party", "3p", "~first-party", "~1p": loadType = "third-party"; continue
            case "first-party", "1p", "~third-party", "~3p", "strict1p": loadType = "first-party"; continue
            case "match-case": caseSensitive = true; continue
            case "document", "doc": isDocument = true; continue
            case "important", "all", "strict3p": continue
            case "popup", "csp", "generichide", "ghide", "elemhide", "ehide", "specifichide", "shide",
                 "inline-script", "inline-font", "empty", "mp4", "cname", "genericblock":
                result.skipped += 1; return
            default: break
            }
            if lower.hasPrefix("~"), let mapped = typeMap[String(lower.dropFirst())] {
                negTypes.formUnion(mapped); continue
            }
            if let mapped = typeMap[lower] { types.formUnion(mapped); continue }
            if ignorableOptions.contains(lower) { continue }
            // Anything else (removeparam, header, method, to, denyallow, permissions, ...) changes
            // semantics in ways content blockers cannot express: skip the rule.
            result.skipped += 1
            return
        }

        // Domain relevance: rules limited to other sites never apply in this app.
        let relevantIncludes = includes.filter(isRelevantDomain)
        if !includes.isEmpty && relevantIncludes.isEmpty { return }
        if excludes.contains(where: isRelevantDomain) { return }

        // replace= rules are applied to responses by the page engine.
        if let replace {
            guard !isException, let urlRegex = jsRegex(fromPattern: pattern), let spec = parseReplace(replace) else {
                result.skipped += 1; return
            }
            result.page.replaces.append(.init(u: urlRegex, f: spec.find, fl: spec.flags, r: spec.replacement))
            return
        }

        if isDocument && !isException { result.skipped += 1; return }   // never block whole pages
        if isDocument && isException { return }                           // site allowlisting is irrelevant here

        // Regex patterns are rarely expressible in WebKit's regex subset.
        if pattern.count > 2 && pattern.hasPrefix("/") && pattern.hasSuffix("/") { result.skipped += 1; return }
        guard let filter = urlFilter(fromPattern: pattern) else { result.skipped += 1; return }

        var trigger: [String: Any] = ["url-filter": filter]
        if caseSensitive { trigger["url-filter-is-case-sensitive"] = true }
        if !types.isEmpty {
            trigger["resource-type"] = Array(types).sorted()
            // "document" here only ever means a frame (subdocument), never the page itself.
            if types.contains("document") { trigger["load-context"] = ["child-frame"] }
        } else if !isException {
            // Like uBlock Origin, untyped block rules never block the top-level page.
            let remaining = subresourceTypes.filter { !negTypes.contains($0) }
            guard !remaining.isEmpty else { return }
            trigger["resource-type"] = remaining
        }
        if let loadType { trigger["load-type"] = [loadType] }
        if !relevantIncludes.isEmpty {
            trigger["if-domain"] = relevantIncludes.map { "*" + $0 }.sorted()
        }

        let key = (isException ? "@" : "") + filter + "|" + ((trigger["resource-type"] as? [String])?.joined(separator: ",") ?? "")
            + "|" + (loadType ?? "") + "|" + ((trigger["if-domain"] as? [String])?.joined(separator: ",") ?? "") + (caseSensitive ? "|c" : "")
        guard result.seenNetwork.insert(key).inserted else { return }

        let rule: [String: Any] = ["trigger": trigger, "action": ["type": isException ? "ignore-previous-rules" : "block"]]
        if isException { result.allows.append(rule) } else { result.blocks.append(rule) }
        result.networkCount += 1
    }

    /// Finds the `$` that starts the options part, if any.
    static func optionsDollarIndex(in line: String) -> String.Index? {
        var idx = line.endIndex
        while let found = line[..<idx].lastIndex(of: "$") {
            let rest = line[line.index(after: found)...]
            if !rest.isEmpty, splitOptions(String(rest)).allSatisfy(isPlausibleOption) {
                return found
            }
            idx = found
        }
        return nil
    }

    private static func isPlausibleOption(_ opt: String) -> Bool {
        guard let first = opt.first, first.isLetter || first == "~" || first.isNumber else { return false }
        let name = opt.split(separator: "=", maxSplits: 1).first.map(String.init) ?? opt
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "~" }
    }

    /// Splits options on commas, but not inside a `replace=/…/…/` value or after `\`.
    static func splitOptions(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        var slashCount = 0
        var inReplace = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if current.lowercased() == "replace=" || current.lowercased() == "urltransform=" { inReplace = true; slashCount = 0 }
            if inReplace && ch == "/" { slashCount += 1 }
            if ch == "," && (!inReplace || slashCount >= 3) {
                parts.append(current); current = ""; inReplace = false; continue
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// `/find/replacement/flags`
    static func parseReplace(_ spec: String) -> (find: String, replacement: String, flags: String)? {
        guard spec.hasPrefix("/") else { return nil }
        var parts: [String] = []
        var current = ""
        var escaped = false
        for ch in spec.dropFirst() {
            if escaped { current.append("\\"); current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "/" && parts.count < 2 { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        guard parts.count == 3 else { return nil }
        // "\," in uBO syntax is a literal comma.
        let find = parts[0].replacingOccurrences(of: "\\,", with: ",")
        let replacement = parts[1].replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\/", with: "/")
        return (find, replacement, parts[2].isEmpty ? "g" : parts[2])
    }

    // MARK: Pattern conversion

    /// Converts an adblock URL pattern into a WebKit content-blocker regex (a restricted subset:
    /// no alternation, no counted repetition, anchors only at the ends).
    static func urlFilter(fromPattern input: String) -> String? {
        var p = Substring(input)
        var out = ""
        if p.hasPrefix("||") { p = p.dropFirst(2); out = "^[^:]+://+([^:/]+\\.)?" }
        else if p.hasPrefix("|") { p = p.dropFirst(); out = "^" }
        var endAnchor = false
        if p.hasSuffix("|") { p = p.dropLast(); endAnchor = true }
        if out.isEmpty { while p.hasPrefix("*") { p = p.dropFirst() } }
        if !endAnchor { while p.hasSuffix("*") { p = p.dropLast() } }
        if p.isEmpty { return out.isEmpty ? ".*" : nil }
        // Very short generic patterns would block far too much.
        if out.isEmpty && p.count < 4 && !p.contains("/") { return nil }

        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "^": out += "[/:?&=]"
            case ".", "+", "?", "{", "}", "(", ")", "[", "]", "\\", "$": out += "\\" + String(ch)
            case "|", " ", "\t": return nil
            default:
                guard ch.isASCII else { return nil }
                out.append(ch)
            }
        }
        if endAnchor { out += "$" }
        return out
    }

    /// Same as `urlFilter` but for JavaScript, where `^` can also match the end of the URL.
    static func jsRegex(fromPattern input: String) -> String? {
        if input.count > 2 && input.hasPrefix("/") && input.hasSuffix("/") { return String(input.dropFirst().dropLast()) }
        var p = Substring(input)
        var out = ""
        if p.hasPrefix("||") { p = p.dropFirst(2); out = "^[^:]+://+([^:/]+\\.)?" }
        else if p.hasPrefix("|") { p = p.dropFirst(); out = "^" }
        var endAnchor = false
        if p.hasSuffix("|") { p = p.dropLast(); endAnchor = true }
        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "^": out += "(?:[^\\w.%-]|$)"
            case ".", "+", "?", "{", "}", "(", ")", "[", "]", "\\", "$", "|", "/": out += "\\" + String(ch)
            default: out.append(ch)
            }
        }
        if endAnchor { out += "$" }
        return out
    }

    // MARK: Domains

    /// Splits "a.com,~b.com" into includes and excludes (lowercased, wildcard `*` entries dropped).
    static func splitDomains(_ s: String, separator: Character) -> ([String], [String]) {
        var inc: [String] = []
        var exc: [String] = []
        for raw in s.split(separator: separator) {
            var d = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !d.isEmpty, d != "*" else { continue }
            let negated = d.hasPrefix("~")
            if negated { d.removeFirst() }
            // Entities ("youtube.*") only matter for the YouTube entity.
            // A dropped include must still count as "restricted to some other site",
            // otherwise the rule would silently become global.
            let unmatchable = "~unmatchable~"
            if d.hasSuffix(".*") {
                let base = String(d.dropLast(2))
                if base == "youtube" || base.hasSuffix(".youtube") { d = base + ".com" } else {
                    if !negated { inc.append(unmatchable) }
                    continue
                }
            }
            guard d.allSatisfy({ $0.isASCII }), !d.hasPrefix("/") else {
                if !negated { inc.append(unmatchable) }
                continue
            }
            if negated { exc.append(d) } else { inc.append(d) }
        }
        return (inc, exc)
    }

    static func isRelevantDomain(_ d: String) -> Bool {
        relevantHosts.contains { $0 == d || $0.hasSuffix("." + d) }
    }

    // MARK: Preprocessor

    /// Evaluates `!#if` expressions the way uBlock Origin on Safari/iOS would.
    static func evaluateCondition(_ expr: String) -> Bool {
        let truthy: Set<String> = ["ext_ublock", "env_safari", "env_mobile", "cap_user_stylesheet"]
        var tokens: [String] = []
        var current = ""
        for ch in expr {
            if "()!".contains(ch) {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            } else if ch == " " {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
                if current == "&&" || current == "||" { tokens.append(current); current = "" }
            }
        }
        if !current.isEmpty { tokens.append(current) }

        var pos = 0
        func parseOr() -> Bool {
            var v = parseAnd()
            while pos < tokens.count, tokens[pos] == "||" { pos += 1; let r = parseAnd(); v = v || r }
            return v
        }
        func parseAnd() -> Bool {
            var v = parseUnary()
            while pos < tokens.count, tokens[pos] == "&&" { pos += 1; let r = parseUnary(); v = v && r }
            return v
        }
        func parseUnary() -> Bool {
            guard pos < tokens.count else { return false }
            let t = tokens[pos]; pos += 1
            if t == "!" { return !parseUnary() }
            if t == "(" { let v = parseOr(); if pos < tokens.count, tokens[pos] == ")" { pos += 1 }; return v }
            return truthy.contains(t)
        }
        return parseOr()
    }
}
