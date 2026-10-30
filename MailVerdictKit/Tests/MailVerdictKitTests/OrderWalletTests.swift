import XCTest

@testable import MailVerdictKit

/// Wallet logic that needs no network: the timeline split, the persisted view, key-fact links, the
/// brightness hold and the offline copy of an order.
final class OrderWalletTests: XCTestCase {

    private func item(
        _ day: String?, kind: OrderKind = .ticket, id: UUID = UUID(),
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> OrderListItem {
        OrderListItem(
            id: id, merchant: "m", subject: "s", status: "", title: "", isOpen: true, icon: "ticket",
            summaryPreview: "", firstMailAt: nil, lastMailAt: nil, mailCount: 1, accountIds: [], textStale: false,
            updatedAt: updatedAt, kind: kind, eventStart: day, timelineDate: day)
    }

    // MARK: - Timeline

    func testTimelineHasFutureAndTodayAboveTheMarkerAndPastBelow() {
        let future2 = item("2026-05-20"), future1 = item("2026-05-12")
        let todays = item("2026-05-10")
        let past1 = item("2026-05-02"), past2 = item("2026-01-15")
        // Deliberately out of order: the timeline must not depend on how the pages arrived.
        let built = OrderTimeline.build(items: [past1, future1, todays, past2, future2], today: "2026-05-10")

        XCTAssertEqual(
            built.entries,
            [.order(future2), .order(future1), .order(todays), .today, .order(past1), .order(past2)])
        XCTAssertEqual(built.todayIndex, 3)
        XCTAssertEqual(built.upcomingCount, 3)
    }

    func testTimelineMarkerIsPresentWhenNothingIsAheadOrNothingHasPassed() {
        let past = item("2026-01-01"), future = item("2026-12-01")
        XCTAssertEqual(OrderTimeline.build(items: [past], today: "2026-05-10").entries, [.today, .order(past)])
        XCTAssertEqual(OrderTimeline.build(items: [future], today: "2026-05-10").entries, [.order(future), .today])
        XCTAssertEqual(OrderTimeline.build(items: [], today: "2026-05-10").entries, [.today])
    }

    func testTimelineKeepsTheServersOrderWithinADayAndPutsUndatedTicketsLast() {
        let a = item("2026-03-01"), b = item("2026-03-01"), undated = item(nil), c = item("2026-03-01")
        let built = OrderTimeline.build(items: [a, undated, b, c], today: "2026-05-10")
        XCTAssertEqual(built.entries, [.today, .order(a), .order(b), .order(c), .order(undated)])
    }

    func testTimelineFallsBackToTheEventStartWhenNoTimelineDateCame() {
        var dated = item(nil)
        dated = OrderListItem(
            id: dated.id, merchant: "m", subject: "s", status: "", title: "", isOpen: true, icon: "ticket",
            summaryPreview: "", firstMailAt: nil, lastMailAt: nil, mailCount: 1, accountIds: [], textStale: false,
            updatedAt: dated.updatedAt, eventStart: "2026-06-01", timelineDate: nil)
        let built = OrderTimeline.build(items: [dated], today: "2026-05-10")
        XCTAssertEqual(built.entries, [.order(dated), .today])
    }

    func testTodayIsTheCalendarDayInTheGivenZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        // 23:30 UTC on the 9th is already the 10th in Berlin in May.
        let instant = Date(timeIntervalSince1970: 1_778_369_400)
        XCTAssertEqual(MVOrderDay.string(for: instant, calendar: calendar), "2026-05-10")
        XCTAssertNotNil(MVOrderDay.date(from: "2026-05-10", calendar: calendar))
        XCTAssertNil(MVOrderDay.date(from: "soon", calendar: calendar))
    }

    func testEventDaysReadAsWeekdayDayMonthWithTheYearOnlyWhenNotCurrent() {
        let now = MVOrderDay.date(from: "2026-05-10")!
        XCTAssertEqual(MVDateFormat.eventDay("2026-10-31", now: now), "Sat 31 Oct")
        XCTAssertEqual(MVDateFormat.eventDay("2027-01-04", now: now), "Mon 4 Jan 2027")
        XCTAssertEqual(MVDateFormat.eventDay("someday", now: now), "someday")
        XCTAssertEqual(
            MVDateFormat.eventRange(start: "2026-10-31", end: "2026-11-02", now: now), "Sat 31 Oct – Mon 2 Nov")
        XCTAssertEqual(MVDateFormat.eventRange(start: "2026-10-31", end: "2026-10-31", now: now), "Sat 31 Oct")
        XCTAssertEqual(MVDateFormat.eventRange(start: "2026-10-31", end: nil, now: now), "Sat 31 Oct")
        XCTAssertNil(MVDateFormat.eventRange(start: nil, end: "2026-11-02", now: now))
    }

