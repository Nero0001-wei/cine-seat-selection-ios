import Foundation
import Observation
import simd

struct Seat: Identifiable, Hashable, Sendable {
    let row: Int
    let column: Int

    var id: String { String(UnicodeScalar(64 + row)!) + String(format: "%02d", column) }
    var title: String { "\(row)排\(column)座" }
    var price: Int { 68 }
    var isSold: Bool { TheaterLayout.soldIDs.contains(id) }
    var position: SIMD3<Float> { TheaterLayout.position(row: row, column: column) }
    var section: SeatingSection { TheaterLayout.sections.first { $0.rows.contains(row) }! }
    var description: String {
        if column <= 3 || column >= 12 { return "\(section.rawValue) · 靠近侧边梯道" }
        switch section {
        case .front: return "前区 · 更靠近银幕"
        case .middle: return "中区 · 靠近银幕中轴"
        case .rear: return "后区 · 视点更高，纵览银幕"
        }
    }
}

enum SeatingSection: String, CaseIterable, Identifiable, Sendable {
    case front = "前区", middle = "中区", rear = "后区"
    var id: String { rawValue }
    var rows: ClosedRange<Int> {
        switch self {
        case .front: 1...4
        case .middle: 5...8
        case .rear: 9...12
        }
    }
}

struct TheaterCrossAisle: Sendable {
    let afterRow: Int
    var startZ: Float { TheaterLayout.rowZ(afterRow) + TheaterLayout.rowPitch / 2 }
    var endZ: Float { startZ + width }
    var centerZ: Float { (startZ + endZ) / 2 }
    var width: Float { TheaterLayout.crossAisleWidth }
    var elevation: Float { TheaterLayout.rowElevation(afterRow) }
}

enum TheaterLayout {
    static let rowCount = 12
    static let columnCount = 14
    static let columnPitch: Float = 0.74
    static let rowPitch: Float = 1.05
    static let rowRise: Float = 0.30
    static let firstRowZ: Float = -6.4
    static let crossAisleWidth: Float = 1.45
    static let sections = SeatingSection.allCases
    static let crossAisles = [TheaterCrossAisle(afterRow: 4), TheaterCrossAisle(afterRow: 8)]
    static let floorWidth: Float = 13.2
    static let sideAisleX: Float = 5.95
    static let roomFrontZ: Float = -10.5
    static var roomBackZ: Float { rowZ(rowCount) + 2.2 }
    static var roomDepth: Float { roomBackZ - roomFrontZ }
    static var roomCenterZ: Float { (roomFrontZ + roomBackZ) / 2 }
    static let overviewSpan: Float = 17.2
    static let overviewCenterZ: Float = -1.35

    // Shared screen geometry keeps the rendered curved frame and sightline target in sync.
    static let screenWidth: Float = 12
    static let filmHeight: Float = screenWidth * 9 / 16
    static let frameWidth: Float = screenWidth + 0.24
    static let frameHeight: Float = filmHeight + 0.24
    static let screenRadius: Float = 29.4 * (screenWidth / 10.8)
    static let filmDepthOffset: Float = 0.025
    static let frameDepthOffset: Float = -0.035
    // Grow upwards from the same lower edge so a larger screen does not lower sightlines.
    static var screenCenterPosition: SIMD3<Float> { SIMD3(0, 0.395 + frameHeight / 2, roomFrontZ + 0.3) }

    // Shared sightline geometry, matching the upholstery in the scene.
    static let seatedEyeBaseHeight: Float = 1.45
    static let seatedEyeForwardOffset: Float = 0.045
    static let seatBackrestHeight: Float = 1.11
    static let seatBackrestTopZOffset: Float = 0.26
    static let sightlineClearance: Float = 0.05
    static var screenBottomPosition: SIMD3<Float> {
        // Both curved outer-frame corners are nearer the viewer than the centre.
        // This conservative full-width envelope includes their bow and the frame's bottom.
        let halfWidth = frameWidth / 2
        let bow = screenRadius - sqrt(screenRadius * screenRadius - halfWidth * halfWidth)
        let center = screenCenterPosition
        return SIMD3(0, center.y - frameHeight / 2, center.z + frameDepthOffset + bow)
    }

