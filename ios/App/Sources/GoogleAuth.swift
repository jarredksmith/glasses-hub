import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

/// Signing in to Google for read-only Gmail access.
///
/// The sign-in page is Google's own, shown by iOS; this app never sees the password. What it gets back
/// is a key that only allows reading mail, kept in the iPhone's Keychain. Mail goes from Google straight
/// to this phone and on to the glasses; nothing passes through the PC or any server of ours.
@MainActor
final class GoogleAuth: NSObject, @preconcurrency ASWebAuthenticationPresentationContextProviding {
    private let service = "GlassesHub.google"
    private var access: (token: String, expires: Date)?
    private var session: ASWebAuthenticationSession?

    var signedIn: Bool { keychain("refresh") != nil }

    /// Returns nil on success, or a sentence saying what went wrong.
    func signIn(clientID rawID: String) async -> String? {
        let clientID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientID.hasSuffix(".apps.googleusercontent.com") else {
            return "That doesn't look like a Google client ID. It ends in .apps.googleusercontent.com."
        }
        let scheme = "com.googleusercontent.apps." + String(clientID.dropLast(".apps.googleusercontent.com".count))
        let redirect = scheme + ":/oauth2redirect"
        let verifier = (0..<64).map { _ in String("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()!) }.joined()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/gmail.readonly"),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = parts.url else { return "Couldn't build the sign-in address." }
        let callback: URL? = await withCheckedContinuation { done in
            var answered = false                     // the system may report both "couldn't start" and a result
            func finish(_ url: URL?) { if !answered { answered = true; done.resume(returning: url) } }
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, _ in
                DispatchQueue.main.async { finish(url) }
            }
            web.presentationContextProvider = self
            self.session = web
            if !web.start() { finish(nil) }
        }
        session = nil
        guard let callback, let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else {
            return "Sign-in was cancelled or Google didn't approve it."
        }
        guard let reply = await token(["grant_type": "authorization_code", "code": code, "client_id": clientID,
                                       "redirect_uri": redirect, "code_verifier": verifier]),
              let refresh = reply["refresh_token"] as? String else {
            return "Google didn't hand back a key. Check that the client ID is the iOS kind and the Gmail API is turned on."
        }
        setKeychain("refresh", refresh); setKeychain("client", clientID)
        remember(reply)
        return nil
    }

    func signOut() {
        setKeychain("refresh", nil); setKeychain("client", nil)
        access = nil
    }

    /// A short-lived key for the next request, renewed when it's about to run out. Nil if not signed in.
    func accessToken() async -> String? {
        if let access, access.expires > Date().addingTimeInterval(60) { return access.token }
        guard let refresh = keychain("refresh"), let clientID = keychain("client"),
              let reply = await token(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]) else { return nil }
        if reply["error"] as? String == "invalid_grant" { signOut(); return nil }      // access was revoked or has expired
        remember(reply)
        return access?.token
    }

    private func remember(_ reply: [String: Any]) {
        guard let token = reply["access_token"] as? String else { return }
        access = (token, Date().addingTimeInterval((reply["expires_in"] as? Double) ?? 3000))
    }

    private func token(_ fields: [String: String]) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents(); form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
    }

    // MARK: Keychain

    private func keychain(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func setKeychain(_ account: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock      // readable with the phone locked, once unlocked since restart
        SecItemAdd(add as CFDictionary, nil)
    }
}
