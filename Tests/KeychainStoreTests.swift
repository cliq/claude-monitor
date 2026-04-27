import XCTest
@testable import ClaudeMonitor

final class KeychainStoreTests: XCTestCase {
    private let testService = "com.cliq.ClaudeMonitor.tests.prowl-\(UUID().uuidString)"
    private var store: KeychainStore!

    override func setUp() {
        super.setUp()
        store = KeychainStore(service: testService, account: "default")
        try? store.delete()
    }

    override func tearDown() {
        try? store.delete()
        super.tearDown()
    }

    func test_returnsNilWhenNoEntryExists() throws {
        XCTAssertNil(try store.get())
    }

    func test_setAndGetRoundTrip() throws {
        try store.set("abc-123")
        XCTAssertEqual(try store.get(), "abc-123")
    }

    func test_setOverwritesExistingValue() throws {
        try store.set("first")
        try store.set("second")
        XCTAssertEqual(try store.get(), "second")
    }

    func test_deleteRemovesValue() throws {
        try store.set("to-be-deleted")
        try store.delete()
        XCTAssertNil(try store.get())
    }

    func test_deleteIsIdempotent() throws {
        try store.delete()
        XCTAssertNoThrow(try store.delete())
    }
}
