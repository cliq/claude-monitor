import Foundation

/// Single-method HTTP client for `https://api.prowlapp.com/publicapi/add`.
/// All Prowl writes (real events and the Settings "Test" button) go through
/// this type so encoding and status-mapping live in one place.
struct ProwlClient {
    enum Error: Swift.Error, Equatable {
        case network(URLError)
        case http(status: Int, body: String)
        case invalidAPIKey
        case rateLimited
    }

    private static let endpoint = URL(string: "https://api.prowlapp.com/publicapi/add")!
    private static let application = "Claude Monitor"

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(apiKey: String, event: String, description: String) async -> Result<Void, Error> {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncoded([
            "apikey":      apiKey,
            "application": Self.application,
            "event":       event,
            "description": description,
            "priority":    "0",
        ])

        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch status {
            case 200..<300:
                return .success(())
            case 401:
                return .failure(.invalidAPIKey)
            case 406:
                return .failure(.rateLimited)
            default:
                return .failure(.http(status: status, body: String(data: data, encoding: .utf8) ?? ""))
            }
        } catch let urlError as URLError {
            return .failure(Self.Error.network(urlError))
        } catch {
            return .failure(Self.Error.network(URLError(.unknown)))
        }
    }

    private func formEncoded(_ pairs: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        // `urlQueryAllowed` permits `:`, but `application/x-www-form-urlencoded` (HTML5
        // form spec) requires it encoded; explicitly remove `&`, `=`, `+`, and `:` from
        // the allow-set so they are percent-encoded.
        allowed.remove(charactersIn: "&=+:")
        let body = pairs
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .sorted()
            .joined(separator: "&")
        return Data(body.utf8)
    }
}
