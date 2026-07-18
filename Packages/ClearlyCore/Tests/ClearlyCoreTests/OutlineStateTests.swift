import XCTest
@testable import ClearlyCore

final class OutlineStateTests: XCTestCase {
    func testDefaultWidthAndRangeClamping() {
        let state = OutlineState()
        XCTAssertGreaterThanOrEqual(state.width, OutlineState.minWidth)
        XCTAssertLessThanOrEqual(state.width, OutlineState.maxWidth)

        state.width = 100
        XCTAssertEqual(state.width, OutlineState.minWidth)

        state.width = 500
        XCTAssertEqual(state.width, OutlineState.maxWidth)

        state.width = 300
        XCTAssertEqual(state.width, 300)
    }
}
