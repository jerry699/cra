import CraCore
import Testing

/// The two-stage Tidy Tabs prompt and parsing: topics first, then a closed-book assignment.
struct TidyTabsTwoStageTests {
    @Test func topicsParsedAndClipped() {
        #expect(TidyTabsTwoStage.topics(from: #"{"topics":["京都旅行","购物","Cra 项目"]}"#) == ["京都旅行", "购物", "Cra 项目"])
        // Model noise around the object is tolerated; empty names and extras are not.
        let answer = #"sure: {"topics":["京都旅行","  ","购物","一","二","三","四"]}"#
        #expect(TidyTabsTwoStage.topics(from: answer) == ["京都旅行", "购物", "一", "二", "三", "四"])
        #expect(TidyTabsTwoStage.topics(from: #"{"topics":[]}"#) == nil)
        #expect(TidyTabsTwoStage.topics(from: "not json") == nil)
    }

    @Test func assignmentsDropDuplicatesAndOutOfRange() {
        let answer = """
        {"assignments":[{"id":0,"topic":0},{"id":1,"topic":1},{"id":1,"topic":0},\
        {"id":99,"topic":0},{"id":2,"topic":9},{"id":3,"topic":2}]}
        """
        let m = TidyTabsTwoStage.assignments(from: answer, tabCount: 4, topics: 3)
        #expect(m == [0: 0, 1: 1, 3: 2])
        #expect(TidyTabsTwoStage.assignments(from: #"{"assignments":[]}"#, tabCount: 4, topics: 3) == nil)
    }

    @Test func proposalsFollowTopicOrderAndPlanMakesGroups() {
        let topics = ["京都旅行", "购物", "Cra 项目"]
        let proposals = TidyTabsTwoStage.proposals(topics: topics,
                                                   assignments: [5: 0, 0: 0, 7: 1, 1: 2, 2: 2, 3: 1])
        #expect(proposals == [.init(name: "京都旅行", tabs: [0, 5]),
                              .init(name: "购物", tabs: [3, 7]),
                              .init(name: "Cra 项目", tabs: [1, 2])])
        // A topic with one tab makes no group; a name matching Today's group adds to it.
        let plan = TidyTabs.plan(TidyTabsTwoStage.proposals(topics: ["旅行", "购物", "杂项"],
                                                            assignments: [0: 0, 1: 0, 2: 1, 3: 2]),
                                 tabCount: 4, existingGroups: ["购物"])
        #expect(plan.newGroups == [.init(name: "旅行", tabs: [0, 1])])
        #expect(plan.joins == [0: [2]])
    }

    @Test func instructionsNameEveryTopic() {
        let text = TidyTabsTwoStage.assignmentsInstructions(topics: ["A", "B", "C"])
        #expect(text.contains("0. A\n1. B\n2. C"))
        #expect(text.contains("0 to 2"))
        #expect(TidyTabsTwoStage.assignmentsInstructions(topics: []).contains("0 to 0"))
    }
}
