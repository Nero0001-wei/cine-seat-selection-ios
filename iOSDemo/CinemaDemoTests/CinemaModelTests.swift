import XCTest
@testable import CinemaDemo

@MainActor
final class CinemaModelTests: XCTestCase {
    func testSeatLayoutHasStableUniqueIdentifiers() {
        XCTAssertEqual(TheaterLayout.seats.count, 168)
        XCTAssertEqual(Set(TheaterLayout.seats.map(\.id)).count, 168)
        XCTAssertEqual(TheaterLayout.center.id, "G08")
        XCTAssertEqual(TheaterLayout.center.title, "7排8座")
        XCTAssertEqual(TheaterLayout.side.id, "G03")
        XCTAssertEqual(TheaterLayout.front.id, "C08")
    }

    func testRowsUseTheSamePhysicalLayoutAsPreviewCamera() throws {
        let first = try XCTUnwrap(TheaterLayout.seat(row: 1, column: 8))
        for row in 1...12 {
            let seat = try XCTUnwrap(TheaterLayout.seat(row: row, column: 8))
            XCTAssertEqual(seat.position.y, Float(row - 1) * 0.30, accuracy: 0.001,
                           "每排应逐级升高0.30米")
            XCTAssertEqual(seat.position.x, first.position.x, accuracy: 0.001)
            guard row > 1 else { continue }
            let previous = try XCTUnwrap(TheaterLayout.seat(row: row - 1, column: 8))
            let expectedPitch: Float = row == 5 || row == 9 ? 2.50 : 1.05
            XCTAssertEqual(seat.position.z - previous.position.z, expectedPitch, accuracy: 0.001,
                           "只有4/5排、8/9排之间应额外留出横向过道")
        }
    }

    func testSeatedEyePositionClearsEveryFrontRowBackrest() {
        let screenBottom = TheaterLayout.screenBottomPosition
        for seat in TheaterLayout.seats {
            let eye = TheaterLayout.seatedEyePosition(for: seat)
            XCTAssertTrue(eye.x.isFinite && eye.y.isFinite && eye.z.isFinite, seat.id)
            XCTAssertEqual(eye.x, seat.position.x, accuracy: 0.0001, seat.id)
            XCTAssertEqual(eye.z, seat.position.z + TheaterLayout.seatedEyeForwardOffset,
                           accuracy: 0.0001, seat.id)
            XCTAssertGreaterThanOrEqual(eye.y - seat.position.y,
                                       TheaterLayout.seatedEyeBaseHeight - 0.0001, seat.id)

            for frontRow in 1..<seat.row {
                let backrest = TheaterLayout.backrestTopPosition(row: frontRow)
                let fraction = (backrest.z - screenBottom.z) / (eye.z - screenBottom.z)
                XCTAssertGreaterThan(fraction, 0, seat.id)
                XCTAssertLessThan(fraction, 1, seat.id)
                let rayHeight = screenBottom.y + (eye.y - screenBottom.y) * fraction
                XCTAssertGreaterThanOrEqual(rayHeight,
                                           backrest.y + TheaterLayout.sightlineClearance - 0.0002,
                                           "\(seat.id)看银幕下沿的视线必须越过第\(frontRow)排椅背")
            }
        }
    }

    func testSeatedEyesFollowTierElevationWithoutUnnecessaryExtraHeight() throws {
        let screenBottom = TheaterLayout.screenBottomPosition
        var previousEyeY: Float?
        for row in 1...TheaterLayout.rowCount {
            let seat = try XCTUnwrap(TheaterLayout.seat(row: row, column: 8))
            let eye = TheaterLayout.seatedEyePosition(for: seat)
            let localHeight = TheaterLayout.seatedEyeHeight(for: seat)
            XCTAssertEqual(eye.y, seat.position.y + localHeight, accuracy: 0.0001)
            if let previousEyeY {
                XCTAssertGreaterThan(eye.y, previousEyeY, "后排眼位应随真实台阶升高")
            }
            previousEyeY = eye.y

            guard localHeight > TheaterLayout.seatedEyeBaseHeight + 0.0002 else {
                XCTAssertEqual(localHeight, TheaterLayout.seatedEyeBaseHeight, accuracy: 0.0002)
                continue
            }
            let clearances = (1..<row).map { frontRow -> Float in
                let backrest = TheaterLayout.backrestTopPosition(row: frontRow)
                let fraction = (backrest.z - screenBottom.z) / (eye.z - screenBottom.z)
                return screenBottom.y + (eye.y - screenBottom.y) * fraction
                    - backrest.y - TheaterLayout.sightlineClearance
            }
            let limitingClearance = try XCTUnwrap(clearances.min())
            XCTAssertEqual(limitingClearance, 0, accuracy: 0.0002,
                           "高于基础眼位的抬升必须由实际前排遮挡约束，避免把坐姿变成悬空视角")
        }
    }

