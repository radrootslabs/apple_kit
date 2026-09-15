import Foundation

/// URL authority checks are not DNS/IP-at-connect enforcement. New native
/// transfers are limited to the explicitly isolated simulator foreground path;
/// hosts requiring public endpoint guarantees use their shared foreground I/O.
enum RadrootsNativeDestinationPolicy {
    static func validate(_ url: URL, policy: RadrootsBackgroundTransferNetworkPolicy) throws {
        guard url.absoluteString.utf8.count <= 4096,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = value.host, !host.isEmpty, value.user == nil, value.password == nil,
              value.query == nil, value.fragment == nil,
              value.port.map({ (1 ... 65535).contains($0) }) ?? true,
              !url.absoluteString.contains("\\")
        else { throw RadrootsBackgroundTransferError.invalidRequest }
        let path = value.percentEncodedPath
        guard path.isEmpty || path.hasPrefix("/"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy(safeComponent)
        else { throw RadrootsBackgroundTransferError.invalidRequest }
        switch policy {
        case .publicHTTPS:
            guard value.scheme?.lowercased() == "https" else { throw RadrootsBackgroundTransferError.invalidRequest }
        case .simulatorLoopbackHTTP:
            #if os(iOS) && !targetEnvironment(simulator)
                throw RadrootsBackgroundTransferError.invalidRequest
            #else
                guard value.scheme?.lowercased() == "http",
                      ["127.0.0.1", "localhost", "::1"].contains(normalizedHost(host))
                else { throw RadrootsBackgroundTransferError.invalidRequest }
            #endif
        }
    }

    static func responseMatches(_ response: URL?, original: URLRequest?, current: URLRequest?) -> Bool {
        guard let original, let current, let requested = original.url, let response,
              let requestedParts = URLComponents(url: requested, resolvingAgainstBaseURL: false),
              let responseParts = URLComponents(url: response, resolvingAgainstBaseURL: false),
              current.httpMethod == original.httpMethod, current.url == requested
        else { return false }
        let policy: RadrootsBackgroundTransferNetworkPolicy = requestedParts.scheme?.lowercased() == "https"
            ? .publicHTTPS : .simulatorLoopbackHTTP
        guard (try? validate(requested, policy: policy)) != nil,
              (try? validate(response, policy: policy)) != nil
        else { return false }
        return requestedParts.scheme?.lowercased() == responseParts.scheme?.lowercased()
            && normalizedHost(requestedParts.host ?? "") == normalizedHost(responseParts.host ?? "")
            && effectivePort(requestedParts) == effectivePort(responseParts)
            && normalizedPath(requestedParts) == normalizedPath(responseParts)
    }

    private static func safeComponent(_ component: Substring) -> Bool {
        guard let decoded = String(component).removingPercentEncoding else { return false }
        return decoded != "." && decoded != ".." && !decoded.contains("/") && !decoded.contains("\\")
            && decoded.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func effectivePort(_ parts: URLComponents) -> Int {
        parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private static func normalizedPath(_ parts: URLComponents) -> String {
        parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
    }
}