    static let soldIDs: Set<String> = [
        "A04", "A10", "B02", "B11", "C03", "C12", "D06", "D07", "D13",
        "E02", "E05", "E11", "F04", "F06", "F07", "F10", "F13",
        "G05", "G11", "H02", "H06", "H07", "H12", "I04", "I09",
        "J03", "J07", "J08", "J12", "K05", "K10", "L03", "L09"
    ]
    static let seats: [Seat] = (1...rowCount).flatMap { row in
        (1...columnCount).map { Seat(row: row, column: $0) }
    }
    static let center = Seat(row: 7, column: 8)
    static let side = Seat(row: 7, column: 3)
    static let front = Seat(row: 3, column: 8)
    static let rear = Seat(row: 11, column: 8)

    static func seat(row: Int, column: Int) -> Seat? {
        guard (1...rowCount).contains(row), (1...columnCount).contains(column) else { return nil }
        return Seat(row: row, column: column)
    }

    static func rowZ(_ row: Int) -> Float {
        let precedingAisles = crossAisles.filter { $0.afterRow < row }.count
        return firstRowZ + Float(row - 1) * rowPitch + Float(precedingAisles) * crossAisleWidth
    }

    static func rowElevation(_ row: Int) -> Float { Float(row - 1) * rowRise }

    static func position(row: Int, column: Int) -> SIMD3<Float> {
        SIMD3((Float(column) - Float(columnCount + 1) / 2) * columnPitch,
              rowElevation(row), rowZ(row))
    }

    /// The top of a conservative full-row backrest envelope. Using every row keeps
    /// a diagonal view clear when its ray passes over a different seat column.
    static func backrestTopPosition(row: Int) -> SIMD3<Float> {
        SIMD3(0, rowElevation(row) + seatBackrestHeight, rowZ(row) + seatBackrestTopZOffset)
    }

    static func seatedEyeHeight(for seat: Seat) -> Float {
        let floor = rowElevation(seat.row)
        let bottom = screenBottomPosition
        let eyeZ = rowZ(seat.row) + seatedEyeForwardOffset
        let eyeDepth = eyeZ - bottom.z
        var minimumWorldY = floor + seatedEyeBaseHeight
        guard seat.row > 1, eyeDepth > 0 else { return seatedEyeBaseHeight }

        for row in 1..<seat.row {
            let backrest = backrestTopPosition(row: row)
            let backrestDepth = backrest.z - bottom.z
            guard backrestDepth > 0, backrestDepth < eyeDepth else { continue }
            // At each front row, the bottom-edge ray must be above the backrest
            // plus its safety clearance. Solve that inequality for world eye Y.
            let requiredWorldY = bottom.y
                + (backrest.y + sightlineClearance - bottom.y) * eyeDepth / backrestDepth
            minimumWorldY = max(minimumWorldY, requiredWorldY)
        }
        return minimumWorldY - floor
    }

    static func seatedEyePosition(for seat: Seat) -> SIMD3<Float> {
        let position = seat.position
        return SIMD3(position.x, position.y + seatedEyeHeight(for: seat),
                     position.z + seatedEyeForwardOffset)
    }

    static func sameBlock(_ a: Seat, _ b: Seat) -> Bool {
        a.row == b.row
    }
}

enum ViewZone: String, CaseIterable, Identifiable {
    case front = "前排", center = "中区", rear = "后排", side = "侧边"
    var id: String { rawValue }
    var seat: Seat {
        switch self {
        case .front: TheaterLayout.front
        case .center: TheaterLayout.center
        case .rear: TheaterLayout.rear
        case .side: TheaterLayout.side
        }
    }
    init(seat: Seat) {
        if seat.row <= 4 { self = .front }
        else if seat.row >= 9 { self = .rear }
        else { self = (seat.column <= 3 || seat.column >= 12) ? .side : .center }
    }
}

