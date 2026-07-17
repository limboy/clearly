import XCTest
@testable import ClearlyCore

final class BugReportURLTests: XCTestCase {
    func testBuildPrefillsOnlySafeFormFields() throws {
        let url = BugReportURL.build(
            appVersion: "2.4.0 (240)",
            osVersion: "macOS 26.1"
        )

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(item(named: "template", in: items), "bug_report.yml")
        XCTAssertEqual(item(named: "app-version", in: items), "2.4.0 (240)")
        XCTAssertEqual(item(named: "os-version", in: items), "macOS 26.1")
        XCTAssertNil(item(named: "labels", in: items))
        XCTAssertNil(item(named: "description", in: items))
    }

    private func item(named name: String, in items: [URLQueryItem]) -> String? {
        items.first(where: { $0.name == name })?.value
    }
}
