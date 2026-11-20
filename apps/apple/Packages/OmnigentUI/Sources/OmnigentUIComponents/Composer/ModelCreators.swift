import Foundation

/// Who made a model, as opposed to who serves it (Claude through Bedrock is Anthropic), as the
/// web's `modelCreators` reads it from a catalog row's ids: a `<creator>/<model>` namespace, a
/// Bedrock `<creator>.<model>` prefix, then the model name. The model menu groups long catalogs
/// by it.
nonisolated struct ModelCreator: Hashable, Sendable {
  /// A stable id.
  let id: String
  /// Its name.
  let label: String

  /// Unknown ids stay selectable under this group, which sorts last.
  static let other = Self(id: "other", label: "Other models")

  /// Catalogs at least this long group by creator when they span creators.
  static let browseMinimum = 10

  private struct Rule {
    let creator: ModelCreator
    let namespaces: [String]
    /// A regular expression the lowercased model name matches.
    let models: String
  }

  // Display order. Patterns run against the lowercased name once serving prefixes are removed.
  private static let rules: [Rule] = [
    rule(
      "anthropic", "Anthropic", ["anthropic"],
      #"^(?:claude|(?:opus|sonnet|haiku|fable)(?:$|[-\d\[]))"#),
    rule(
      "openai", "OpenAI", ["openai"],
      #"^(?:gpt|chatgpt|codex|o\d+(?:$|-)|text-embedding|whisper)"#),
    rule("google", "Google", ["google"], #"^(?:gemini|gemma|codegemma|learnlm)"#),
    rule("xai", "xAI", ["xai", "x-ai"], #"^grok"#),
    rule(
      "moonshotai", "Moonshot AI", ["moonshotai", "moonshot", "moonshot-ai"],
      #"^(?:kimi|moonshot)"#),
    rule(
      "zai", "Z.ai", ["zai", "z-ai", "zai-org", "zhipuai", "zhipu", "thudm"],
      #"^(?:zai-)?(?:glm|chatglm|autoglm|codegeex)"#),
    rule("alibaba", "Alibaba / Qwen", ["alibaba", "qwen", "dashscope"], #"^(?:qwen|qwq|qvq)"#),
    rule(
      "meta", "Meta", ["meta", "meta-llama", "facebook"],
      #"^(?:(?:meta-|code)?llama(?!.*nemotron)|muse-spark)"#),
    rule("deepseek", "DeepSeek", ["deepseek", "deepseek-ai"], #"^deepseek"#),
    rule(
      "mistral", "Mistral AI", ["mistral", "mistralai"],
      #"^(?:open-)?(?:mistral|mixtral|codestral|devstral|magistral|ministral|pixtral|voxtral)"#),
    rule("minimax", "MiniMax", ["minimax", "minimaxai"], #"^minimax"#),
    rule("amazon", "Amazon", ["amazon"], #"^(?:nova|titan)-"#),
    rule("cohere", "Cohere", ["cohere", "cohereforai", "coherelabs"], #"^(?:command|c4ai|aya)"#),
    rule("microsoft", "Microsoft", ["microsoft"], #"^(?:phi-?\d|mai-)"#),
    rule("nvidia", "NVIDIA", ["nvidia"], #"nemotron"#),
    rule("bytedance", "ByteDance", ["bytedance", "bytedance-seed"], #"^(?:doubao|seed-)"#),
    rule("xiaomi", "Xiaomi", ["xiaomi", "xiaomimimo"], #"^mimo"#),
    rule("perplexity", "Perplexity", ["perplexity"], #"^sonar"#),
    rule("ibm", "IBM", ["ibm", "ibm-granite"], #"^granite"#),
  ]

  private static func rule(_ id: String, _ label: String, _ namespaces: [String], _ models: String)
    -> Rule
  {
    Rule(creator: Self(id: id, label: label), namespaces: namespaces, models: models)
  }

  /// Path segments that are neither a host nor an organization (`accounts/…/models/<model>`).
  private static let pathSegments: Set<String> = ["accounts", "models"]

  /// The creator of a catalog row, or ``other`` when its ids don't name one.
  /// - Parameters:
  ///   - id: The row's id.
  ///   - model: Its provider model name.
  ///   - displayName: Its display name.
  /// - Returns: The creator.
  static func of(id: String, model: String?, displayName: String?) -> Self {
    var references = [model, id].compactMap(\.self)
    // Under an organization (`host/<org>/<model>`) a display name may name a fine-tune's base.
    if !references.contains(where: { $0.split(separator: "/").count > 2 }) {
      references += [displayName].compactMap(\.self)
    }
    return references.lazy.compactMap(rule(for:)).first?.creator ?? .other
  }

  /// The groups' order: the rules' order, then ``other``.
  var rank: Int { Self.rules.firstIndex { $0.creator == self } ?? Self.rules.count }

  private static func rule(for reference: String) -> Rule? {
    var segments = reference.trimmingCharacters(in: .whitespaces).lowercased()
      .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
      .split(separator: "/").map { segment in
        String(segment.hasPrefix("~") || segment.hasPrefix("@") ? segment.dropFirst() : segment)
      }
      .filter { !$0.isEmpty && !pathSegments.contains($0) }
    guard let name = segments.popLast() else { return nil }
    let local =
      name
      .replacingOccurrences(
        of: #"^(?:databricks-|system\.ai\.)"#, with: "", options: .regularExpression
      )
      .replacingOccurrences(
        of: #"^(?:us|us-gov|eu|apac|jp|au|ca|in|global)\."#, with: "", options: .regularExpression)
    if let dot = local.firstIndex(of: "."), let vendor = namespace(String(local[..<dot])) {
      return vendor
    }
    let owner = segments.last.flatMap(namespace)
    // Under a host the organization published the model; a lone leading namespace is usually
    // the serving provider, so the model's name wins.
    if let owner, segments.count > 1 { return owner }
    return rules.first { local.range(of: $0.models, options: .regularExpression) != nil } ?? owner
  }

  private static func namespace(_ name: String) -> Rule? {
    rules.first { $0.namespaces.contains(name) }
  }
}

nonisolated extension ModelCreator {
  /// `models` by creator, in the groups' order with catalog order within; a single group when
  /// the catalog is shorter than ``browseMinimum`` or one creator made it all.
  static func groups(_ models: [ModelOption]) -> [(creator: ModelCreator, models: [ModelOption])] {
    guard models.count >= browseMinimum else { return [(.other, models)] }
    var order: [ModelCreator] = []
    var grouped: [ModelCreator: [ModelOption]] = [:]
    for model in models {
      let creator = of(id: model.id, model: model.model, displayName: model.displayName)
      if grouped[creator] == nil { order.append(creator) }
      grouped[creator, default: []].append(model)
    }
    guard order.count > 1 else { return [(.other, models)] }
    return order.sorted { $0.rank < $1.rank }.map { ($0, grouped[$0] ?? []) }
  }
}
