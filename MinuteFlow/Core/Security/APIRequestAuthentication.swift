import Foundation

enum APIRequestAuthentication {
    static func apply(apiKey: String, endpoint: URL, to request: inout URLRequest) {
        let host = endpoint.host?.lowercased() ?? ""
        if host == "xiaomimimo.com" || host.hasSuffix(".xiaomimimo.com") {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue(nil, forHTTPHeaderField: "api-key")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }
}
