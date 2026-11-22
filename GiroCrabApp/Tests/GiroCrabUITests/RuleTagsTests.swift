import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Rules that add tags (#580): saving one tags the matching bookings, a rule may
/// leave the category out, and „Tags verwalten“ knows which rules give a tag.
@MainActor
final class RuleTagsTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        model.period = .all
        model.reloadRules()
        XCTAssertNil(model.errorMessage)
    }

    override func tearDown() async throws { model = nil }

    private func tag(_ name: String) throws -> GiroCrabCore.Tag {
        try XCTUnwrap(model.tags.first { $0.name == name }, "no tag \(name)")
    }

    func testDemoRulesGiveTags() throws {
        let urlaub = try tag("Urlaub")
        let reisen = try XCTUnwrap(model.rules.first { $0.name == "Mietwagen" })
        XCTAssertEqual(reisen.categoryId, 0, "the demo's tags-only rule")
        XCTAssertEqual(reisen.tagIds, [urlaub.id])
        XCTAssertEqual(model.rules(addingTag: urlaub.id).map(\.name), ["Mietwagen"])
        XCTAssertTrue(model.rules(addingTag: try tag("Lebensmittel").id).isEmpty)
    }

    func testSavingATagsOnlyRuleTagsTheBookingsAndKeepsTheirCategory() async throws {
        let steuern = try tag("Steuern")
        let rewe = try XCTUnwrap(model.bookings.first { $0.counterparty.localizedCaseInsensitiveContains("REWE") })
        let category = rewe.categoryId
        var rule = model.newRuleDraft()
        rule.name = "Belege"
        rule.pattern = "REWE"
        rule.categoryId = 0
        rule.tagIds = [steuern.id]
        rule.minAmountCents = nil
        rule.maxAmountCents = nil
        let result = try await model.saveRule(rule)
        XCTAssertGreaterThan(try XCTUnwrap(result).application.get(), 0)
        XCTAssertNil(model.errorMessage)
        let after = try XCTUnwrap(model.bookings.first { $0.id == rewe.id })
        XCTAssertTrue(after.tags.contains { $0.id == steuern.id })
        XCTAssertEqual(after.categoryId, category, "a tags-only rule leaves the category alone")
        XCTAssertEqual(model.rules(addingTag: steuern.id).map(\.name), ["Belege"])
    }

    func testSavingAndEditingABookingRuleWithAPurposePattern() async throws {
        let booking = try XCTUnwrap(model.bookings.first { $0.purpose == "Konzertticket" })
        var rule = model.newRuleDraft(from: booking)
        // A pasted purpose does not match while the booking draft still searches the payee.
        rule.pattern = booking.purpose
        let creation = try await model.saveRule(rule)
        let saved = try XCTUnwrap(creation)
        XCTAssertEqual(try saved.application.get(), 0)
        XCTAssertEqual(model.rules.first { $0.id == saved.id }?.pattern, booking.purpose)

        rule.id = saved.id
        rule.field = .purpose
        let edit = try await model.saveRule(rule)
        let updated = try XCTUnwrap(edit)
        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(try updated.application.get(), 1)
        model.reloadRules()
        XCTAssertEqual(model.rules.first { $0.id == saved.id }?.field, .purpose)
        XCTAssertEqual(model.bookings.first { $0.id == booking.id }?.categoryId, rule.categoryId)
    }

    func testRuleListCountsTheMatchingBookingsWithTheRuleTags() async throws {
        let urlaub = try tag("Urlaub")
        let rental = try XCTUnwrap(model.rules.first { $0.name == "Mietwagen" })
        let counts = await model.loadRuleTagCounts()
        let loaded = try XCTUnwrap(counts)
        XCTAssertEqual(Set(loaded.keys), Set(model.rules.filter { $0.enabled && !$0.tagIds.isEmpty }.map(\.id)),
                       "only active rules that add tags")
        let before = try XCTUnwrap(loaded[rental.id])
        XCTAssertGreaterThan(before, 0, "the demo's rental bookings carry „Urlaub“")

        let sixt = try XCTUnwrap(model.bookings.first {
            $0.counterparty.localizedCaseInsensitiveContains("Sixt") && $0.tags.contains { $0.id == urlaub.id }
        })
        model.removeTag(urlaub.id, from: [sixt.id])
        let after = await model.loadRuleTagCounts()
        XCTAssertEqual(after?[rental.id], before - 1, "a tag removed by hand no longer counts")
    }

    func testARuleWithoutCategoryAndTagsIsRefused() async throws {
        var rule = model.newRuleDraft()
        rule.pattern = "REWE"
        rule.categoryId = 0
        rule.tagIds = []
        do {
            _ = try await model.saveRule(rule)
            XCTFail("Expected saving a rule without a category or tags to fail")
        } catch let error as CoreError {
            guard case .InvalidInput = error else { throw error }
        }
    }
}
