import XCTest

@MainActor
final class CinemaFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    func testPreviewSwitchingSelectionAndReservation() {
        let recommended = app.buttons["overview.recommend"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 15))
        capture("01-overview")
        recommended.tap()

        let choose = app.buttons["preview.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        let zones = app.segmentedControls["preview.zone"]
        XCTAssertTrue(zones.waitForExistence(timeout: 5))
        zones.buttons["侧边"].tap()
        XCTAssertTrue(app.staticTexts["7排3座"].waitForExistence(timeout: 5))
        settleCamera()
        capture("02-side-view")
        zones.buttons["前排"].tap()
        XCTAssertTrue(app.staticTexts["3排8座"].waitForExistence(timeout: 5))
        settleCamera()
        capture("03-front-view")
        zones.buttons["后排"].tap()
        XCTAssertTrue(app.staticTexts["11排8座"].waitForExistence(timeout: 5))
        settleCamera()
        capture("03c-rear-view")
        zones.buttons["中区"].tap()
        settleCamera()
        capture("03b-center-lights-on")

        let lights = app.segmentedControls["preview.lighting"]
        XCTAssertTrue(lights.exists)
        lights.buttons["放映中"].tap()
        settleCamera()
        capture("04-screening-view")
        lights.buttons["开灯"].tap()
        choose.tap()

        let preview = app.buttons["selection.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let companion = app.buttons["selection.companion"]
        XCTAssertTrue(companion.exists)
        companion.tap()
        capture("05-two-selected")

        let confirm = app.buttons["selection.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let hold = app.buttons["reservation.hold"]
        XCTAssertTrue(hold.waitForExistence(timeout: 5))
        capture("06-confirmation")
        hold.tap()
        XCTAssertTrue(app.staticTexts["reservation.success"].waitForExistence(timeout: 10))
        capture("07-reserved")
    }

    func testRepeatedPreviewEntryAcrossFrontMiddleRearKeepsSelectionAccurate() {
        let recommend = app.buttons["overview.recommend"]
        XCTAssertTrue(recommend.waitForExistence(timeout: 15))
        recommend.tap()
        app.buttons["preview.choose"].tap()
        let preview = app.buttons["selection.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let summary = app.staticTexts["selection.summary"]
        var selectedTitle = "7排8座"

        for (zone, title) in [("前排", "3排8座"), ("后排", "11排8座"), ("中区", "7排8座")] {
            XCTContext.runActivity(named: "重复进入实景：" + zone) { _ in
                preview.tap()
                let zones = app.segmentedControls["preview.zone"]
                XCTAssertTrue(zones.waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts[selectedTitle].waitForExistence(timeout: 5),
                              "重新进入实景必须从当前已选座位开始")
                zones.buttons[zone].tap()
                XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
                app.buttons["preview.back"].tap()
                XCTAssertTrue(summary.waitForExistence(timeout: 5))
                XCTAssertEqual(summary.label, selectedTitle, "退出预览不得替换已选座位")

                preview.tap()
                XCTAssertTrue(zones.waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts[selectedTitle].waitForExistence(timeout: 5))
                zones.buttons[zone].tap()
                XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
                app.buttons["preview.choose"].tap()
                XCTAssertTrue(summary.waitForExistence(timeout: 5))
                XCTAssertEqual(summary.label, title, "反复切换后仍应选择当前视角对应的实际座位")
                XCTAssertTrue(app.buttons["selection.companion"].exists)
                selectedTitle = title
            }
        }
    }

    func testPhysical3DSeatHitTestingSelectsAndDeselectsSeat() {
        let seat = app.buttons["seat.G08"]
        XCTAssertTrue(seat.waitForExistence(timeout: 15))
        settleCamera()
        XCTAssertTrue(seat.isHittable)

        // Coordinate taps exercise ARView's recognizer and entity collision ray;
        // this intentionally does not call the accessibility activation closure.
        let point = seat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.tap()
        let summary = app.staticTexts["selection.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("7排8座"))
        capture("08-physical-seat-hit")

        let selectedSeat = app.buttons["seat.G08"]
        XCTAssertTrue(selectedSeat.waitForExistence(timeout: 5))
        selectedSeat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["overview.recommend"].waitForExistence(timeout: 5))
    }

    func testComparisonChoosesTheOtherViewWithoutAddingAnExtraSeat() {
        let recommended = app.buttons["overview.recommend"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 15))
        recommended.tap()
        let compare = app.buttons["preview.compare"]
        XCTAssertTrue(compare.waitForExistence(timeout: 5))
        settleCamera()
        compare.tap()

        let firstCard = app.descendants(matching: .any)
            .matching(identifier: "comparison.card.A").firstMatch
        let secondCard = app.descendants(matching: .any)
            .matching(identifier: "comparison.card.B").firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        XCTAssertTrue(secondCard.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(firstCard.frame.height, 100)
        XCTAssertGreaterThan(secondCard.frame.height, 100)
        settleCamera()
        capture("09-comparison")

        let chooseB = app.buttons["comparison.chooseB"]
        XCTAssertTrue(chooseB.waitForExistence(timeout: 5))
        if !chooseB.isHittable { app.swipeUp() }
        chooseB.tap()
        let summary = app.staticTexts["selection.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "7排3座")
        XCTAssertTrue(app.buttons["selection.companion"].exists)
    }

    func testStructurePreviewSwitchesSeatsAndReturnsToAccurateTopDownPicking() {
        let recommended = app.buttons["overview.recommend"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 15))
        recommended.tap()
        let structure = app.buttons["preview.structure"]
        XCTAssertTrue(structure.waitForExistence(timeout: 5))
        XCTAssertEqual(structure.value as? String, "座位视角")
        structure.tap()
        XCTAssertEqual(structure.value as? String, "影厅结构")
        let structureScene = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "三维影厅结构，靠近银幕最低，后排逐级升高"
        )).firstMatch
        XCTAssertTrue(structureScene.waitForExistence(timeout: 5))
        settleCamera()
        capture("16-structure-cutaway")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.66, dy: 0.34))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.38))
        start.press(forDuration: 0.05, thenDragTo: end)
        settleCamera()
        XCTAssertEqual(structure.value as? String, "影厅结构")
        capture("17-structure-orbit")

        app.segmentedControls["preview.zone"].buttons["后排"].tap()
        XCTAssertTrue(app.staticTexts["11排8座"].waitForExistence(timeout: 5))
        XCTAssertEqual(structure.value as? String, "影厅结构")
        settleCamera()
        capture("18-structure-rear-selection")
        structure.tap()
        XCTAssertEqual(structure.value as? String, "座位视角")
        settleCamera()
        capture("19-returned-to-rear-seat")

        app.buttons["preview.choose"].tap()
        let summary = app.staticTexts["selection.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "11排8座")
        app.buttons["selection.clear"].tap()
        XCTAssertTrue(recommended.waitForExistence(timeout: 5))
        settleCamera()

        let seat = app.buttons["seat.G08"]
        XCTAssertTrue(seat.waitForExistence(timeout: 5))
        XCTAssertTrue(seat.isHittable)
        seat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "7排8座")
        capture("20-structure-return-physical-pick")
    }

    func testTopDownOverviewKeepsSeatColumnsVerticallyAligned() {
        let first = app.buttons["seat.A08"]
        let middle = app.buttons["seat.G08"]
        let last = app.buttons["seat.L08"]
        for seat in [first, middle, last] {
            XCTAssertTrue(seat.waitForExistence(timeout: 15))
        }
        settleCamera()
        XCTAssertEqual(first.frame.midX, middle.frame.midX, accuracy: 2.5)
        XCTAssertEqual(last.frame.midX, middle.frame.midX, accuracy: 2.5)
        XCTAssertLessThan(first.frame.midY, middle.frame.midY)
        XCTAssertLessThan(middle.frame.midY, last.frame.midY)
        capture("12-top-down-column-alignment")
    }

    func testHorizontalCrossAislesAreVisibleAndDoNotSelectASeat() {
        for id in ["B08", "C08", "D08", "E08", "H08", "I08"] {
            XCTAssertTrue(app.buttons["seat." + id].waitForExistence(timeout: 15), id)
        }
        settleCamera()
        let normalPitch = app.buttons["seat.C08"].frame.midY - app.buttons["seat.B08"].frame.midY
        XCTAssertGreaterThan(normalPitch, 0)

        for (beforeID, afterID, name) in [
            ("D08", "E08", "front-middle"), ("H08", "I08", "middle-rear")
        ] {
            let before = app.buttons["seat." + beforeID].frame
            let after = app.buttons["seat." + afterID].frame
            XCTAssertGreaterThan(after.midY - before.midY, normalPitch * 1.75,
                                 "前中后分区之间应有明显宽于普通排距的横向过道")
            let point = CGPoint(x: (before.midX + after.midX) / 2,
                                y: (before.midY + after.midY) / 2)
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            origin.withOffset(CGVector(dx: point.x - app.frame.minX,
                                       dy: point.y - app.frame.minY)).tap()
            XCTAssertTrue(app.buttons["overview.recommend"].exists,
                          "点击过道空白不得吸附到相邻座位")
            XCTAssertFalse(app.staticTexts["selection.summary"].exists)
            XCTAssertEqual(app.alerts.count, 0)
            capture("15-empty-cross-aisle-" + name)
        }
    }

    func testPhysicalSeatPickingIsAccurateAcrossTheWholeAuditorium() {
        let fixtures = [
            ("A01", "1排1座"), ("A14", "1排14座"),
            ("C08", "3排8座"), ("G03", "7排3座"),
            ("G08", "7排8座"), ("G09", "7排9座"),
            ("L01", "12排1座"), ("L14", "12排14座")
        ]
        XCTAssertTrue(app.buttons["seat.G08"].waitForExistence(timeout: 15))
        settleCamera()
        for (index, fixture) in fixtures.enumerated() {
            let seat = app.buttons["seat." + fixture.0]
            XCTAssertTrue(seat.waitForExistence(timeout: 5), fixture.0)
            XCTAssertTrue(seat.isEnabled, "测试位置应为未售座位：" + fixture.0)
            XCTAssertTrue(seat.isHittable, "完整排座应可见可点：" + fixture.0)
            seat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let summary = app.staticTexts["selection.summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 5), fixture.0)
            XCTAssertEqual(summary.label, fixture.1, "物理点击必须命中用户看到的座位：" + fixture.0)
            capture("13-physical-matrix-" + fixture.0)

            if index.isMultiple(of: 2) {
                app.buttons["selection.clear"].tap()
            } else {
                app.buttons["seat." + fixture.0]
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(app.buttons["overview.recommend"].waitForExistence(timeout: 5))
        }
    }

    func testPhysicalSeatPickingAcceptsVisibleOffCentrePoints() {
        let offsets: [(String, CGVector)] = [
            ("left", CGVector(dx: 0.28, dy: 0.5)),
            ("right", CGVector(dx: 0.72, dy: 0.5)),
            ("upper", CGVector(dx: 0.5, dy: 0.3)),
            ("lower", CGVector(dx: 0.5, dy: 0.7))
        ]
        XCTAssertTrue(app.buttons["seat.G08"].waitForExistence(timeout: 15))
        settleCamera()
        for (name, offset) in offsets {
            let seat = app.buttons["seat.G08"]
            XCTAssertTrue(seat.isHittable)
            seat.coordinate(withNormalizedOffset: offset).tap()
            let summary = app.staticTexts["selection.summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 5), name)
            XCTAssertEqual(summary.label, "7排8座", "座位可见区域内的偏心点击应准确：" + name)
            capture("14-off-centre-" + name)
            app.buttons["selection.clear"].tap()
            XCTAssertTrue(app.buttons["overview.recommend"].waitForExistence(timeout: 5))
        }
    }

    func testPanPinchAndResetKeepTopDownSeatPickingAccurate() {
        let seat = app.buttons["seat.G08"]
        // Track an interior column: a legitimate pan can move edge seats offscreen.
        let cornerSeat = app.buttons["seat.A08"]
        XCTAssertTrue(seat.waitForExistence(timeout: 15))
        XCTAssertTrue(cornerSeat.waitForExistence(timeout: 5))
        settleCamera()
        let initial = seat.frame
        let initialCorner = cornerSeat.frame

        // Both coordinates remain in the unobscured model area, above the dock.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.66, dy: 0.40))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.34, dy: 0.44))
        start.press(forDuration: 0.05, thenDragTo: end)
        let panned = seat.frame
        let pannedCorner = cornerSeat.frame
        let movement = max(frameDifference(initial, panned),
                           frameDifference(initialCorner, pannedCorner))
        XCTAssertGreaterThan(movement, 3, "单指拖动应平移座位投影")
        XCTAssertEqual(app.buttons["seat.A08"].frame.midX, seat.frame.midX, accuracy: 2.5,
                       "平移后列方向应保持正对齐")
        XCTAssertEqual(app.buttons["seat.L08"].frame.midX, seat.frame.midX, accuracy: 2.5,
                       "平移后列方向应保持正对齐")

        // XCUI's app-centred pinch sends two touches within the 3D scene.
        app.pinch(withScale: 1.18, velocity: 0.7)
        XCTAssertGreaterThan(seat.frame.width, panned.width * 1.02,
                             "双指放大应扩大座位的屏幕投影")
        capture("10-pan-and-zoom")

        app.buttons["overview.options"].tap()
        let reset = app.buttons["复位三维视图"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        settleCamera()
        let restored = seat.frame
        XCTAssertEqual(restored.midX, initial.midX, accuracy: 5)
        XCTAssertEqual(restored.midY, initial.midY, accuracy: 5)
        XCTAssertEqual(restored.width, initial.width, accuracy: 5)
        seat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let summary = app.staticTexts["selection.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "7排8座")
        capture("11-reset-physical-pick")
    }

    private func frameDifference(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func settleCamera() {
        // The RealityKit camera interpolation is outside XCTest's UI animation
        // tracking. Allow its 1.15s travel to finish before recording evidence.
        Thread.sleep(forTimeInterval: 1.4)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
