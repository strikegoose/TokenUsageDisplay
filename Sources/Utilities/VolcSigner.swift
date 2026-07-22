import Foundation
import CryptoKit

/// Minimal Volcengine signature V4 (HMAC-SHA256) signer for GET OpenAPI calls.
/// Spec: https://www.volcengine.com/docs/6369/67269
enum VolcSigner {

    struct Credentials: Sendable {
        let ak: String
        let sk: String
        /// STS session token (temporary credentials from arkcli SSO login); nil for permanent AK/SK
        var sessionToken: String? = nil
    }

    /// Builds a signed GET request for `https://{host}/?Action=...&Version=...`.
    static func signedGetRequest(
        action: String,
        version: String,
        service: String,
        region: String = "cn-beijing",
        host: String = "open.volcengineapi.com",
        credentials: Credentials,
        date: Date = Date()
    ) -> URLRequest {
        let xDate = isoBasic(date)                 // e.g. 20260722T060000Z
        let shortDate = String(xDate.prefix(8))    // e.g. 20260722
        let payloadHash = sha256Hex(Data())        // empty body

        // Canonical query: percent-encoded, sorted
        let canonicalQuery = [("Action", action), ("Version", version)]
            .map { "\($0.0)=\(uriEncode($0.1))" }
            .sorted()
            .joined(separator: "&")

        let canonicalHeaders =
            "host:\(host)\n" +
            "x-content-sha256:\(payloadHash)\n" +
            "x-date:\(xDate)\n" +
            (credentials.sessionToken.map { "x-security-token:\($0)\n" } ?? "")
        let signedHeaders = credentials.sessionToken != nil
            ? "host;x-content-sha256;x-date;x-security-token"
            : "host;x-content-sha256;x-date"

        let canonicalRequest = [
            "GET",
            "/",
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let scope = "\(shortDate)/\(region)/\(service)/request"
        let stringToSign = [
            "HMAC-SHA256",
            xDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        // Signing key chain: HMAC(SK, date) → region → service → "request"
        let kDate = hmac(key: Data(credentials.sk.utf8), data: Data(shortDate.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = hmac(key: kService, data: Data("request".utf8))
        let signature = hex(hmac(key: kSigning, data: Data(stringToSign.utf8)))

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/"
        components.percentEncodedQuery = canonicalQuery

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(xDate, forHTTPHeaderField: "X-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
        if let sessionToken = credentials.sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Security-Token")
        }
        request.setValue(
            "HMAC-SHA256 Credential=\(credentials.ak)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        request.timeoutInterval = 15
        return request
    }

    // MARK: - Helpers

    private static func isoBasic(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// RFC 3986 URI encode: unreserved characters pass through, everything else %XX.
    private static func uriEncode(_ string: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
