import Foundation

/// A connected Mac signs its own Hub window in.
///
/// Ruled 30 Sep 2026 (Robert): the app and the hub are one account, not two.
/// "There shouldn't be a potential mismatch... they are the same thing." On a
/// Mac connected any way other than a fresh install, the window's web store
/// was empty, so "open report" landed on the hub's sign-in page although the
/// app was signed in. Now, when the window finds nobody signed in, the app
/// asks the hub for a one-time sign-in ticket and loads it.
///
/// The hub route (hq-app `app/api/devices/web-session`) turns a machine
/// credential into a person's web session, so it demands both halves: the
/// device token as Bearer, and a DPoP proof from the key recorded at pairing,
/// exactly as the Gateway token mint does. It answers with the ticket's
/// address and the account's user id, which is how the app knows which
/// account it is connected as.
public enum HubWebSession {

    public struct Ticket: Sendable, Equatable {
        /// The hub's sign-in page carrying the ticket. Load it once, now: it
        /// lives sixty seconds and works one time.
        public let url: URL
        /// The account this Mac is connected as (the hub's sign-in user id).
        public let user: String
    }

    public enum Failure: Error, Equatable {
        case notConnected
        /// The hub said no; 401 means the token or the proof was refused.
        case refused(status: Int)
        case unreadable
    }

    public typealias Post = @Sendable (_ request: URLRequest) async throws -> (status: Int, body: Data)

    /// Ask the hub for a ticket that lands the window on `next` (a hub path).
    public static func ticket(hub: URL, next: String, deviceToken: String?,
                              signer: DeviceKey.Signer, post: Post = httpPost,
                              now: Date = Date()) async throws -> Ticket {
        guard let deviceToken, !deviceToken.isEmpty else { throw Failure.notConnected }
        let route = hub.appendingPathComponent("api/devices/web-session")
        let proof = try DeviceKey.proof(signer: signer, method: "POST", url: route.absoluteString,
                                        accessToken: nil, now: now)
        var request = URLRequest(url: route)
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue(proof, forHTTPHeaderField: "DPoP")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["next": next])

        let (status, body) = try await post(request)
        guard status == 200 else { throw Failure.refused(status: status) }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = json["url"] as? String, let url = URL(string: raw),
              let user = json["user"] as? String, !user.isEmpty,
              // A ticket address is only ever the hub's own page. Anything else
              // is not loaded, whoever sent it.
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == hub.host?.lowercased()
        else { throw Failure.unreadable }
        return Ticket(url: url, user: user)
    }

    /// Where a window on `current` should land after signing in: the page it
    /// was showing, or the one the hub's sign-in page was going to return to.
    public static func landing(from current: URL?) -> String {
        guard let current, var path = Optional(current.path), !path.isEmpty else { return "/" }
        if path.hasPrefix("/sign-in") {
            let back = URLComponents(url: current, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "redirect_url" })?.value
            path = back ?? "/"
        } else if let query = current.query, !query.isEmpty {
            path += "?" + query
        }
        // A hub path and nothing else; the hub checks this again.
        return path.hasPrefix("/") && !path.hasPrefix("//") && !path.contains("\\") ? path : "/"
    }

    /// The real request: ephemeral, no cookies, no redirects.
    public static let httpPost: Post = { request in
        final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            func urlSession(_ session: URLSession, task: URLSessionTask,
                            willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest,
                            completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
                completionHandler(nil)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

