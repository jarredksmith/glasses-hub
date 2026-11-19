import Foundation
import HubCore

/// Finds and downloads subtitle files from OpenSubtitles.com.
enum SubtitleSearch {
    struct Title: Identifiable, Hashable {
        let id: Int
        let title: String
        let year: String
        let isSeries: Bool
    }
    struct Version: Identifiable, Hashable {
        /// The file to download.
        let id: Int
        let release: String
        let downloads: Int
        let hearingImpaired: Bool
    }
    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let languages: [(code: String, name: String, speech: String)] = [
        ("en", "English", "en-US"), ("es", "Spanish", "es-ES"), ("fr", "French", "fr-FR"),
        ("de", "German", "de-DE"), ("it", "Italian", "it-IT"), ("pt-br", "Portuguese", "pt-BR"),
        ("nl", "Dutch", "nl-NL"), ("sv", "Swedish", "sv-SE"),
    ]
    static func speech(_ code: String) -> String { languages.first { $0.code == code }?.speech ?? "en-US" }

    /// A key that came with the app, if this build has one.
    static var builtInKey: String {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SubtitleKey") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return key.hasPrefix("$(") ? "" : key
    }

    private static func number(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func request(_ path: String, _ query: [String: String], key: String) -> URLRequest? {
        var parts = URLComponents(string: "https://api.opensubtitles.com/api/v1/" + path)
        // the service wants its parameters in alphabetical order and lower case
        parts?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value.lowercased()) }
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "Api-Key")
        request.setValue("GlassesHub v2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw Problem(message: "Couldn't reach the subtitle service. Check the connection.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200...299: return body
        case 401, 403: throw Problem(message: "The subtitle service didn't accept the search key.")
        case 406: throw Problem(message: (body["message"] as? String) ?? "Today's download limit is used up. Try again tomorrow.")
        case 429: throw Problem(message: "Too many searches at once. Wait a moment and try again.")
        default: throw Problem(message: (body["message"] as? String) ?? "The subtitle service had a problem (\(status)).")
        }
    }

    /// Movies and shows whose name matches.
    static func titles(_ query: String, key: String) async throws -> [Title] {
        guard let request = request("features", ["query": query], key: key) else { return [] }
        let body = try await send(request)
        var out = [Title]()
        for item in body["data"] as? [[String: Any]] ?? [] {
            let fields = item["attributes"] as? [String: Any] ?? [:]
            guard let id = number(fields["feature_id"]) ?? number(item["id"]), let title = fields["title"] as? String, !title.isEmpty else { continue }
            let kind = (fields["feature_type"] as? String ?? "").lowercased()
            guard kind != "episode" else { continue }
            let year = (fields["year"] as? String) ?? number(fields["year"]).map(String.init) ?? ""
            out.append(Title(id: id, title: title, year: year, isSeries: kind == "tvshow"))
        }
        return out
    }

    /// The subtitle files there are for a movie, or one episode of a show, most downloaded first.
    static func versions(of title: Title, season: Int, episode: Int, language: String, key: String) async throws -> [Version] {
        var query = ["languages": language, "order_by": "download_count", "order_direction": "desc"]
        if title.isSeries {
            query["parent_feature_id"] = String(title.id); query["season_number"] = String(season); query["episode_number"] = String(episode)
        } else {
            query["id"] = String(title.id)
        }
        guard let request = request("subtitles", query, key: key) else { return [] }
        let body = try await send(request)
        var out = [Version]()
        for item in body["data"] as? [[String: Any]] ?? [] {
            let fields = item["attributes"] as? [String: Any] ?? [:]
            guard let file = (fields["files"] as? [[String: Any]])?.first, let id = number(file["file_id"]) else { continue }
            let release = (fields["release"] as? String) ?? (file["file_name"] as? String) ?? "Subtitles"
            out.append(Version(id: id, release: release, downloads: number(fields["download_count"]) ?? 0,
                               hearingImpaired: fields["hearing_impaired"] as? Bool ?? false))
        }
        return out
    }

    /// The text of one subtitle file.
    static func download(_ version: Version, key: String) async throws -> String {
        guard var request = request("download", [:], key: key) else { throw Problem(message: "Couldn't ask for the file.") }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["file_id": version.id, "sub_format": "srt"])
        let body = try await send(request)
        guard let link = body["link"] as? String, let url = URL(string: link) else {
            throw Problem(message: (body["message"] as? String) ?? "The subtitle service didn't send the file.")
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return SubtitleFile.decode(data)
        } catch { throw Problem(message: "The download didn't finish. Try again.") }
    }
}

/// Subtitle files kept on the phone.
enum SubtitleShelf {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func save(_ text: String, as name: String) -> Bool {
        (try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil
    }
    static func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return SubtitleFile.decode(data)
    }
    static func remove(_ name: String) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
}
