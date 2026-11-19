import Foundation

struct TokenContext {
    var deviceName = ""
    var modelName = ""
    var company = ""
    var profileName = ""
}

/// Dynamic text tokens for watermarks, headers, footers and file names.
enum Tokens {
    static let help = "{user} {fullname} {date} {time} {datetime} {device} {model} {company} {host} {profile}"

    private static let userName = NSUserName()
    private static let fullName = NSFullUserName()
    private static let hostName = Host.current().localizedName ?? ""

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let dateF = formatter("yyyy-MM-dd")
    private static let timeF = formatter("HH:mm")
    private static let fileTimeF = formatter("HH.mm.ss")

    static func resolve(_ text: String, _ ctx: TokenContext, date: Date = Date(), fileSafe: Bool = false) -> String {
        guard text.contains("{") else { return text }
        let d = dateF.string(from: date)
        let t = fileSafe ? fileTimeF.string(from: date) : timeF.string(from: date)
        let pairs: [(String, String)] = [
            ("{user}", userName),
            ("{fullname}", fullName),
            ("{datetime}", "\(d) \(t)"),
            ("{date}", d),
            ("{time}", t),
            ("{device}", ctx.deviceName),
            ("{model}", ctx.modelName),
            ("{company}", ctx.company),
            ("{host}", hostName),
            ("{profile}", ctx.profileName),
        ]
        var out = text
        for (token, value) in pairs where out.contains(token) {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }
}