    func testTwoHorizontalCrossAislesContainNoSeats() {
        let aisles = TheaterLayout.crossAisles
        XCTAssertEqual(aisles.count, 2)
        XCTAssertEqual(aisles.map(\.afterRow), [4, 8])
        for aisle in aisles {
            XCTAssertEqual(aisle.width, 1.45, accuracy: 0.001)
            XCTAssertEqual(aisle.endZ - aisle.startZ, 1.45, accuracy: 0.001)
            XCTAssertEqual(aisle.centerZ, (aisle.startZ + aisle.endZ) / 2, accuracy: 0.001)
            XCTAssertEqual(aisle.elevation, Float(aisle.afterRow - 1) * 0.30, accuracy: 0.001)
            XCTAssertEqual(aisle.startZ - TheaterLayout.rowZ(aisle.afterRow), 0.525, accuracy: 0.001)
            XCTAssertEqual(TheaterLayout.rowZ(aisle.afterRow + 1) - aisle.endZ, 0.525, accuracy: 0.001)
            let seatsInside = TheaterLayout.seats.filter {
                $0.position.z > aisle.startZ && $0.position.z < aisle.endZ
            }
            XCTAssertTrue(seatsInside.isEmpty, "横向过道必须是连续无座空间")
        }
    }

    func testFrontMiddleRearSectionsCoverEveryRowExactlyOnce() {
        let sections = TheaterLayout.sections
        XCTAssertEqual(sections.map(\.rawValue), ["前区", "中区", "后区"])
        XCTAssertEqual(Array(SeatingSection.front.rows), [1, 2, 3, 4])
        XCTAssertEqual(Array(SeatingSection.middle.rows), [5, 6, 7, 8])
        XCTAssertEqual(Array(SeatingSection.rear.rows), [9, 10, 11, 12])
        XCTAssertEqual(sections.flatMap { Array($0.rows) }, Array(1...12))
        for seat in TheaterLayout.seats {
            XCTAssertEqual(sections.filter { $0.rows.contains(seat.row) }.count, 1,
                           "每个座位应恰好归属一个前中后分区")
            XCTAssertTrue(seat.section.rows.contains(seat.row))
        }
        for section in sections {
            XCTAssertEqual(TheaterLayout.seats.filter { section.rows.contains($0.row) }.count, 56)
        }
    }

    func testAllFourteenColumnsRemainContinuousInEveryRow() throws {
        for row in 1...12 {
            let seats = TheaterLayout.seats.filter { $0.row == row }.sorted { $0.column < $1.column }
            XCTAssertEqual(seats.map(\.column), Array(1...14))
            for column in 2...14 {
                let previous = try XCTUnwrap(TheaterLayout.seat(row: row, column: column - 1))
                let next = try XCTUnwrap(TheaterLayout.seat(row: row, column: column))
                XCTAssertEqual(next.position.x - previous.position.x, 0.74, accuracy: 0.001,
                               "每排14座连续排列，旧纵向分块边界不再留空")
                XCTAssertEqual(next.position.y, previous.position.y, accuracy: 0.001)
                XCTAssertEqual(next.position.z, previous.position.z, accuracy: 0.001)
            }
        }
    }

    func testCompanionCanCrossTheFormerColumnBlockBoundaries() {
        for column in [4, 10] {
            let store = CinemaStore()
            let first = Seat(row: 3, column: column)
            let expected = Seat(row: 3, column: column + 1)
            XCTAssertFalse(first.isSold)
            XCTAssertFalse(expected.isSold)
            store.select(first)
            XCTAssertTrue(store.canSelectCompanion)
            XCTAssertEqual(store.companion, expected)
            store.selectCompanion()
            XCTAssertEqual(store.selectedIDs, Set([first.id, expected.id]))
            XCTAssertEqual(store.total, 136)
        }
    }

