import SwiftUI

struct ModelPR: Codable, Equatable {
  let model: String
  let url: URL

  var number: Int { Int(url.lastPathComponent) ?? 0 }
}

extension Store {
  func loadModelPRs() {
    guard let data = UserDefaults.standard.data(forKey: "modelPRs"),
      let saved = try? JSONDecoder().decode([String: ModelPR].self, from: data)
    else { return }
    modelPRs = saved
  }

  func recordModelPR(_ loop: String, model: String, url: URL) {
    modelPRs[loop] = ModelPR(model: model, url: url)
    if let data = try? JSONEncoder().encode(modelPRs) { UserDefaults.standard.set(data, forKey: "modelPRs") }
  }

  func modelPR(_ loop: String, model: String) -> (pr: ModelPR, pull: PullRequest?)? {
    if let r = modelPRs[loop], r.model == model, pulls[r.number].map({ live($0, loop) }) ?? true {
      return (r, pulls[r.number])
    }
    let title = "chore(loops): \(loop) changes model"
    guard let p = pulls.values.filter({ $0.title == title && live($0, loop) }).max(by: { $0.number < $1.number }) else { return nil }
    return (ModelPR(model: model, url: p.url), p)
  }

  private func live(_ p: PullRequest, _ loop: String) -> Bool {
    if p.open { return true }
    guard p.merged, let merged = p.mergedAt else { return false }
    let agent = paths.runner.appending(path: ".claude/agents/\(loop).md").path
    let read = (try? FileManager.default.attributesOfItem(atPath: agent))?[.modificationDate] as? Date ?? .distantPast
    return merged > read
  }
}
