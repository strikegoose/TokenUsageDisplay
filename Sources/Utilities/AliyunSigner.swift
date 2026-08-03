import Foundation
import CryptoKit

/// Alibaba Cloud RPC API signature V1 (HMAC-SHA1, base64).
///
/// Used for GET OpenAPI calls such as the BSS (费用中心) `QueryAccountBalance`
/// action. Spec: https://help.aliyun.com/zh/sdk/product-overview/v3-request-structure-and-signature
///
/// StringToSign = "GET&%2F&" + percentEncode(canonicalizedQueryString)
/// Signature     = Base64(HMAC-SHA1(key = AccessKeySecret + "&", msg = StringToSign))
enum AliyunSigner {

    struct Credentials: Sendable {
        let ak: String
        let sk: String
    }

    /// Builds a signed GET request for an Alibaba Cloud RPC OpenAPI call.
    /// `host` defaults to the BSS (费用) endpoint; pass another to reuse for
    /// other Alibaba services.
    static func signedGetRequest(
        action: String,
        version: String,
        host: String = "business.aliyuncs.com",
        region: String = "cn-hangzhou",
        credentials: Credentials,
        date: Date = Date()
    ) -> URLRequest {
        // RPC common parameters
        var params: [String: String] = [
            "Action": action,
            "Version": version,
            "Format": "JSON",
            "AccessKeyId": credentials.ak,
            "SignatureMethod": "HMAC-SHA1",
            "SignatureVersion": "1.0",
            "SignatureNonce": UUID().uuidString,
            "Timestamp": iso8601(date),
            "RegionId": region
        ]

        // 1. Canonicalized query string: keys sorted, both sides percent-encoded
        let canonicalQuery = params
            .sorted { $0.key < $1.key }
            .map { "\(uriEncode($0.key))=\(uriEncode($0.value))" }
            .joined(separator: "&")

        // 2. String to sign: GET + "&" + %2F + "&" + percentEncode(canonicalQuery)
        let stringToSign = "GET&\(uriEncode("/"))&\(uriEncode(canonicalQuery))"

        // 3. Signature = Base64(HMAC-SHA1(key = SK + "&", msg = stringToSign))
        let key = Data((credentials.sk + "&").utf8)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: key)
        )
        params["Signature"] = Data(mac).base64EncodedString()

        // 4. Rebuild the full (signed) query and assemble the URL
        let signedQuery = params
            .sorted { $0.key < $1.key }
            .map { "\(uriEncode($0.key))=\(uriEncode($0.value))" }
            .joined(separator: "&")

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/"
        components.percentEncodedQuery = signedQuery

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        return request
    }

    // MARK: - Helpers

    /// ISO8601 UTC timestamp, e.g. 2026-08-04T12:00:00Z
    private static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// RFC 3986 URI encode: unreserved characters pass through, everything else %XX.
    /// Identical to Alibaba's specialUrlEncode (space → %20, * → %2A, ~ kept).
    private static func uriEncode(_ string: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
