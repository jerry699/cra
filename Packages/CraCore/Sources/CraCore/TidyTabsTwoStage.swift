import Foundation

/// Tidy Tabs in two stages, sized for small local models: first three to six topic names that cover
/// every tab, then a closed-book pass that assigns each tab id to one topic number. The answers are
/// plain JSON (the local model is held to the grammar below); `TidyTabs.plan()` still makes the
/// final call, so bad ids or one-tab groups never reach the sidebar.
public enum TidyTabsTwoStage {
    public static let minimumTopics = 1
    public static let maximumTopics = 6
    public static let maximumTopicLength = 24

    public static let topicsInstructions = """
    You sort a person's open browser tabs into topic groups, like tidying loose papers into \
    labelled folders. Propose three to six short topic names that together cover ALL the tabs \
    below. Use the tab titles' own language, two to four words each, no website names.
    """

    public static func assignmentsInstructions(topics: [String]) -> String {
        let listing = topics.enumerated().map { "\($0.offset). \($0.element)" }.joined(separator: "\n")
        return """
        You assign each browser tab to exactly one topic from a fixed list. For every tab id give \
        the topic number (0 to \(max(topics.count - 1, 0))).

        Topics:
        \(listing)
        """
    }

    /// `{"topics": ["…"]}`, nothing else: what topics.gbnf allows.
    public static let topicsGrammar = """
    root ::= "{" ws "\\"topics\\"" ws ":" ws "[" ws string (ws "," ws string)* ws "]" ws "}"
    string ::= "\\"" ( [^"\\\\\\x7F\\x00-\\x1F] | "\\\\" (["\\\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]) )* "\\""
    ws ::= [ \\t\\n]*
    """

    /// `{"assignments": [{"id": 0, "topic": 1}, …]}`, compact: every token spent here is a token not
    /// spent on the answer.
    public static let assignmentsGrammar = """
    root ::= "{" "\\"assignments\\"" ":" "[" item ("," item)* "]" "}"
    item ::= "{" "\\"id\\"" ":" integer "," "\\"topic\\"" ":" integer "}"
    integer ::= [0-9]+
    """

    /// The topics in the model's answer, or nil when it isn't the object the grammar allows.
    public static func topics(from answer: String) -> [String]? {
        guard let object = json(answer), let list = object["topics"] as? [Any] else { return nil }
        let topics = list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !topics.isEmpty else { return nil }
        return Array(topics.prefix(maximumTopics)).map { TidyTabs.clip($0, maximumTopicLength) }
    }

    /// Tab id → topic number. Ids the answer repeats keep their first topic; ids and topics outside
    /// the prompt are dropped, as are tabs the answer left out (they stay loose).
    public static func assignments(from answer: String, tabCount: Int, topics: Int) -> [Int: Int]? {
        guard let object = json(answer), let rows = object["assignments"] as? [Any] else { return nil }
        var out: [Int: Int] = [:]
        for row in rows {
            guard let row = row as? [String: Any], let id = row["id"] as? Int, let topic = row["topic"] as? Int else { continue }
            guard id >= 0, id < tabCount, topic >= 0, topic < topics, out[id] == nil else { continue }
            out[id] = topic
        }
        guard !out.isEmpty else { return nil }
        return out
    }

    /// What `TidyTabs.plan()` takes: one group per topic that got tabs, in topic order. Plan drops
    /// the ones with fewer than two tabs, merges repeats and makes ids safe.
    public static func proposals(topics: [String], assignments: [Int: Int]) -> [TidyTabs.Proposal] {
        var byTopic: [[Int]] = Array(repeating: [], count: topics.count)
        for (id, topic) in assignments where topic >= 0 && topic < topics.count {
            byTopic[topic].append(id)
        }
        return topics.enumerated().compactMap { topic, name in
            byTopic[topic].isEmpty ? nil : TidyTabs.Proposal(name: name, tabs: byTopic[topic].sorted())
        }
    }

    static func json(_ answer: String) -> [String: Any]? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8))) as? [String: Any]
    }
}
