// Tests/UpdateCheckerTests.swift
import XCTest
@testable import ClaudeMonitor

final class UpdateCheckerTests: XCTestCase {

    // MARK: isNewer

    func test_isNewer_basicComparisons() {
        XCTAssertTrue(UpdateChecker.isNewer("1.5.0", than: "1.4.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.4.0", than: "1.5.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.5.0", than: "1.5.0"))
    }

    func test_isNewer_numericNotLexicographic() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.0", than: "1.10.0"))
    }

    func test_isNewer_toleratesVPrefix() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.6.0", than: "1.5.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.6.0", than: "v1.5.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.5.0", than: "v1.5.0"))
    }

    func test_isNewer_missingComponentsCountAsZero() {
        XCTAssertFalse(UpdateChecker.isNewer("1.5", than: "1.5.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.5.0", than: "1.5"))
        XCTAssertTrue(UpdateChecker.isNewer("1.5.1", than: "1.5"))
    }

    func test_isNewer_suffixedComponentsCompareNumerically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.6.0-beta", than: "1.5.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.5.0-beta", than: "1.5.0"))
    }

    func test_isNewer_garbageNeverWins() {
        XCTAssertFalse(UpdateChecker.isNewer("", than: "1.5.0"))
        XCTAssertFalse(UpdateChecker.isNewer("banana", than: "1.5.0"))
    }

    // MARK: parseLatestRelease

    private func releaseJSON(tag: String = "v1.6.0",
                             url: String = "https://github.com/cliq/claude-monitor/releases/tag/v1.6.0") -> Data {
        let json: [String: Any] = ["tag_name": tag, "html_url": url, "name": tag, "draft": false]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func test_parseLatestRelease_stripsVPrefixAndParsesURL() {
        let update = UpdateChecker.parseLatestRelease(releaseJSON())
        XCTAssertEqual(update?.version, "1.6.0")
        XCTAssertEqual(update?.url.absoluteString, "https://github.com/cliq/claude-monitor/releases/tag/v1.6.0")
    }

    func test_parseLatestRelease_keepsTagWithoutVPrefix() {
        XCTAssertEqual(UpdateChecker.parseLatestRelease(releaseJSON(tag: "1.6.0"))?.version, "1.6.0")
    }

    func test_parseLatestRelease_rejectsMissingFieldsAndGarbage() {
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parseLatestRelease(try! JSONSerialization.data(withJSONObject: ["html_url": "https://x.y"])))
        XCTAssertNil(UpdateChecker.parseLatestRelease(try! JSONSerialization.data(withJSONObject: ["tag_name": "v1.6.0"])))
        XCTAssertNil(UpdateChecker.parseLatestRelease(try! JSONSerialization.data(withJSONObject: ["tag_name": "v", "html_url": "https://x.y"])))
    }

    // MARK: check() against an injected transport

    private func http(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: UpdateChecker.latestReleaseURL, statusCode: status,
                        httpVersion: nil, headerFields: headers)!
    }

    @MainActor
    func test_check_newerVersionSetsAvailableUpdate() async {
        let checker = UpdateChecker(currentVersion: "1.5.0") { [self] _ in
            (releaseJSON(tag: "v1.6.0"), http(200))
        }
        await checker.check()
        XCTAssertEqual(checker.availableUpdate?.version, "1.6.0")
        XCTAssertEqual(checker.lastOutcome, .updateAvailable("1.6.0"))
        XCTAssertNotNil(checker.lastCheckedAt)
    }

    @MainActor
    func test_check_sameVersionMeansUpToDate() async {
        let checker = UpdateChecker(currentVersion: "1.6.0") { [self] _ in
            (releaseJSON(tag: "v1.6.0"), http(200))
        }
        await checker.check()
        XCTAssertNil(checker.availableUpdate)
        XCTAssertEqual(checker.lastOutcome, .upToDate)
    }

    @MainActor
    func test_check_transportErrorIsSilentFailure() async {
        struct Boom: Error {}
        let checker = UpdateChecker(currentVersion: "1.5.0") { _ in throw Boom() }
        await checker.check()
        XCTAssertNil(checker.availableUpdate)
        XCTAssertEqual(checker.lastOutcome, .failed)
    }

    @MainActor
    func test_check_notModifiedKeepsPriorConclusion() async {
        var status = 200
        let checker = UpdateChecker(currentVersion: "1.5.0") { [self] _ in
            defer { status = 304 }
            return (releaseJSON(tag: "v1.6.0"), http(status, headers: ["ETag": "\"abc\""]))
        }
        await checker.check()
        XCTAssertEqual(checker.lastOutcome, .updateAvailable("1.6.0"))
        await checker.check()
        XCTAssertEqual(checker.availableUpdate?.version, "1.6.0")
        XCTAssertEqual(checker.lastOutcome, .updateAvailable("1.6.0"))
    }

    @MainActor
    func test_check_sendsETagOnSecondRequest() async {
        var seenIfNoneMatch: [String?] = []
        let checker = UpdateChecker(currentVersion: "1.5.0") { [self] request in
            seenIfNoneMatch.append(request.value(forHTTPHeaderField: "If-None-Match"))
            return (releaseJSON(), http(200, headers: ["ETag": "\"abc\""]))
        }
        await checker.check()
        await checker.check()
        XCTAssertEqual(seenIfNoneMatch, [nil, "\"abc\""])
    }

    @MainActor
    func test_check_serverErrorIsFailure() async {
        let checker = UpdateChecker(currentVersion: "1.5.0") { [self] _ in
            (Data(), http(500))
        }
        await checker.check()
        XCTAssertEqual(checker.lastOutcome, .failed)
        XCTAssertNil(checker.availableUpdate)
    }
}
