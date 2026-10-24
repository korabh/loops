import SwiftUI

struct AccountProfile {
  let email: String
  let name: String?
  let organization: String?

  var initials: String {
    let source = name?.isEmpty == false ? name! : email
    let words = source.split(whereSeparator: { !$0.isLetter }).prefix(2)
    return words.compactMap(\.first).map { String($0).uppercased() }.joined()
  }

  static func read(_ dir: String) -> AccountProfile? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = dir == "\(home)/.claude" ? "\(home)/.claude.json" : "\(dir)/.claude.json"
    guard let data = FileManager.default.contents(atPath: path),
      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let account = obj["oauthAccount"] as? [String: Any],
      let email = account["emailAddress"] as? String
    else { return nil }
    let org = account["organizationName"] as? String
    return AccountProfile(
      email: email, name: (account["displayName"] as? String) ?? (account["fullName"] as? String),
      organization: org?.hasSuffix("'s Organization") == true ? "Personal" : org)
  }
}
