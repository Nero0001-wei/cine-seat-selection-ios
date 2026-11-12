import SwiftUI

private enum DemoRoute: Hashable { case cinema }

struct CinemaRootView: View {
    @State private var store = CinemaStore()
    @State private var path: [DemoRoute] = [.cinema]

    var body: some View {
        NavigationStack(path: $path) {
            FilmDetailView { path.append(.cinema) }
                .navigationDestination(for: DemoRoute.self) { _ in
                    CinemaExperienceView(store: store) {
                        store.reset()
                        path.removeLast()
                    }
                }
        }
        .alert("选座提示", isPresented: Binding(
            get: { store.notice != nil },
            set: { if !$0 { store.notice = nil } }
        )) {
            Button("知道了", role: .cancel) { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }
}

private struct CinemaExperienceView: View {
    @Bindable var store: CinemaStore
    let onExit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showComparison = false
    @State private var showConfirmation = false
    @State private var showSeatPicker = false
    @State private var dockContentHeight: CGFloat?

    private var isPreview: Bool { store.previewSeat != nil }

    private enum DockPresentation: Equatable, Sendable {
        case overview(selectionCount: Int)
        case preview(isStructure: Bool)
    }

    private struct DockMeasurement: Equatable, Sendable {
        let presentation: DockPresentation
        let height: CGFloat
    }

    private var dockPresentation: DockPresentation {
        isPreview ? .preview(isStructure: store.showsStructure)
            : .overview(selectionCount: store.selectedSeats.count)
    }

    var body: some View {
        let presentation = dockPresentation
        return ZStack {
            CinemaTheme.background.ignoresSafeArea()
            GeometryReader { geometry in
                CinemaSceneView(selectedSeatIDs: store.selectedIDs,
                                previewSeat: store.previewSeat,
                                lightsOn: store.lightsOn,
                                resetToken: store.resetToken,
                                reduceMotion: reduceMotion,
                                showsStructure: store.showsStructure,
                                isSceneActive: scenePhase == .active && !showComparison && !showConfirmation && !showSeatPicker) { seat in
                    if store.previewSeat == nil { store.toggleSelection(seat) }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityIdentifier(isPreview ? "preview.scene" : "overview.scene")
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.38), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 100)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.12)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
            }
            .ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 10) {
                Spacer(minLength: 0)
                if !isPreview {
                    if store.selectedSeats.isEmpty {
                        Text("点击座位选择 · 拖动平移 · 双指缩放")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    SeatLegend()
                }
                GlassEffectContainer(spacing: 12) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 0) {
                            if let seat = store.previewSeat {
                                previewDock(seat)
                                    .transition(.identity)
                                    .transaction { $0.animation = nil }
                            } else {
                                overviewDock
                                    .transition(.identity)
                                    .transaction { $0.animation = nil }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Measure the active content at its natural height before
                        // the animated frame constrains it. Never mount a hidden dock.
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: DockMeasurement.self) { geometry in
                            DockMeasurement(presentation: presentation,
                                            height: (geometry.size.height * 2).rounded() / 2)
                        } action: { measurement in
                            guard measurement.presentation == dockPresentation,
                                  measurement.height > 0,
                                  abs(measurement.height - (dockContentHeight ?? 0)) > 0.5 else { return }
                            if dockContentHeight == nil {
                                var initial = Transaction(animation: nil)
                                initial.disablesAnimations = true
                                withTransaction(initial) { dockContentHeight = measurement.height }
                            } else {
                                dockContentHeight = measurement.height
                            }
                        }
                        .frame(height: dockContentHeight, alignment: .bottom)
                        .clipped()
                        .contentShape(.rect)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            // Animate the bottom-anchored panel's natural layout, without passing
            // a SwiftUI animation transaction into the full-screen 3D renderer.
            .animation(reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.02),
                       value: dockContentHeight)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if isPreview { store.closePreview() } else { onExit() }
                } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(isPreview ? "返回影厅总览" : "返回影片")
                .accessibilityIdentifier(isPreview ? "preview.back" : "overview.back")
                .tint(.white)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isPreview {
                    Picker("影厅灯光", selection: $store.lightsOn) {
                        Text("开灯").tag(true)
                        Text("放映中").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .accessibilityIdentifier("preview.lighting")
                } else {
                    Menu {
                        Button("按排号选座", systemImage: "list.number") { showSeatPicker = true }
                        Button("复位三维视图", systemImage: "arrow.counterclockwise") { store.resetToken += 1 }
                        Divider()
                        Toggle("演示库存冲突", isOn: $store.simulateConflict)
                        Button("重新开始", systemImage: "arrow.clockwise") { store.reset() }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("选座选项")
                    .accessibilityIdentifier("overview.options")
                    .tint(.white)
                }
            }
        }
        .sheet(isPresented: $showSeatPicker) { SeatPickerSheet(store: store) }
        .sheet(isPresented: $showComparison) {
            ComparisonSheet(store: store, second: store.previewSeat == TheaterLayout.center
                            ? TheaterLayout.side : store.previewSeat ?? TheaterLayout.side)
        }
        .sheet(isPresented: $showConfirmation) { ReservationSheet(store: store) }
        .sensoryFeedback(.selection, trigger: store.selectedIDs)
        .sensoryFeedback(.selection, trigger: store.previewSeat?.id)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.checkExpiration() }
        }
    }

    private func previewDock(_ seat: Seat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(seat.title).font(.headline)
                Spacer()
                Button(store.showsStructure ? "回到座位" : "影厅结构",
                       systemImage: store.showsStructure ? "eye" : "view.3d") {
                    store.toggleStructurePreview()
                }
                .font(.caption)
                .buttonStyle(.glass).controlSize(.small)
                .frame(minHeight: 40)
                .tint(store.showsStructure ? CinemaTheme.accent : .white)
                .accessibilityIdentifier("preview.structure")
                .accessibilityValue(store.showsStructure ? "影厅结构" : "座位视角")
                Text("¥\(seat.price)").font(.title3.weight(.semibold)).monospacedDigit()
            }
            Text(store.showsStructure ? "靠近银幕最低 · 后排逐级升高" : seat.description)
            .font(.caption).foregroundStyle(.white.opacity(0.8))
            Picker("观影视角", selection: Binding(
                get: { ViewZone(seat: seat) }, set: { store.preview($0.seat) }
            )) {
                ForEach(ViewZone.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 40)
            .accessibilityIdentifier("preview.zone")
            HStack(spacing: 12) {
                PrimaryAction(title: "选这个位置") {
                    store.choosePreview(seat)
                    if store.selectedIDs.contains(seat.id) { store.closePreview() }
                }
                .accessibilityIdentifier("preview.choose")
                Button { showComparison = true } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .frame(minWidth: 24, minHeight: 27)
                }
                .buttonStyle(.glass).controlSize(.large).buttonBorderShape(.circle)
                .tint(.white)
                .accessibilityLabel("比较两个座位的视角")
                .accessibilityIdentifier("preview.compare")
            }
        }
    }

    private var overviewDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("星际穿越 · 19:30 · IMAX 2D")
                .font(.caption).foregroundStyle(.white.opacity(0.72))
            if store.selectedSeats.isEmpty {
                Text("先坐进去看看").font(.title2.weight(.semibold))
                Text("选一个座位，预览你的观影视角")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                PrimaryAction(title: "试坐推荐位置") {
                    store.select(TheaterLayout.center)
                    store.preview(TheaterLayout.center)
                }
                .accessibilityIdentifier("overview.recommend")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.selectedSeats.map(\.id).joined(separator: " + "))
                        .font(.system(size: store.selectedSeats.count == 1 ? 28 : 24,
                                      weight: .medium, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Text("¥\(store.total)").font(.title2.weight(.semibold)).monospacedDigit()
                }
                Text(store.selectedSeats.map(\.title).joined(separator: "、"))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("selection.summary")
                HStack(spacing: 10) {
                    if store.selectedSeats.count == 1 {
                        PrimaryAction(title: "查看观影视角") {
                            if let seat = store.focusedSeat { store.preview(seat) }
                        }
                        .accessibilityIdentifier("selection.preview")
                        Button { showConfirmation = true } label: {
                            Image(systemName: "checkmark").frame(minWidth: 24, minHeight: 27)
                        }
                        .buttonStyle(.glass).controlSize(.large).buttonBorderShape(.circle)
                        .tint(.white)
                        .accessibilityLabel("确认选座")
                        .accessibilityIdentifier("selection.confirm")
                    } else {
                        PrimaryAction(title: "确认这两个座位") { showConfirmation = true }
                            .accessibilityIdentifier("selection.confirm")
                    }
                }
                HStack(spacing: 12) {
                    if let companion = store.companion {
                        SecondaryAction(title: "加选\(companion.title)") { store.selectCompanion() }
                            .accessibilityIdentifier("selection.companion")
                            .frame(maxWidth: .infinity)
                    } else {
                        SecondaryAction(title: "查看座位视角") {
                            if let seat = store.focusedSeat { store.preview(seat) }
                        }
                        .accessibilityIdentifier("selection.preview")
                        .frame(maxWidth: .infinity)
                    }
                    Button { store.clear() } label: {
                        Text("清空").font(.subheadline.weight(.medium))
                            .frame(minWidth: 36, minHeight: 27)
                    }
                        .accessibilityIdentifier("selection.clear")
                }
                .buttonStyle(.glass).controlSize(.large).tint(.white)
            }
        }
    }
}

