import Foundation

public enum NavigationURLPolicy {
    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 2_048,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parts.host?.isEmpty == false,
              parts.user == nil,
              parts.password == nil else { return nil }
        parts.scheme = scheme
        return parts.string
    }
}