    // MARK: - View state

    private func makeDefaults() -> UserDefaults {
        let suite = "OrderWalletTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTheViewStateSurvivesAnotherLaunch() {
        let defaults = makeDefaults()
        XCTAssertEqual(OrderViewPersistence(defaults: defaults).load(), OrderViewState())
        let chosen = OrderViewState(kind: .tickets, open: true, favorites: true)
        OrderViewPersistence(defaults: defaults).save(chosen)
        XCTAssertEqual(OrderViewPersistence(defaults: defaults).load(), chosen)
    }

    func testAnUnreadableSavedViewIsTheDefaultViewAndAnUnknownKindIsAll() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "mv.orders.view")
        XCTAssertEqual(OrderViewPersistence(defaults: defaults).load(), OrderViewState())
        defaults.set(Data(#"{"kind":"gadgets","open":true}"#.utf8), forKey: "mv.orders.view")
        XCTAssertEqual(OrderViewPersistence(defaults: defaults).load(), OrderViewState(kind: .all, open: true))
    }

    func testEachChoiceIsADifferentListIdentity() {
        var identities: Set<String> = []
        for kind in OrderKindFilter.allCases {
            for open in [false, true] {
                for favorites in [false, true] {
                    identities.insert(OrderViewState(kind: kind, open: open, favorites: favorites).identity)
                }
            }
        }
        XCTAssertEqual(identities.count, 12)
    }

    // MARK: - Key facts

    private func fact(_ kind: OrderFactKind, value: String, trackingUrl: String? = nil, code: OrderCodeOut? = nil)
        -> OrderFactOut
    {
        OrderFactOut(id: UUID(), kind: kind, label: "", value: value, trackingUrl: trackingUrl, code: code)
    }

    func testOnlyWebAddressesOpenFromAFact() {
        XCTAssertEqual(
            fact(.trackingNumber, value: "123", trackingUrl: "https://dhl.example/track?n=123").linkURL?.host,
            "dhl.example")
        XCTAssertEqual(fact(.link, value: " https://shop.example/manage ").linkURL?.host, "shop.example")
        XCTAssertNil(fact(.trackingNumber, value: "123", trackingUrl: nil).linkURL)
        XCTAssertNil(fact(.link, value: "javascript:alert(1)").linkURL)
        XCTAssertNil(fact(.link, value: "tel:+4912345").linkURL)
        // A scheme the app could hand to another app, with a host that makes it look like a link.
        XCTAssertNil(fact(.link, value: "ftp://files.example/ticket").linkURL)
        XCTAssertNil(fact(.link, value: "mailverdict://app/open").linkURL)
        XCTAssertNil(fact(.trackingNumber, value: "1", trackingUrl: "file://host/etc/passwd").linkURL)
        XCTAssertNil(fact(.link, value: "not a link").linkURL)
        // A tracking number's own value is never treated as a link, only the server's built URL.
        XCTAssertNil(fact(.trackingNumber, value: "https://evil.example").linkURL)
        XCTAssertNil(fact(.orderNumber, value: "https://evil.example").linkURL)
    }

    func testAFactWithoutALabelIsNamedByItsKindAndACodeCopiesItsPayload() {
        XCTAssertEqual(fact(.bookingCode, value: "X").displayLabel, "Booking")
        let code = OrderCodeOut(format: "QR", payloadText: "5471205382", imageUrl: "/api/x.png", page: 1)
        XCTAssertEqual(fact(.code, value: "", code: code).copyText, "5471205382")
        XCTAssertEqual(fact(.code, value: "Ticketcode", code: code).copyText, "Ticketcode")
        XCTAssertNil(
            fact(.code, value: "", code: OrderCodeOut(format: "Aztec", payloadText: nil, imageUrl: "/x", page: nil))
                .copyText)
    }

    func testAnUnknownFactKindAndOrderKindDecodeAsOther() throws {
        let kind = try JSONDecoder().decode(OrderFactKind.self, from: Data(#""frequent_flyer""#.utf8))
        XCTAssertEqual(kind, .other)
        let order = try JSONDecoder().decode(OrderKind.self, from: Data(#""voucher""#.utf8))
        XCTAssertEqual(order, .other)
    }

    // MARK: - Brightness

    func testBrightnessReturnsToWhatThePersonHadAndOnlyOnce() {
        var hold = MVBrightnessHold()
        XCTAssertNil(hold.release())
        XCTAssertEqual(hold.engage(current: 0.4), 1.0)
        // The scene coming back to active while the code is still up must not save the raised value.
        XCTAssertNil(hold.engage(current: 1.0))
        XCTAssertEqual(hold.release(), 0.4)
        // Disappearing after the scene already restored it restores nothing more.
        XCTAssertNil(hold.release())
        XCTAssertFalse(hold.isEngaged)
        XCTAssertEqual(hold.engage(current: 0.7), 1.0)
        XCTAssertEqual(hold.release(), 0.7)
    }

    // MARK: - Uploads

    func testHeicIsConvertedAndEverythingElseIsSentAsItIs() {
        XCTAssertTrue(OrderUploadFile.needsJPEGConversion(contentType: "image/heic", filename: "a"))
        XCTAssertTrue(OrderUploadFile.needsJPEGConversion(contentType: nil, filename: "IMG_0001.HEIC"))
        XCTAssertFalse(OrderUploadFile.needsJPEGConversion(contentType: "image/jpeg", filename: "a.jpg"))
        XCTAssertFalse(OrderUploadFile.needsJPEGConversion(contentType: "application/pdf", filename: "t.pdf"))
        XCTAssertEqual(OrderUploadFile.jpegFilename(for: "IMG_0001.HEIC"), "IMG_0001.jpg")
        XCTAssertEqual(OrderUploadFile.jpegFilename(for: ""), "image.jpg")
    }

    // MARK: - Offline copy

    private func makeCache(budget: MVOfflineCache.Budget = .init()) -> MVOfflineCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("order-cache-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MVOfflineCache(directory: directory, budget: budget)
    }

    private func detail(_ id: UUID = UUID(), facts: [OrderFactOut] = []) -> OrderDetail {
        OrderDetail(
            id: id, merchant: "Deutsche Bahn", subject: "Aachen to Berlin", status: "ticket issued", title: "t",
            isOpen: true, icon: "train", summaryPreview: "p", firstMailAt: nil, lastMailAt: nil, mailCount: 1,
            accountIds: [], textStale: false, updatedAt: Date(timeIntervalSince1970: 1_000), summary: "s",
            facts: facts, mails: [], documents: [], kind: .ticket, eventStart: "2026-06-01", timelineDate: "2026-06-01")
    }

    func testAnOrderAndItsCodeComeBackFromTheOfflineCopy() async {
        let cache = makeCache()
        let code = OrderCodeOut(format: "Aztec", payloadText: nil, imageUrl: "/api/orders/x/codes/y.png", page: 1)
        let codeFact = OrderFactOut(id: UUID(), kind: .code, label: "Ticketcode", value: "", code: code)
        let saved = detail(facts: [codeFact])
        await cache.saveOrder(saved)
        await cache.saveOrderCode(Data([0x89, 0x50]), factId: codeFact.id)

        let loaded = await cache.order(id: saved.id)
        XCTAssertEqual(loaded?.detail, saved)
        XCTAssertEqual(loaded?.detail.facts.first?.code?.format, "Aztec")
        let png = await cache.orderCode(factId: codeFact.id)
        XCTAssertEqual(png, Data([0x89, 0x50]))
        let missing = await cache.order(id: UUID())
        XCTAssertNil(missing)
    }

    func testTheOrderCopyIsPerServerAndDiscardedWithIt() async {
        let cache = makeCache()
        let saved = detail()
        await cache.saveOrder(saved)
        await cache.discard()
        let after = await cache.order(id: saved.id)
        XCTAssertNil(after)
        await cache.saveOrder(saved)
        let ignored = await cache.order(id: saved.id)
        XCTAssertNil(ignored, "a discarded cache takes no further saves")
    }

    func testTheOrderCopyKeepsTheMostRecentlyUsedWithinItsBudget() async {
        var budget = MVOfflineCache.Budget()
        budget.orders = 2
        let clock = Clock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("order-cache-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = MVOfflineCache(directory: directory, budget: budget, now: { clock.tick() })
        let a = detail(), b = detail(), c = detail()
        await cache.saveOrder(a)
        await cache.saveOrder(b)
        _ = await cache.order(id: a.id)  // a is used again, so b is the oldest
        await cache.saveOrder(c)
        let keptA = await cache.order(id: a.id)
        let keptB = await cache.order(id: b.id)
        let keptC = await cache.order(id: c.id)
        XCTAssertNotNil(keptA)
        XCTAssertNil(keptB)
        XCTAssertNotNil(keptC)
    }

    func testOnlyTodaysAndLaterTicketsAreKeptReadyNearestFirst() {
        let past = item("2026-05-01"), todays = item("2026-05-10"), soon = item("2026-05-12"),
            later = item("2026-09-01")
        let order = item("2026-05-11", kind: .order)
        let chosen = OrderOfflineCopy.upcoming(in: [later, past, order, soon, todays], today: "2026-05-10")
        XCTAssertEqual(chosen.map(\.id), [todays.id, soon.id, later.id])
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    func tick() -> Date {
        lock.lock()
        defer { lock.unlock() }
        now += 10
        return now
    }
}
