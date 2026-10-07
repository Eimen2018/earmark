import Foundation
import Security

/// Translates one caption line into Amharic with Gemini, through OpenRouter.
/// This is the only thing in Earmark that sends call text off the Mac, and only for the line she picks.
/// Numbers, dates, addresses and IDs are swapped for placeholders first and put back afterwards,
/// so those details never leave the Mac.
enum Translator {
    static let model = "google/gemini-3.8-flash"

    private static let instructions = """
        You translate single lines from phone calls for a professional English–Amharic interpreter. \
        Translate the English line into natural, clear Amharic in Ge'ez script. \
        Use the polite form (እርስዎ) when the line addresses someone. \
        For specialist US terms (insurance, legal, benefits: deductible, copay, prior authorization, SNAP, EBT, pay stubs) \
        give the Amharic meaning and keep the English term in brackets. \
        Write clock times in digits with a.m./p.m. (for example 9:00 a.m.) so they can't be read as Ethiopian time. \
        The line may contain placeholders like {1}; copy each one into the translation exactly once, unchanged. \
        Ignore filler words like um. Reply with only the Amharic translation.
        """

    enum Failure: LocalizedError {
        case badKey, noCredit, busy, offline, server(Int), empty

        var errorDescription: String? {
            switch self {
            case .badKey: "OpenRouter didn't accept the key. Check it under Captions › Amharic Translation."
            case .noCredit: "The OpenRouter account is out of credit."
            case .busy: "Too many requests. Try again in a moment."
            case .offline: "Couldn't translate: no internet connection."
            case .server(let code): "Couldn't translate (OpenRouter error \(code)). Try again."
            case .empty: "Couldn't translate this line. Try again."
            }
        }
    }

    static func translate(_ text: String, details: [Detail] = [], key: String) async throws -> String {
        // Swap each detail for {1}, {2}… so the numbers themselves never leave the Mac.
        var masked = ""
        var values: [String] = []
        var cursor = text.startIndex
        for detail in details where detail.range.lowerBound >= cursor {
            masked += text[cursor..<detail.range.lowerBound]
            values.append(String(text[detail.range]))
            masked += "{\(values.count)}"
            cursor = detail.range.upperBound
        }
        masked += text[cursor...]

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/Eimen2018/earmark", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Earmark", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 400,
            // Gemini 3 can't switch reasoning off; minimal keeps a line around two seconds.
            "reasoning": ["effort": "minimal"],
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": masked],
            ],
        ] as [String: Any])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut].contains(error.code) {
            throw Failure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw Failure.badKey
        case 402: throw Failure.noCredit
        case 429: throw Failure.busy
        default:
            log.error("translation failed: HTTP \(status, privacy: .public)")
            throw Failure.server(status)
        }

        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        guard var amharic = try? JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines), !amharic.isEmpty else { throw Failure.empty }

        // Put the details back. Any the model dropped go on the end, so a number is never lost.
        var missing: [String] = []
        for (i, value) in values.enumerated() {
            let placeholder = "{\(i + 1)}"
            if amharic.contains(placeholder) { amharic = amharic.replacingOccurrences(of: placeholder, with: value) }
            else { missing.append(value) }
        }
        if !missing.isEmpty { amharic += " · " + missing.joined(separator: " · ") }
        return amharic
    }
}

/// Her OpenRouter key, kept in the login Keychain.
enum TranslationKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.aymen.Earmark",
        kSecAttrAccount as String: "openrouter",
    ]

    static func load() -> String? {
        var result: AnyObject?
        var lookup = query
        lookup[kSecReturnData as String] = true
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("keychain save failed: \(status, privacy: .public)") }
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
