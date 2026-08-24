import Foundation

enum APIRequestAuthentication {
    static func apply(apiKey: String, endpoint: URL, to request: inout URLRequest) {
        if endpoint.host?.lowercased().contains("xiaomimimo.com") == true {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }
}
