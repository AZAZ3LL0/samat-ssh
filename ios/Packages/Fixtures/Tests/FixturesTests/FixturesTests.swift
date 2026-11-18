import Foundation
import Testing

@testable import Fixtures

@Suite struct FixturesTests {
    @Test func listsDirectoryInNameOrder() throws {
        let paths = try Fixtures.paths(in: "host_metrics")
        #expect(paths.count >= 2)
        #expect(paths == paths.sorted())
        #expect(paths.allSatisfy { $0.hasPrefix("host_metrics/") && $0.hasSuffix(".json") })
    }

    @Test func readsEveryListedFixture() throws {
        for directory in ["agent_info", "host_metrics"] {
            for path in try Fixtures.paths(in: directory) {
                let json = try JSONSerialization.jsonObject(with: Fixtures.data(path))
                #expect(json is [String: Any], "\(path) is not a JSON object")
            }
        }
    }

    @Test func reportsMissingFixture() {
        #expect(throws: Fixtures.Failure.missing("host_metrics/none.json")) {
            try Fixtures.data("host_metrics/none.json")
        }
        #expect(throws: Fixtures.Failure.missing("no_such_schema")) {
            try Fixtures.paths(in: "no_such_schema")
        }
    }
}