private struct ComparisonSheet: View {
    @Bindable var store: CinemaStore
    let second: Seat
    @Environment(\.dismiss) private var dismiss
    private let first = TheaterLayout.center
    private let snapshots = CinemaSceneSnapshots.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    comparisonCard(first, label: "A")
                    comparisonCard(second, label: "B")
                    PrimaryAction(title: "选 A · \(first.title) · ¥68") { choose(first) }
                        .accessibilityIdentifier("comparison.chooseA")
                    SecondaryAction(title: "选 B · \(second.title) · ¥68") { choose(second) }
                        .accessibilityIdentifier("comparison.chooseB")
                }
                .padding(20)
            }
            .background(CinemaTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                        .tint(.white).accessibilityIdentifier("comparison.close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func comparisonCard(_ seat: Seat, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image = snapshots.images[CinemaSceneSnapshots.key(for: seat, lightsOn: store.lightsOn)] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    CinemaSceneView(selectedSeatIDs: [], previewSeat: seat, lightsOn: store.lightsOn,
                                    resetToken: 0, reduceMotion: true, allowsTrailer: false,
                                    onSeatTap: { _ in })
                }
            }
            .frame(height: 188).clipped().allowsHitTesting(false)
            HStack {
                Text("\(label) · \(seat.title)").font(.headline)
                Spacer()
                Text(seat == first ? "靠近中轴" : seat.description.components(separatedBy: " · ").first ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(.quaternary, in: .rect(cornerRadius: 24))
        .clipShape(.rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("comparison.card." + label)
    }

    private func choose(_ seat: Seat) {
        store.choosePreview(seat)
        if store.selectedIDs.contains(seat.id) {
            store.closePreview()
            dismiss()
        }
    }
}

private struct SeatPickerSheet: View {
    @Bindable var store: CinemaStore
    @State private var row = 7
    @State private var column = 8
    @Environment(\.dismiss) private var dismiss
    private var seat: Seat { Seat(row: row, column: column) }

    var body: some View {
        NavigationStack {
            Form {
                Section("选择位置") {
                    Picker("排号", selection: $row) {
                        ForEach(1...TheaterLayout.rowCount, id: \.self) { Text("第\($0)排").tag($0) }
                    }
                    Picker("座号", selection: $column) {
                        ForEach(1...TheaterLayout.columnCount, id: \.self) { Text("\($0)座").tag($0) }
                    }
                    LabeledContent("状态", value: seat.isSold ? "已售" : store.selectedIDs.contains(seat.id) ? "已选" : "可选 · ¥68")
                }
                Section {
                    Button("查看\(seat.title)实景") { store.preview(seat); dismiss() }
                    Button(store.selectedIDs.contains(seat.id) ? "移除这个座位" : "加入已选座位") {
                        store.toggleSelection(seat)
                        dismiss()
                    }
                }.disabled(seat.isSold)
            }
            .navigationTitle("按排号选座").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                        .tint(.white)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ReservationSheet: View {
    @Bindable var store: CinemaStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPaymentInfo = false

    var body: some View {
        NavigationStack {
            Group {
                if store.reservation == .held { success }
                else if store.reservation == .conflict { conflict }
                else { confirmation }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CinemaTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).disabled(store.reservation == .holding)
                        .tint(.white)
                }
            }
        }
        .presentationDetents([.height(550), .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(store.reservation == .holding)
        .alert("演示完成", isPresented: $showPaymentInfo) {
            Button("继续体验", role: .cancel) {}
        } message: { Text("这次保留仅在本机模拟，未创建真实订单，也不会扣款。") }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.selectedSeats.count == 1 ? "确认这个座位" : "确认这两个座位")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("星际穿越").font(.headline)
                Text("今天 19:30 · 3号 IMAX 厅 · IMAX 2D")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            List(store.selectedSeats) { seat in
                LabeledContent(seat.title, value: "标准座 · ¥\(seat.price)")
                    .listRowBackground(Color.white.opacity(0.04))
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .contentMargins(.all, 0).scrollDisabled(true)
            .frame(height: CGFloat(store.selectedSeats.count * 48 + 16))
            HStack {
                Text("\(store.selectedSeats.count) 张电影票").foregroundStyle(.secondary)
                Spacer()
                Text("¥\(store.total)").font(.title2.weight(.semibold))
            }
            Text("保留后，请在 5 分钟内完成支付")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            PrimaryAction(title: store.reservation == .holding ? "正在保留座位…" : "保留座位",
                          isLoading: store.reservation == .holding) {
                Task { await store.reserve() }
            }
            .accessibilityIdentifier("reservation.hold")
        }
    }

    private var success: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62)).foregroundStyle(CinemaTheme.accent)
                .symbolRenderingMode(.hierarchical)
            Text("已保留 \(store.selectedSeats.count) 个座位")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("reservation.success")
            Text(store.selectedSeats.map(\.title).joined(separator: " · "))
                .font(.headline)
            if let expiration = store.reservationExpiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("座位保留 \(max(0, Int(expiration.timeIntervalSince(context.date))) / 60, format: .number.precision(.integerLength(2))):\(max(0, Int(expiration.timeIntervalSince(context.date))) % 60, format: .number.precision(.integerLength(2)))")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .onChange(of: context.date) { _, now in store.checkExpiration(now: now) }
                }
            }
            Spacer(minLength: 10)
            PrimaryAction(title: "继续支付 · ¥\(store.total)") { showPaymentInfo = true }
            SecondaryAction(title: "查看已选座位") { dismiss() }
        }
        .padding(.top, 20)
    }

    private var conflict: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(CinemaTheme.accent)
            Text("刚刚有一个座位被选走了").font(.title2.weight(.semibold))
            Text("其余座位仍在你的选座列表中，可以继续选择其他位置。")
                .foregroundStyle(.secondary)
            Spacer()
            PrimaryAction(title: "保留现有选择，继续选座") {
                store.recoverConflict(); dismiss()
            }
            SecondaryAction(title: "清空后重新选座") { store.clear(); dismiss() }
        }
    }
}

private struct FilmDetailView: View {
    let selectSeats: () -> Void
    private static let artwork: UIImage? = {
        guard let source = UIImage(named: "CinemaReference")?.cgImage,
              let frame = source.cropping(to: CGRect(x: CGFloat(source.width) * 0.1806,
                  y: CGFloat(source.height) * 0.3125, width: CGFloat(source.width) * 0.6343,
                  height: CGFloat(source.height) * 0.1992)) else { return nil }
        return UIImage(cgImage: frame)
    }()

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                if let artwork = Self.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }.ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Spacer()
                Text("星际穿越").font(.largeTitle.weight(.semibold))
                Text("今天 19:30 · IMAX 2D · 3号厅")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("在买票之前，先坐进去看看。")
                    .font(.title3).padding(.bottom, 8)
                PrimaryAction(title: "进入三维影厅", symbol: "view.3d") { selectSeats() }
                    .accessibilityIdentifier("film.chooseSeats")
            }
            .padding(24).padding(.bottom, 20)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

#Preview { CinemaRootView().preferredColorScheme(.dark) }
