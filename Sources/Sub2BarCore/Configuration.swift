import Foundation

public struct Configuration: Codable, Equatable, Sendable {
    public static let defaultRefreshInterval: Double = 5
    public static let minimumRefreshInterval: Double = 5
    public static let maximumRefreshInterval: Double = 60
    public static let quotaIntervals: [Double] = [5, 10, 15, 30, 60]
    public static let concurrencyInterval: Double = 2
    public static let statusInterval: Double = 5
    public static let upstreamMinimumInterval: Double = 600
    public var serverURL: String
    public var refreshInterval: Double
    public var allowHTTP: Bool

    public init(serverURL: String = "", refreshInterval: Double = Configuration.defaultRefreshInterval, allowHTTP: Bool = false) {
        self.serverURL = serverURL
        self.refreshInterval = refreshInterval
        self.allowHTTP = allowHTTP
    }

    public var effectiveRefreshInterval: Double {
        guard refreshInterval.isFinite else { return Self.defaultRefreshInterval }
        return Self.quotaIntervals.first(where: { $0 >= refreshInterval }) ?? Self.maximumRefreshInterval
    }

    public func baseURL() throws -> URL {
        let input = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: input),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw APIError.invalidURL }
        guard scheme == "https" || allowHTTP else { throw APIError.insecureHTTP }
        parts.scheme = scheme
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/api/v1/admin", "/api/v1"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
            break
        }
        parts.path = path
        guard let url = parts.url else { throw APIError.invalidURL }
        return url
    }

    public func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let base = try baseURL().appendingPathComponent("api/v1/admin").appendingPathComponent(path)
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw APIError.invalidURL }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw APIError.invalidURL }
        return url
    }
}

public enum APIError: Error, LocalizedError, Equatable {
    case invalidURL, insecureHTTP, missingKey, invalidResponse, tooManyPages
    case http(Int), server(Int), network

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的服务器地址，例如 https://sub2api.example.com；不要包含账号密码、查询参数或页面锚点。"
        case .insecureHTTP: return "HTTP 会明文传输 Admin Key。仅在可信网络下明确允许后使用。"
        case .missingKey: return "请先填写 Admin API Key。"
        case .invalidResponse: return "响应格式不兼容。请检查 URL 是否指向 sub2api，而不是登录页或其他服务。"
        case .tooManyPages: return "账号分页异常或超过 10,000 个账号；本次刷新已停止。"
        case .http(401), .http(403): return "认证失败：请检查 Admin API Key 及反向代理访问权限。"
        case .http(404): return "接口不存在：请检查服务器 URL、子路径及 sub2api 版本。"
        case .http(429): return "请求过于频繁，请增大刷新间隔后重试。"
        case .http(let code) where (300..<400).contains(code): return "服务器要求重定向。为避免泄露密钥，请直接填写最终服务地址。"
        case .http(let code): return "服务器请求失败（HTTP \(code)）。"
        case .server(let code): return "sub2api 返回错误（code \(code)）。"
        case .network: return "无法连接服务器。请检查网络、地址和 HTTPS 证书。"
        }
    }
}