    func testRearViewPresetIsAvailableAndSelectsItsPhysicalSeat() {
        let rear = ViewZone.rear.seat
        XCTAssertEqual(rear.id, "K08")
        XCTAssertEqual(rear.title, "11排8座")
        XCTAssertTrue(SeatingSection.rear.rows.contains(rear.row))
        XCTAssertFalse(rear.isSold)
        XCTAssertEqual(ViewZone(seat: rear), .rear)
        let store = CinemaStore()
        store.preview(rear)
        XCTAssertTrue(store.selectedSeats.isEmpty)
        XCTAssertEqual(store.previewSeat, rear)
        store.choosePreview(rear)
        XCTAssertEqual(store.selectedIDs, ["K08"])
    }

    func testSoldSeatCannotBeAdded() throws {
        let store = CinemaStore()
        let sold = try XCTUnwrap(TheaterLayout.seats.first(where: \.isSold))
        store.select(sold)
        store.toggleSelection(sold)
        XCTAssertTrue(store.selectedSeats.isEmpty)
        XCTAssertEqual(store.total, 0)
    }

    func testPreviewDoesNotReserveOrSelectSeat() {
        let store = CinemaStore()
        store.preview(TheaterLayout.center)
        XCTAssertEqual(store.previewSeat?.id, "G08")
        XCTAssertTrue(store.selectedSeats.isEmpty)
        store.closePreview()
        XCTAssertNil(store.previewSeat)
    }

    func testPreviewZoneChangesDoNotModifyExistingSelection() {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        store.selectCompanion()
        let selection = store.selectedIDs
        store.preview(TheaterLayout.center)
        for seat in [TheaterLayout.side, TheaterLayout.front, TheaterLayout.rear, TheaterLayout.center] {
            store.preview(seat)
            let eye = TheaterLayout.seatedEyePosition(for: seat)
            XCTAssertEqual(TheaterLayout.seatedEyePosition(for: seat), eye,
                           "重复求眼位应保持确定性")
            XCTAssertEqual(store.previewSeat, seat)
            XCTAssertEqual(store.selectedIDs, selection, "眼位和视角切换不应改动已选座位")
        }
        XCTAssertEqual(store.selectedIDs, selection)
        XCTAssertEqual(store.total, 136)
        store.closePreview()
        XCTAssertEqual(store.selectedIDs, selection)
    }

    func testStructurePreviewLifecycleRequiresAnOpenSeatPreview() {
        let store = CinemaStore()
        XCTAssertFalse(store.showsStructure)
        store.toggleStructurePreview()
        XCTAssertFalse(store.showsStructure)

        store.preview(TheaterLayout.center)
        XCTAssertFalse(store.showsStructure)
        store.toggleStructurePreview()
        XCTAssertTrue(store.showsStructure)
        store.select(TheaterLayout.center)
        store.selectCompanion()
        store.lightsOn = false
        XCTAssertTrue(store.showsStructure, "选择和灯光变化不应退出结构视图")

        store.closePreview()
        XCTAssertFalse(store.showsStructure)
        store.toggleStructurePreview()
        XCTAssertFalse(store.showsStructure)
        store.preview(TheaterLayout.rear)
        XCTAssertFalse(store.showsStructure)
        store.toggleStructurePreview()
        XCTAssertTrue(store.showsStructure)
        store.reset()
        XCTAssertFalse(store.showsStructure)
        XCTAssertNil(store.previewSeat)
    }

    func testChangingSeatsPreservesStructureModeWithoutChangingSelection() {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        store.selectCompanion()
        let selection = store.selectedIDs
        store.preview(TheaterLayout.center)
        store.toggleStructurePreview()
        store.preview(TheaterLayout.rear)
        XCTAssertTrue(store.showsStructure)
        XCTAssertEqual(store.previewSeat, TheaterLayout.rear)
        store.preview(TheaterLayout.front)
        XCTAssertTrue(store.showsStructure)
        XCTAssertEqual(store.previewSeat, TheaterLayout.front)
        XCTAssertEqual(store.selectedIDs, selection)
        XCTAssertEqual(store.total, 136)
        store.toggleStructurePreview()
        XCTAssertFalse(store.showsStructure)
        XCTAssertEqual(store.selectedIDs, selection)
    }

