import XCTest

/// Policy: the app never talks to the network (no network entitlement, no third-party requests). This scans
/// every Swift file under `Sources/` for networking APIs and web URLs, outside comments, and fails on any.
/// The only URL strings allowed are XML/XMP namespace names and SVG DTD identifiers: they name a vocabulary
/// and are never fetched (`SVGSanitizer` refuses anything external). Links in docs (README etc.) are not
/// under `Sources/` and are fine.
final class NoNetworkTests: XCTestCase {
    static let forbiddenAPIs = ["URLSession", "URLRequest", "NWConnection", "NWListener", "NWBrowser", "CFSocket",
                                "NSURLConnection", "WKWebView", "CFStream", "NSStream", "SCNetworkReachability",
                                "getaddrinfo"]
    /// What isn't a single identifier: network modules, POSIX sockets and the CFHTTPMessage function family.
    static let forbiddenPatterns = [#"\bimport\s+(Network|WebKit)\b"#, #"\bsocket\s*\("#, #"\bCFHTTPMessage"#]
    static let allowedURLPrefixes = ["http://www.w3.org/", "http://ns.adobe.com/", "http://ns.apple.com/",
                                     "http://purl.org/dc/", "http://iptc.org/std/"]

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
    }

    func testNoNetworkAPIsInSources() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var problems: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let code = Self.strippingComments(try String(contentsOf: url, encoding: .utf8))
            let name = url.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            problems += Self.violations(in: code).map { "\(name): \($0)" }
        }
        XCTAssertGreaterThan(scanned, 50, "Sources/ not found at \(sourcesRoot.path)")
        XCTAssertEqual(problems, [])
    }

    func testScannerSeesThroughCommentsButNotStrings() {
        let code = """
        // URLSession in a comment is fine, so is https://example.com
        /* NWConnection, /* nested */ http://example.com */
        let a = "// not a comment: https://example.com"
        let b = URLSession.shared
        let c = "http://www.w3.org/2000/svg"
        let d = "quote \\" then // still a string http://evil.test"
        """
        let violations = Self.violations(in: Self.strippingComments(code))
        XCTAssertEqual(violations, ["URL https://example.com", "URL http://evil.test", "API URLSession"])
        let more = """
        import Network
        import WebKit
        let s = socket (AF_INET, SOCK_STREAM, 0)
        var r = URLRequest(url: u); getaddrinfo(nil, nil, nil, nil); CFHTTPMessageCreateEmpty(nil, true)
        let w = ["ws://a", "wss://b", "ftp://c"]
        // import Network in a comment, socket( too
        let fine = CFSocketless + mysocket(1)
        """
        XCTAssertEqual(Self.violations(in: Self.strippingComments(more)), [
            "URL ws://a", "URL wss://b", "URL ftp://c", "API URLRequest", "API getaddrinfo",
            "API import Network", "API import WebKit", "API socket (", "API CFHTTPMessage",
        ])
    }

    /// Forbidden identifiers (whole words) and web URLs outside the allowlist.
    static func violations(in code: String) -> [String] {
        var found: [String] = []
        let urlPattern = try? NSRegularExpression(pattern: #"(?:https?|wss?|ftp)://[^\s"\\)]+"#)
        let range = NSRange(code.startIndex..., in: code)
        for match in urlPattern?.matches(in: code, range: range) ?? [] {
            guard let swiftRange = Range(match.range, in: code) else { continue }
            let url = String(code[swiftRange])
            if !allowedURLPrefixes.contains(where: url.hasPrefix) { found.append("URL \(url)") }
        }
        for api in forbiddenAPIs {
            let pattern = try? NSRegularExpression(pattern: "\\b\(api)\\b")
            if pattern?.firstMatch(in: code, range: range) != nil { found.append("API \(api)") }
        }
        for source in forbiddenPatterns {
            let pattern = try? NSRegularExpression(pattern: source)
            for match in pattern?.matches(in: code, range: range) ?? [] {
                if let swiftRange = Range(match.range, in: code) { found.append("API \(code[swiftRange])") }
            }
        }
        return found
    }

    /// The source with `//` and (nested) `/* */` comments removed; string literals, including multi-line and
    /// raw ones, are kept as they are.
    static func strippingComments(_ source: String) -> String {
        let chars = Array(source)
        var output: [Character] = []
        var index = 0
        func peek(_ offset: Int) -> Character? { index + offset < chars.count ? chars[index + offset] : nil }
        while index < chars.count {
            let char = chars[index]
            if char == "/", peek(1) == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else if char == "/", peek(1) == "*" {
                var depth = 0
                repeat {
                    if chars[index] == "/", peek(1) == "*" {
                        depth += 1
                        index += 2
                    } else if chars[index] == "*", peek(1) == "/" {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                } while depth > 0 && index < chars.count
            } else if char == "#" || char == "\"" {
                index = copyString(chars, from: index, into: &output)
            } else {
                output.append(char)
                index += 1
            }
        }
        return String(output)
    }

    /// Copies one string literal (`"…"`, `"""…"""`, `#"…"#`) starting at `start`; returns the index after it.
    private static func copyString(_ chars: [Character], from start: Int, into output: inout [Character]) -> Int {
        var index = start
        var hashes = 0
        while index < chars.count, chars[index] == "#" { hashes += 1; index += 1 }
        guard index < chars.count, chars[index] == "\"" else {
            output.append(contentsOf: chars[start..<index])
            return index
        }
        let multiline = index + 2 < chars.count && chars[index + 1] == "\"" && chars[index + 2] == "\""
        let quote: [Character] = multiline ? ["\"", "\"", "\""] : ["\""]
        let closing = quote + Array(repeating: "#", count: hashes)
        index += quote.count
        while index < chars.count {
            if hashes == 0, chars[index] == "\\" {
                index += 2
                continue
            }
            if index + closing.count <= chars.count, Array(chars[index..<(index + closing.count)]) == closing {
                index += closing.count
                break
            }
            index += 1
        }
        output.append(contentsOf: chars[start..<min(index, chars.count)])
        return index
    }
}
