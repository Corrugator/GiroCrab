import XCTest
@testable import GiroCrabUI

/// Sync feedback when nothing was written (#1703).
final class CloudSyncFeedbackTests: XCTestCase {
    func testEmptyVaultWithoutMergeIsReportedAsNotSaved() {
        let note = CloudSyncManager.skippedWriteNote(mergeOnly: false, wrote: false, merged: false)
        XCTAssertNotNil(note)
        XCTAssertFalse(note?.contains("aktualisiert") ?? true)
    }

    func testNoNoteWhenWritten() {
        XCTAssertNil(CloudSyncManager.skippedWriteNote(mergeOnly: false, wrote: true, merged: false))
        XCTAssertNil(CloudSyncManager.skippedWriteNote(mergeOnly: false, wrote: true, merged: true))
    }

    func testNoNoteWhenSomethingWasMerged() {
        XCTAssertNil(CloudSyncManager.skippedWriteNote(mergeOnly: false, wrote: false, merged: true))
    }

    func testNoNoteForMergeOnlyRun() {
        XCTAssertNil(CloudSyncManager.skippedWriteNote(mergeOnly: true, wrote: false, merged: false))
    }
}