    func testChoosePreviewReplacesOnlyOriginWithoutDuplicatingSeats() throws {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        store.selectCompanion()
        let origin = try XCTUnwrap(store.focusedSeat)
        store.preview(origin)
        store.preview(TheaterLayout.side)
        store.choosePreview(TheaterLayout.side)
        XCTAssertEqual(store.selectedIDs, ["G08", "G03"])
        XCTAssertFalse(store.selectedIDs.contains(origin.id))
        store.choosePreview(TheaterLayout.side)
        store.choosePreview(TheaterLayout.center)
        XCTAssertEqual(store.selectedSeats.count, 2)
        XCTAssertEqual(store.selectedIDs, ["G08", "G03"])

        store.closePreview()
        store.preview(TheaterLayout.front)
        store.choosePreview(TheaterLayout.front)
        XCTAssertEqual(store.selectedIDs, ["G08", "C08"])
        XCTAssertEqual(store.total, 136)
    }

    func testSelectionIsIdempotentAndToggleRemoves() {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        store.select(TheaterLayout.center)
        XCTAssertEqual(store.selectedSeats.count, 1)
        XCTAssertEqual(store.selectedIDs, ["G08"])
        store.toggleSelection(TheaterLayout.center)
        XCTAssertTrue(store.selectedSeats.isEmpty)
    }

    func testMaximumTwoSeatsAndPriceUsesActualSelection() {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        store.select(TheaterLayout.side)
        store.select(TheaterLayout.front)
        XCTAssertEqual(store.selectedSeats.count, 2)
        XCTAssertEqual(store.total, store.selectedSeats.reduce(0) { $0 + $1.price })
        XCTAssertEqual(store.total, 136)
    }

    func testCompanionIsAdjacentAndDoesNotDuplicate() {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        XCTAssertTrue(store.canSelectCompanion)
        store.selectCompanion()
        XCTAssertEqual(store.selectedSeats.count, 2)
        XCTAssertEqual(Set(store.selectedSeats.map(\.row)), [7])
        let columns = store.selectedSeats.map(\.column).sorted()
        XCTAssertEqual(columns[1] - columns[0], 1)
        XCTAssertFalse(store.selectedSeats.contains(where: \.isSold))
        store.selectCompanion()
        XCTAssertEqual(store.selectedSeats.count, 2)
    }

    func testClearResetsSelectedPrice() {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        store.selectCompanion()
        store.clear()
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertEqual(store.total, 0)
    }

    func testEmptySelectionCannotCreateReservation() async {
        let store = CinemaStore()
        await store.reserve()
        guard case .idle = store.reservation else {
            return XCTFail("空选座不能创建预留")
        }
    }

    func testReservationPreservesSelectedSeats() async {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        store.selectCompanion()
        let before = store.selectedIDs
        await store.reserve()
        guard case .held = store.reservation else {
            return XCTFail("可选座位应进入已预留状态")
        }
        XCTAssertEqual(store.selectedIDs, before)
        XCTAssertEqual(store.total, 136)
    }

    func testConflictKeepsTheStillValidSeatAndCanRecover() async {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        store.selectCompanion()
        store.simulateConflict = true
        await store.reserve()
        XCTAssertEqual(store.reservation, .conflict)
        XCTAssertEqual(store.selectedIDs, ["G08"])
        store.recoverConflict()
        XCTAssertEqual(store.reservation, .idle)
        XCTAssertTrue(store.canSelectCompanion)
    }

    func testClearingDuringReservationCannotProduceStaleSuccess() async throws {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        let pending = Task { await store.reserve() }
        try await Task.sleep(for: .milliseconds(30))
        store.clear()
        await pending.value
        XCTAssertEqual(store.reservation, .idle)
        XCTAssertTrue(store.selectedSeats.isEmpty)
        XCTAssertNil(store.reservationExpiresAt)
    }

    func testExpiredReservationCanBeHeldAgain() async throws {
        let store = CinemaStore()
        store.select(TheaterLayout.center)
        await store.reserve()
        let expiration = try XCTUnwrap(store.reservationExpiresAt)
        store.checkExpiration(now: expiration.addingTimeInterval(1))
        XCTAssertEqual(store.reservation, .idle)
        XCTAssertNil(store.reservationExpiresAt)
        XCTAssertEqual(store.selectedIDs, ["G08"])
    }
}