enum ReservationState: Equatable { case idle, holding, held, conflict }

@MainActor @Observable
final class CinemaStore {
    private(set) var selectedSeats: [Seat] = []
    var previewSeat: Seat?
    private(set) var showsStructure = false
    var lightsOn = true
    var resetToken = 0
    private(set) var reservation: ReservationState = .idle
    private(set) var reservationExpiresAt: Date?
    var simulateConflict = false
    var notice: String?
    private var reservationGeneration = 0
    private var previewedSelectionID: String?

    var selectedIDs: Set<String> { Set(selectedSeats.map(\.id)) }
    var total: Int { selectedSeats.reduce(0) { $0 + $1.price } }
    var focusedSeat: Seat? { selectedSeats.last }
    var companion: Seat? {
        guard selectedSeats.count == 1, let first = selectedSeats.first else { return nil }
        return [first.column + 1, first.column - 1]
            .compactMap { TheaterLayout.seat(row: first.row, column: $0) }
            .first { !$0.isSold && TheaterLayout.sameBlock(first, $0) }
    }
    var canSelectCompanion: Bool { reservation == .idle && companion != nil }

    func select(_ seat: Seat) {
        guard reservation == .idle else { return }
        guard !seat.isSold else { notice = "这个座位已售，请选择其他位置"; return }
        guard !selectedIDs.contains(seat.id) else { return }
        guard selectedSeats.count < 2 else { notice = "最多选择 2 个座位，请先移除一个"; return }
        selectedSeats.append(seat)
    }

    func toggleSelection(_ seat: Seat) {
        guard reservation == .idle else { return }
        if let index = selectedSeats.firstIndex(of: seat) { selectedSeats.remove(at: index) }
        else { select(seat) }
    }

    func preview(_ seat: Seat) {
        guard !seat.isSold else { notice = "这个座位已售，请选择其他位置"; return }
        if previewSeat == nil {
            previewedSelectionID = focusedSeat?.id
            showsStructure = false
        }
        previewSeat = seat
    }

    func toggleStructurePreview() {
        guard previewSeat != nil else { return }
        showsStructure.toggle()
    }

    func choosePreview(_ seat: Seat) {
        guard reservation == .idle, !seat.isSold else { return }
        if selectedIDs.contains(seat.id) { return }
        if let previous = previewedSelectionID,
           let index = selectedSeats.firstIndex(where: { $0.id == previous }) {
            selectedSeats[index] = seat
        } else { select(seat) }
    }

    func closePreview() {
        previewSeat = nil
        previewedSelectionID = nil
        showsStructure = false
    }
    func selectCompanion() { if let companion { select(companion) } }

    func clear() {
        reservationGeneration += 1
        selectedSeats.removeAll()
        reservation = .idle
        reservationExpiresAt = nil
    }

    func reserve() async {
        guard !selectedSeats.isEmpty, reservation == .idle else { return }
        reservationGeneration += 1
        let generation = reservationGeneration
        reservation = .holding
        do { try await Task.sleep(for: .milliseconds(850)) }
        catch {
            if generation == reservationGeneration { reservation = .idle }
            return
        }
        guard generation == reservationGeneration, !selectedSeats.isEmpty else { return }
        if simulateConflict {
            simulateConflict = false
            if selectedSeats.count > 1 { selectedSeats.removeLast() }
            reservation = .conflict
        } else {
            reservation = .held
            reservationExpiresAt = Date().addingTimeInterval(300)
        }
    }

    func recoverConflict() { reservation = .idle }

    func checkExpiration(now: Date = .now) {
        if reservation == .held, let reservationExpiresAt, now >= reservationExpiresAt {
            self.reservationExpiresAt = nil
            reservation = .idle
            notice = "座位保留时间已结束，可以重新保留"
        }
    }

    func reset() {
        clear()
        previewSeat = nil
        showsStructure = false
        previewedSelectionID = nil
        lightsOn = true
        resetToken += 1
        notice = nil
    }
}
