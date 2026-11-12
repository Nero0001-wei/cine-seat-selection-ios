import SwiftUI
import RealityKit
import UIKit
import Observation
import simd

@MainActor
private final class CinemaViewport: ARView {
    var onViewportChange: (() -> Void)?
    private var previousSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize else { return }
        previousSize = bounds.size
        onViewportChange?()
    }
}

/// These are rendered from the same live scene used for seat selection.
@MainActor @Observable
final class CinemaSceneSnapshots {
    static let shared = CinemaSceneSnapshots()
    var images: [String: UIImage] = [:]

    static func key(for seat: Seat, lightsOn: Bool) -> String {
        seat.id + (lightsOn ? ":lights" : ":screening")
    }
}

/// A non-AR RealityKit theatre. The SwiftUI controls stay outside the renderer.
struct CinemaSceneView: UIViewRepresentable {
    var selectedSeatIDs: Set<String>
    var previewSeat: Seat?
    var lightsOn: Bool
    var resetToken: Int
    var reduceMotion: Bool
    var showsStructure: Bool = false
    var isSceneActive: Bool = true
    var allowsTrailer: Bool = true
    var onSeatTap: (Seat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = CinemaViewport(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(red: 27 / 255, green: 28 / 255, blue: 33 / 255, alpha: 1))
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        view.renderOptions.insert(.disableCameraGrain)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "三维影厅"
        view.accessibilityHint = "正上方俯视影厅，拖动平移，双指缩放。也可以使用下方的推荐座位和视角切换。"
        view.accessibilityIdentifier = "cinema.scene"
        context.coordinator.install(in: view, allowsTrailer: allowsTrailer)
        let coordinator = context.coordinator
        view.onViewportChange = { [weak coordinator] in coordinator?.viewportDidChange() }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.update(
            selected: selectedSeatIDs,
            seat: previewSeat,
            lightsOn: lightsOn,
            resetToken: resetToken,
            reduceMotion: reduceMotion,
            showsStructure: showsStructure,
            isSceneActive: isSceneActive,
            onSeatTap: onSeatTap
        )
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var view: ARView?
        private let anchor = AnchorEntity(world: .zero)
        private let architecture = Entity()
        private let frontStage = Entity()
        private let rowLabels = Entity()
        private let camera = Entity()
        private let keyLight = DirectionalLight()
        private let fillLight = DirectionalLight()
        private let rimLight = DirectionalLight()
        private let projectionLight = SpotLight()
        private var downLights: [SpotLight] = []
        private var houseFixtures: [ModelEntity] = []
        private var seats: [String: Entity] = [:]
        private var upholstery: [String: [ModelEntity]] = [:]
        private var seatPiping: [String: [ModelEntity]] = [:]
        private var selectionMarkers: [String: ModelEntity] = [:]
        private var seatLocalBounds: BoundingBox?
        private var selectedIDs: Set<String> = []
        private var previewSeat: Seat?
        private var showsStructure = false
        private var structureAzimuth: Float = 2.0
        private var structurePitch: Float = 0.48
        private var structureRadius: Float = 23
        private var lastPreviewID: String?
        private var lastReset = -1
        private var lastLights: Bool?
        private var hasPositioned = false
        private var reduceMotion = false
        private var onSeatTap: ((Seat) -> Void)?
        private var displayLink: CADisplayLink?
        private let cameraDiagnostics = CinemaCameraDiagnostics()
        private var tween: CameraTween?
        private var snapshotTask: Task<Void, Never>?
        private var accessibilityTask: Task<Void, Never>?
        private var viewportTask: Task<Void, Never>?
        private var environmentTask: Task<Void, Never>?
        private var screenPlayback: CinemaScreenPlayback?
        private var screenVideoSurface: ModelEntity?
        private var allowsTrailer = true
        private var playbackRequested = false
        private var projectionWarmupTask: Task<Void, Never>?
        private var projectionWarmupToken = 0
        private var projectionPrepared = false
        private var isPreparingProjection = false
        private var pendingSeatTap: CGPoint?
        private var overviewPan = SIMD2<Float>.zero
        private var overviewScale: Float = TheaterLayout.overviewSpan
        private var isOrthographic = false
        private var lookYaw: Float = 0
        private var lookPitch: Float = 0
        private var pinchStart: Float = TheaterLayout.overviewSpan
        private var cameraFOV: Float = 56
        private var cameraFocusDistance: Float = 22
        private var panStart = SIMD2<Float>.zero
        private var acceptsPan = false
        private var acceptsPinch = false
        private static let seatCollisionGroup = CollisionGroup(rawValue: 1 << 1)
        private let screenCenter = TheaterLayout.screenCenterPosition
        private let availableMaterial = CinemaUpholstery.fabric(UIColor(CinemaTheme.availableSeat))
        private let soldMaterial = CinemaUpholstery.fabric(UIColor(red: 67 / 255, green: 68 / 255, blue: 76 / 255, alpha: 1))
        private let selectedMaterial = CinemaUpholstery.fabric(UIColor(red: 1, green: 200 / 255, blue: 0, alpha: 1))
        private let availablePiping = Coordinator.stitch(UIColor(CinemaTheme.availableSeat))
        private let soldPiping = Coordinator.stitch(UIColor(red: 67 / 255, green: 68 / 255, blue: 76 / 255, alpha: 1))
        private let selectedPiping = Coordinator.stitch(UIColor(red: 1, green: 200 / 255, blue: 0, alpha: 1))

        private struct CameraTween {
            var started: CFTimeInterval?
            var duration: Double
            var endPosition: SIMD3<Float>
            var startRotation: simd_quatf
            var endRotation: simd_quatf
            var startFocus: SIMD3<Float>
            var endFocus: SIMD3<Float>
            var startDistance: Float
            var endDistance: Float
            var startSpan: Float
            var endSpan: Float
        }

        private final class SeatAccessibilityElement: UIAccessibilityElement {
            var activate: (() -> Void)?
            override func accessibilityActivate() -> Bool {
                activate?()
                return activate != nil
            }
        }

        func install(in view: ARView, allowsTrailer: Bool) {
            self.view = view
            self.allowsTrailer = allowsTrailer
            view.scene.addAnchor(anchor)
            anchor.addChild(camera)
            usePerspective(fov: 56)
            buildTheatre()
            environmentTask = Task { @MainActor [weak self, weak view] in
                let resource = await CinemaLightingEnvironment.resource.value
                guard !Task.isCancelled, let self, let view, let resource else { return }
                view.environment.lighting.resource = resource
                self.updateLighting(lightsOn: self.lastLights ?? true, overview: self.previewSeat == nil)
                self.preparePerspectiveProjection()
            }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            pan.delegate = self
            pinch.delegate = self
            tap.require(toFail: pan)
            view.addGestureRecognizer(tap)
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
            ensureDisplayLink()
            accessibilityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.refreshAccessibility()
            }
        }

        func stop() {
            screenPlayback?.stop()
            screenPlayback = nil
            displayLink?.invalidate()
            displayLink = nil
            tween = nil
            snapshotTask?.cancel()
            snapshotTask = nil
            accessibilityTask?.cancel()
            accessibilityTask = nil
            viewportTask?.cancel()
            viewportTask = nil
            environmentTask?.cancel()
            environmentTask = nil
            projectionWarmupTask?.cancel()
            projectionWarmupTask = nil
            projectionWarmupToken += 1
        }

        func update(selected: Set<String>, seat: Seat?, lightsOn: Bool, resetToken: Int, reduceMotion: Bool, showsStructure: Bool, isSceneActive: Bool, onSeatTap: @escaping (Seat) -> Void) {
            let updateStarted = CACurrentMediaTime()
            self.onSeatTap = onSeatTap
            self.reduceMotion = reduceMotion
            let changedSeats = selectedIDs.symmetricDifference(selected)
            let wasStructure = self.showsStructure
            let nextStructure = showsStructure && seat != nil
            playbackRequested = isSceneActive && seat != nil && !nextStructure
            let structureChanged = wasStructure != nextStructure
            let modeChanged = lastPreviewID != seat?.id || structureChanged || !hasPositioned
            let resetting = lastReset != resetToken
            if isPreparingProjection && (modeChanged || resetting) {
                projectionWarmupToken += 1
                projectionWarmupTask?.cancel()
                projectionWarmupTask = nil
                isPreparingProjection = false
                pendingSeatTap = nil
            }
            defer {
                if modeChanged || resetting {
                    CinemaCameraDiagnostics.recordUpdate(milliseconds: (CACurrentMediaTime() - updateStarted) * 1000,
                        label: seat == nil ? "overview" : nextStructure ? "structure" : "seat")
                }
            }
            previewSeat = seat
            self.showsStructure = nextStructure
            if !changedSeats.isEmpty || !hasPositioned {
                selectedIDs = selected
                updateSelection(changed: hasPositioned ? changedSeats : nil)
                if hasPositioned && !modeChanged && seat == nil { refreshAccessibility() }
            }
            if modeChanged || resetting {
                if resetting {
                    overviewPan = .zero
                    overviewScale = TheaterLayout.overviewSpan
                    structureAzimuth = 2.0
                    structurePitch = 0.48
                    structureRadius = 23
                }
                lookYaw = 0
                lookPitch = 0
                // Inward-facing walls and ceiling are culled from outside the room.
                // They stay resident throughout the flight instead of appearing in one frame.
                architecture.isEnabled = !nextStructure
                frontStage.isEnabled = seat != nil
                rowLabels.isEnabled = seat == nil
                if !nextStructure || !wasStructure || resetting || !hasPositioned {
                    let pose = nextStructure ? structurePose() : seat.map(seatPose) ?? overviewPose()
                    moveCamera(to: pose.position, lookingAt: pose.target, fov: pose.fov, animated: hasPositioned && !reduceMotion)
                } else { refreshAccessibility() }
                lastPreviewID = seat?.id
                lastReset = resetToken
                hasPositioned = true
            }
            if lastLights != lightsOn || modeChanged {
                updateLighting(lightsOn: lightsOn, overview: seat == nil)
                lastLights = lightsOn
                if !modeChanged { scheduleSnapshot() }
            }
            if seat == nil && tween == nil { preparePerspectiveProjection() }
            screenPlayback?.setPlaybackEnabled(playbackRequested && tween == nil)
        }

        private func prepareScreenPlayback(on screen: ModelEntity, fallback: UnlitMaterial) {
            guard allowsTrailer, let playback = CinemaScreenPlayback() else { return }
            screenPlayback = playback
            playback.prepare { [weak self, weak screen] material, aspectRatio in
                guard let self, let screen else { return }
                let width = min(TheaterLayout.screenWidth, TheaterLayout.filmHeight * aspectRatio)
                let height = min(TheaterLayout.filmHeight, width / aspectRatio)
                // Keep the entire physical screen black behind aspect-fit video.
                // Both surfaces use the same cylinder, including for narrow/ultrawide trailers.
                var black = UnlitMaterial()
                black.color = .init(tint: .black)
                screen.model?.materials = [black]
                let video = ModelEntity(mesh: CinemaGeometry.screen(width: width, height: height),
                                        materials: [material])
                video.name = "Aspect-fit cinema trailer"
                video.position.z = 0.006
                self.screenVideoSurface?.removeFromParent()
                self.screenVideoSurface = video
                screen.addChild(video)
            } onFailure: { [weak self, weak screen] in
                self?.screenVideoSurface?.removeFromParent()
                self?.screenVideoSurface = nil
                screen?.model?.materials = [fallback]
            }
        }

        private func buildTheatre() {
            let floorMaterial = Self.fabric(UIColor(red: 37 / 255, green: 38 / 255, blue: 44 / 255, alpha: 1))
            let wallMaterial = Self.fabric(UIColor(red: 37 / 255, green: 38 / 255, blue: 44 / 255, alpha: 1))
            let slatMaterial = Self.fabric(UIColor(red: 43 / 255, green: 44 / 255, blue: 51 / 255, alpha: 1))
            var frameMaterial = Self.fabric(UIColor(red: 0.67, green: 0.67, blue: 0.73, alpha: 1))
            frameMaterial.emissiveColor = .init(color: UIColor(red: 0.40, green: 0.39, blue: 0.46, alpha: 1))
            frameMaterial.emissiveIntensity = 0.08
            var baseMaterial = Self.fabric(UIColor(red: 0.09, green: 0.095, blue: 0.11, alpha: 1))
            baseMaterial.metallic = .init(floatLiteral: 0.42)
            baseMaterial.roughness = .init(floatLiteral: 0.58)
            baseMaterial.specular = .init(floatLiteral: 0.35)
            let stairMaterial = Self.fabric(UIColor(red: 40 / 255, green: 41 / 255, blue: 48 / 255, alpha: 1))
            let landingMaterial = Self.fabric(UIColor(red: 45 / 255, green: 46 / 255, blue: 53 / 255, alpha: 1))
            var riserMaterial = Self.fabric(UIColor(red: 0.29, green: 0.29, blue: 0.33, alpha: 1))
            riserMaterial.emissiveColor = .init(color: UIColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1))
            riserMaterial.emissiveIntensity = 0.35
            let profileMaterial = Self.emissive(UIColor(red: 0.38, green: 0.38, blue: 0.43, alpha: 1))
            let aisleLight = Self.emissive(UIColor(red: 0.27, green: 0.27, blue: 0.32, alpha: 1))
            let perimeterLight = Self.emissive(UIColor(red: 0.52, green: 0.51, blue: 0.60, alpha: 1))
            anchor.addChild(architecture)
            anchor.addChild(frontStage)
            anchor.addChild(rowLabels)

            // One shared set of seat meshes keeps the 168-seat auditorium inexpensive.
            let cushionMesh = CinemaGeometry.pillow(size: SIMD3<Float>(0.55, 0.20, 0.58))
            let backMesh = CinemaGeometry.pillow(size: SIMD3<Float>(0.57, 0.66, 0.22))
            let wingMesh = CinemaGeometry.pillow(size: SIMD3<Float>(0.15, 0.63, 0.24))
            let armMesh = CinemaGeometry.pillow(size: SIMD3<Float>(0.15, 0.24, 0.53))
            let baseMesh = CinemaGeometry.pillow(size: SIMD3<Float>(0.49, 0.27, 0.43))
            let cushionSeam = CinemaGeometry.piping(size: SIMD3<Float>(0.55, 0.20, 0.58), face: .top)
            let backFrontSeam = CinemaGeometry.piping(size: SIMD3<Float>(0.57, 0.66, 0.22), face: .front)
            let backRearSeam = CinemaGeometry.piping(size: SIMD3<Float>(0.57, 0.66, 0.22), face: .back)
            let markerMesh = MeshResource.generateBox(size: SIMD3<Float>(0.52, 0.012, 0.50), cornerRadius: 0.11)
            // Match the visible upholstery, including rounded edges. Reuse these
            // shapes instead of a tall box that also intercepts empty space.
            let cushionHit = ShapeResource.generateConvex(from: cushionMesh)
            let backHit = ShapeResource.generateConvex(from: backMesh)
            let wingHit = ShapeResource.generateConvex(from: wingMesh)
            let armHit = ShapeResource.generateConvex(from: armMesh)
            let markerMaterial = Self.emissive(UIColor(red: 0.54, green: 0.43, blue: 0.03, alpha: 1))

            for seat in TheaterLayout.seats {
                let entity = Entity()
                entity.name = "seat:" + seat.id
                entity.position = seat.position
                var parts: [ModelEntity] = []
                let material = seat.isSold ? soldMaterial : availableMaterial
                func part(_ mesh: MeshResource, hit: ShapeResource, at position: SIMD3<Float>, rotation: simd_quatf? = nil) {
                    let model = ModelEntity(mesh: mesh, materials: [material])
                    model.components.set(CollisionComponent(shapes: [hit],
                        filter: CollisionFilter(group: Self.seatCollisionGroup, mask: .all)))
                    model.position = position
                    if let rotation { model.orientation = rotation }
                    entity.addChild(model)
                    parts.append(model)
                }
                // Overlapping soft lobes form a continuous U-shaped wrap, with no headrest bar.
                part(cushionMesh, hit: cushionHit, at: SIMD3<Float>(0, 0.43, -0.045))
                part(backMesh, hit: backHit, at: SIMD3<Float>(0, 0.77, 0.26), rotation: simd_quatf(angle: -0.06, axis: SIMD3<Float>(1, 0, 0)))
                part(wingMesh, hit: wingHit, at: SIMD3<Float>(-0.263, 0.77, 0.15), rotation: simd_quatf(angle: -0.14, axis: SIMD3<Float>(0, 1, 0)))
                part(wingMesh, hit: wingHit, at: SIMD3<Float>(0.263, 0.77, 0.15), rotation: simd_quatf(angle: 0.14, axis: SIMD3<Float>(0, 1, 0)))
                part(armMesh, hit: armHit, at: SIMD3<Float>(-0.277, 0.55, -0.025))
                part(armMesh, hit: armHit, at: SIMD3<Float>(0.277, 0.55, -0.025))
                let seamMaterial = seat.isSold ? soldPiping : availablePiping
                func seam(_ mesh: MeshResource, position: SIMD3<Float>, rotation: simd_quatf? = nil) -> ModelEntity {
                    let detail = ModelEntity(mesh: mesh, materials: [seamMaterial])
                    detail.name = "Upholstery / inset piping"
                    detail.position = position
                    if let rotation { detail.orientation = rotation }
                    detail.components.set(DynamicLightShadowComponent(castsShadow: false))
                    entity.addChild(detail)
                    return detail
                }
                seatPiping[seat.id] = [
                    seam(cushionSeam, position: SIMD3<Float>(0, 0.43, -0.045)),
                    seam(backFrontSeam, position: SIMD3<Float>(0, 0.77, 0.26),
                         rotation: simd_quatf(angle: -0.06, axis: SIMD3<Float>(1, 0, 0))),
                    seam(backRearSeam, position: SIMD3<Float>(0, 0.77, 0.26),
                         rotation: simd_quatf(angle: -0.06, axis: SIMD3<Float>(1, 0, 0)))
                ]
                let base = ModelEntity(mesh: baseMesh, materials: [baseMaterial])
                base.position = SIMD3<Float>(0, 0.16, 0.04)
                entity.addChild(base)
                let marker = ModelEntity(mesh: markerMesh, materials: [markerMaterial])
                marker.position = SIMD3<Float>(0, 0.018, -0.015)
                marker.isEnabled = false
                entity.addChild(marker)
                anchor.addChild(entity)
                seats[seat.id] = entity
                upholstery[seat.id] = parts
                selectionMarkers[seat.id] = marker
                if seatLocalBounds == nil {
                    seatLocalBounds = entity.visualBounds(recursive: true, relativeTo: entity, excludeInactive: false)
                }
            }

            // One continuous bank per row, with two side stair flights and broad cross-aisle landings.
            // Every platform consumes the same coordinates as the seats and collision entities.
            let laneWidth = 2 * (TheaterLayout.floorWidth / 2 - TheaterLayout.sideAisleX)
            let seatingWidth = TheaterLayout.floorWidth - 2 * laneWidth
            let halfPitch = TheaterLayout.rowPitch / 2
            let halfRise = TheaterLayout.rowRise / 2
            let crossEntryRows = Set(TheaterLayout.crossAisles.map { $0.afterRow + 1 })
            for row in 1...TheaterLayout.rowCount {
                let elevation = TheaterLayout.rowElevation(row)
                let z = TheaterLayout.rowZ(row)
                let rowStart = z - halfPitch
                let entryDepth: Float = crossEntryRows.contains(row) ? TheaterLayout.rowPitch * 0.22 : 0
                addPlatform(top: elevation, width: seatingWidth, depth: TheaterLayout.rowPitch - entryDepth,
                            centerZ: z + entryDepth / 2, material: floorMaterial)
                let mainRise = entryDepth > 0 ? halfRise : min(elevation, TheaterLayout.rowRise)
                if mainRise > 0 {
                    addRiser(width: seatingWidth, height: mainRise, top: elevation,
                             centerX: 0, frontZ: rowStart + entryDepth, material: riserMaterial)
                }
                if entryDepth > 0 {
                    addPlatform(top: elevation - halfRise, width: seatingWidth, depth: entryDepth,
                                centerZ: rowStart + entryDepth / 2, material: stairMaterial)
                    addRiser(width: seatingWidth, height: halfRise, top: elevation - halfRise,
                             centerX: 0, frontZ: rowStart, material: riserMaterial)
                }
                for side: Float in [-1, 1] {
                    for tread in 0..<2 {
                        let top = tread == 0 ? max(0, elevation - halfRise) : elevation
                        let treadStart = rowStart + Float(tread) * halfPitch
                        addPlatform(top: top, width: laneWidth, depth: halfPitch,
                                    centerZ: treadStart + halfPitch / 2,
                                    centerX: side * TheaterLayout.sideAisleX, material: stairMaterial)
                        addBox(size: SIMD3<Float>(laneWidth - 0.12, 0.012, 0.018),
                               at: SIMD3<Float>(side * TheaterLayout.sideAisleX, top + 0.008, treadStart + 0.012), material: aisleLight)
                        let previousTop = tread == 0 ? max(0, elevation - TheaterLayout.rowRise) : max(0, elevation - halfRise)
                        if top > previousTop {
                            addRiser(width: laneWidth, height: top - previousTop, top: top,
                                     centerX: side * TheaterLayout.sideAisleX, frontZ: treadStart, material: riserMaterial)
                        }
                        addStairProfile(startZ: treadStart, endZ: treadStart + halfPitch,
                                        previousTop: previousTop, top: top,
                                        side: side, material: profileMaterial)
                    }
                }
                // Subtle row numerals are part of the model, not a 2D touch overlay.
                let labelMesh = MeshResource.generateText(String(row), extrusionDepth: 0.001, font: .systemFont(ofSize: 0.22, weight: .medium), containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
                let label = ModelEntity(mesh: labelMesh, materials: [Self.emissive(UIColor(red: 0.52, green: 0.52, blue: 0.58, alpha: 1))])
                label.position = SIMD3<Float>(-TheaterLayout.floorWidth / 2 + 0.20, elevation + 0.025, z + 0.11)
                label.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                rowLabels.addChild(label)
            }
            for aisle in TheaterLayout.crossAisles {
                addPlatform(top: aisle.elevation, width: TheaterLayout.floorWidth,
                            depth: aisle.width, centerZ: aisle.centerZ, material: landingMaterial)
                for side: Float in [-1, 1] {
                    addStairProfile(startZ: aisle.startZ, endZ: aisle.endZ,
                                    previousTop: aisle.elevation, top: aisle.elevation,
                                    side: side, material: profileMaterial)
                }
                let label = ModelEntity(mesh: .generateText("过道", extrusionDepth: 0.001,
                    font: .systemFont(ofSize: 0.20, weight: .regular)),
                    materials: [Self.emissive(UIColor(red: 0.41, green: 0.41, blue: 0.46, alpha: 1))])
                label.name = "Cross aisle after row \(aisle.afterRow)"
                label.position = SIMD3<Float>(-0.27, aisle.elevation + 0.025, aisle.centerZ + 0.07)
                label.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                rowLabels.addChild(label)
            }
            let frontRowStart = TheaterLayout.rowZ(1) - halfPitch
            let frontWalkDepth = frontRowStart - TheaterLayout.roomFrontZ
            let frontWalkCenter = (frontRowStart + TheaterLayout.roomFrontZ) / 2
            for side: Float in [-1, 1] {
                addPlatform(top: TheaterLayout.rowElevation(1), width: laneWidth,
                            depth: frontWalkDepth, centerZ: frontWalkCenter,
                            centerX: side * TheaterLayout.sideAisleX, material: stairMaterial)
            }
            let lastRowEnd = TheaterLayout.rowZ(TheaterLayout.rowCount) + halfPitch
            addPlatform(top: TheaterLayout.rowElevation(TheaterLayout.rowCount), width: TheaterLayout.floorWidth,
                        depth: TheaterLayout.roomBackZ - lastRowEnd,
                        centerZ: (TheaterLayout.roomBackZ + lastRowEnd) / 2, material: landingMaterial)
            // Low front stage, black surround, and the original film artwork.
            addBox(size: SIMD3<Float>(seatingWidth, 0.16, frontWalkDepth),
                   at: SIMD3<Float>(0, -0.08, frontWalkCenter), material: floorMaterial, to: frontStage)
            let curvedFrame = ModelEntity(mesh: CinemaGeometry.screen(width: TheaterLayout.frameWidth, height: TheaterLayout.frameHeight), materials: [frameMaterial])
            curvedFrame.name = "Silver curved screen surround"
            curvedFrame.position = screenCenter + SIMD3<Float>(0, 0, TheaterLayout.frameDepthOffset)
            anchor.addChild(curvedFrame)
            var film = UnlitMaterial()
            if let image = UIImage(named: "CinemaReference")?.cgImage,
               let crop = image.cropping(to: CGRect(x: CGFloat(image.width) * 0.1806, y: CGFloat(image.height) * 0.3125, width: CGFloat(image.width) * 0.6343, height: CGFloat(image.height) * 0.1992)),
               let texture = try? TextureResource(image: crop, options: .init(semantic: .color)) {
                film.color = .init(tint: .white, texture: .init(texture))
            } else {
                film.color = .init(tint: UIColor(red: 0.12, green: 0.23, blue: 0.42, alpha: 1))
            }
            let screen = ModelEntity(mesh: CinemaGeometry.screen(width: TheaterLayout.screenWidth, height: TheaterLayout.filmHeight), materials: [film])
            screen.name = "IMAX screen"
            screen.position = screenCenter + SIMD3<Float>(0, 0, TheaterLayout.filmDepthOffset)
            anchor.addChild(screen)
            prepareScreenPlayback(on: screen, fallback: film)
            // The plan uses the actual screen's top rim and the same continuous curve.
            let halo = ModelEntity(mesh: CinemaGeometry.screenRibbon(width: TheaterLayout.frameWidth + 0.61, depth: 1.25), materials: [Self.screenHalo()])
            halo.name = "Screen / soft silver falloff"
            halo.position = SIMD3<Float>(0, screenCenter.y + TheaterLayout.frameHeight / 2 - 0.025, screenCenter.z + 0.28)
            rowLabels.addChild(halo)
            for (width, depth, height, color) in [
                (TheaterLayout.frameWidth + 0.04, Float(0.22), screenCenter.y + TheaterLayout.frameHeight / 2 - 0.005, UIColor(red: 0.38, green: 0.38, blue: 0.44, alpha: 1)),
                (TheaterLayout.frameWidth - 0.06, Float(0.14), screenCenter.y + TheaterLayout.frameHeight / 2 + 0.015, UIColor(red: 0.79, green: 0.78, blue: 0.86, alpha: 1))
            ] {
                let rim = ModelEntity(mesh: CinemaGeometry.screenRibbon(width: width, depth: depth), materials: [Self.emissive(color)])
                rim.position = SIMD3<Float>(0, height, screenCenter.z)
                rowLabels.addChild(rim)
            }
            let screenLabel = ModelEntity(mesh: .generateText("银幕", extrusionDepth: 0.001,
                font: .systemFont(ofSize: 0.34, weight: .medium)),
                materials: [Self.emissive(.lightGray)])
            screenLabel.position = SIMD3<Float>(-0.34, 0.18, -8.0)
            screenLabel.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            rowLabels.addChild(screenLabel)

            // One-sided interiors are invisible from the plan, resident during a flight,
            // and visible from the seated camera without enabling a whole room mid-frame.
            let wallX = TheaterLayout.floorWidth / 2 + 0.25
            let roomWidth = wallX * 2
            addInteriorPlane(width: roomWidth, height: 8.4, at: SIMD3<Float>(0, 4.1, TheaterLayout.roomFrontZ), yaw: 0, material: wallMaterial)
            addInteriorPlane(width: roomWidth, height: 8.4, at: SIMD3<Float>(0, 4.1, TheaterLayout.roomBackZ), yaw: .pi, material: wallMaterial)
            addInteriorPlane(width: TheaterLayout.roomDepth, height: 8.4, at: SIMD3<Float>(-wallX, 4.1, TheaterLayout.roomCenterZ), yaw: .pi / 2, material: wallMaterial)
            addInteriorPlane(width: TheaterLayout.roomDepth, height: 8.4, at: SIMD3<Float>(wallX, 4.1, TheaterLayout.roomCenterZ), yaw: -.pi / 2, material: wallMaterial)
            addCeilingPlane(width: roomWidth, depth: TheaterLayout.roomDepth, at: SIMD3<Float>(0, 8.3, TheaterLayout.roomCenterZ), material: floorMaterial)
            for side: Float in [-1, 1] {
                addCeilingPlane(width: 0.025, depth: TheaterLayout.roomDepth - 0.7, at: SIMD3<Float>(side * (wallX - 0.32), 7.95, TheaterLayout.roomCenterZ), material: perimeterLight)
                let slatCount = Int((TheaterLayout.roomDepth - 0.7) / 0.49) + 1
                for index in 0..<slatCount {
                    addBox(size: SIMD3<Float>(0.08, 7.5, 0.055), at: SIMD3<Float>(side * (wallX - 0.17), 4.1, TheaterLayout.roomFrontZ + 0.35 + Float(index) * 0.49), material: slatMaterial, to: architecture)
                }
            }
            for z in [TheaterLayout.roomFrontZ + 0.6, TheaterLayout.roomBackZ - 0.6] {
                addCeilingPlane(width: TheaterLayout.floorWidth - 0.1, depth: 0.025, at: SIMD3<Float>(0, 7.95, z), material: perimeterLight)
            }

            keyLight.light = DirectionalLightComponent(color: UIColor(red: 1, green: 0.97, blue: 0.93, alpha: 1), intensity: 1800, isRealWorldProxy: false)
            keyLight.look(at: SIMD3<Float>(0, 1.2, 1.5), from: SIMD3<Float>(-4.5, 10.5, -2.5), relativeTo: nil)
            var seatShadow = DirectionalLightComponent.Shadow()
            seatShadow.shadowProjection = .fixed(zNear: 0.05, zFar: 40, orthographicScale: 26)
            seatShadow.depthBias = 0.25
            keyLight.shadow = seatShadow
            anchor.addChild(keyLight)
            fillLight.light = DirectionalLightComponent(color: UIColor(red: 0.85, green: 0.91, blue: 1, alpha: 1), intensity: 400, isRealWorldProxy: false)
            fillLight.look(at: SIMD3<Float>(0, 1.4, TheaterLayout.roomCenterZ), from: SIMD3<Float>(6, 6, 8.5), relativeTo: nil)
            anchor.addChild(fillLight)
            rimLight.light = DirectionalLightComponent(color: UIColor(red: 0.72, green: 0.83, blue: 1, alpha: 1), intensity: 180, isRealWorldProxy: false)
            rimLight.look(at: SIMD3<Float>(0, 1.8, 0), from: SIMD3<Float>(5.5, 7, 7.5), relativeTo: nil)
            anchor.addChild(rimLight)
            projectionLight.light = SpotLightComponent(color: UIColor(red: 0.59, green: 0.72, blue: 1, alpha: 1), intensity: 3500,
                innerAngleInDegrees: 52, outerAngleInDegrees: 108, attenuationRadius: TheaterLayout.roomDepth + 4)
            projectionLight.look(at: SIMD3<Float>(0, 1.8, 4), from: screenCenter + SIMD3<Float>(0, 0.3, 1.25), relativeTo: nil)
            anchor.addChild(projectionLight)
            for (index, section) in TheaterLayout.sections.enumerated() {
                let z = (TheaterLayout.rowZ(section.rows.lowerBound) + TheaterLayout.rowZ(section.rows.upperBound)) / 2
                let light = SpotLight()
                light.light = SpotLightComponent(color: UIColor(red: 1, green: 0.93, blue: 0.84, alpha: 1), intensity: 600,
                    innerAngleInDegrees: 28, outerAngleInDegrees: 64, attenuationRadius: 12)
                let x: Float = index.isMultiple(of: 2) ? -3.6 : 3.6
                light.look(at: SIMD3<Float>(x * 0.35, TheaterLayout.rowElevation(section.rows.lowerBound) + 0.4, z + 0.5),
                           from: SIMD3<Float>(x, 7.8, z), relativeTo: nil)
                anchor.addChild(light)
                downLights.append(light)
                let fixture = Self.emissive(UIColor(red: 0.80, green: 0.70, blue: 0.58, alpha: 1))
                houseFixtures.append(addCeilingPlane(width: 0.65, depth: 0.045,
                    at: SIMD3<Float>(x, 8.15, z), material: fixture))
            }
        }

        private func addInteriorPlane(width: Float, height: Float, at position: SIMD3<Float>, yaw: Float,
                                      material: any RealityKit.Material) {
            let model = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
            model.position = position
            model.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            model.components.set(DynamicLightShadowComponent(castsShadow: false))
            architecture.addChild(model)
        }

        @discardableResult
        private func addCeilingPlane(width: Float, depth: Float, at position: SIMD3<Float>,
                                     material: any RealityKit.Material) -> ModelEntity {
            let model = ModelEntity(mesh: .generatePlane(width: width, depth: depth), materials: [material])
            model.position = position
            model.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            model.components.set(DynamicLightShadowComponent(castsShadow: false))
            architecture.addChild(model)
            return model
        }

        private func addPlatform(top: Float, width: Float, depth: Float, centerZ: Float, centerX: Float = 0,
                                 material: any RealityKit.Material) {
            let bottom: Float = -0.22
            addBox(size: SIMD3<Float>(width, top - bottom, depth),
                   at: SIMD3<Float>(centerX, (top + bottom) / 2, centerZ), material: material)
        }

        private func addRiser(width: Float, height: Float, top: Float, centerX: Float, frontZ: Float,
                              material: any RealityKit.Material) {
            let face = ModelEntity(mesh: .generatePlane(width: width - 0.02, height: height * 0.88), materials: [material])
            face.position = SIMD3<Float>(centerX, top - height / 2, frontZ - 0.004)
            face.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
            anchor.addChild(face)
        }

        private func addStairProfile(startZ: Float, endZ: Float, previousTop: Float, top: Float,
                                     side: Float, material: any RealityKit.Material) {
            let x = side * (TheaterLayout.floorWidth / 2 + 0.01)
            addBox(size: SIMD3<Float>(0.028, 0.028, endZ - startZ),
                   at: SIMD3<Float>(x, top + 0.008, (startZ + endZ) / 2), material: material)
            if top > previousTop {
                addBox(size: SIMD3<Float>(0.028, top - previousTop, 0.028),
                       at: SIMD3<Float>(x, (top + previousTop) / 2, startZ), material: material)
            }
        }

        @discardableResult
        private func addBox(size: SIMD3<Float>, at position: SIMD3<Float>, material: any RealityKit.Material, to parent: Entity? = nil) -> ModelEntity {
            let model = ModelEntity(mesh: .generateBox(size: size), materials: [material])
            model.position = position
            // The cutaway roof should not block the controlled auditorium lighting.
            if parent != nil { model.components.set(DynamicLightShadowComponent(castsShadow: false)) }
            (parent ?? anchor).addChild(model)
            return model
        }

        private static func fabric(_ color: UIColor) -> PhysicallyBasedMaterial {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color)
            material.roughness = .init(floatLiteral: 1)
            material.metallic = .init(floatLiteral: 0)
            material.specular = .init(floatLiteral: 0.08)
            material.clearcoat = .init(floatLiteral: 0)
            return material
        }

        private static func stitch(_ color: UIColor) -> PhysicallyBasedMaterial {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: UIColor(red: red * 0.73, green: green * 0.73, blue: blue * 0.73, alpha: alpha))
            material.roughness = .init(floatLiteral: 0.86)
            material.specular = .init(floatLiteral: 0.24)
            return material
        }

        private static func emissive(_ color: UIColor) -> UnlitMaterial {
            var material = UnlitMaterial()
            material.color = .init(tint: color)
            return material
        }

        /// A low-opacity, continuously feathered wash. It fades before the geometry edge.
        private static func screenHalo() -> UnlitMaterial {
            let size = CGSize(width: 256, height: 64)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let cg = context.cgContext
                let color = UIColor(red: 0.85, green: 0.84, blue: 0.95, alpha: 1)
                let vertical = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                    color.withAlphaComponent(0).cgColor,
                    color.withAlphaComponent(0.025).cgColor,
                    color.withAlphaComponent(0.09).cgColor,
                    color.withAlphaComponent(0.06).cgColor,
                    color.withAlphaComponent(0.015).cgColor,
                    color.withAlphaComponent(0).cgColor
                ] as CFArray, locations: [0, 0.15, 0.40, 0.60, 0.85, 1])!
                cg.drawLinearGradient(vertical, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                cg.setBlendMode(.destinationIn)
                let ends = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                    UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.cgColor,
                    UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor
                ] as CFArray, locations: [0, 0.08, 0.92, 1])!
                cg.drawLinearGradient(ends, start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
            }
            var material = UnlitMaterial()
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            material.writesDepth = false
            if let cgImage = image.cgImage,
               let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) {
                material.color = .init(tint: .white, texture: .init(texture))
            } else {
                material.color = .init(tint: .clear)
            }
            return material
        }

        private func updateSelection(changed: Set<String>? = nil) {
            for seat in TheaterLayout.seats {
                if let changed, !changed.contains(seat.id) { continue }
                let selected = selectedIDs.contains(seat.id)
                let material = selected ? selectedMaterial : seat.isSold ? soldMaterial : availableMaterial
                for entity in upholstery[seat.id] ?? [] {
                    entity.model?.materials = [material]
                }
                let thread = selected ? selectedPiping : seat.isSold ? soldPiping : availablePiping
                for entity in seatPiping[seat.id] ?? [] { entity.model?.materials = [thread] }
                selectionMarkers[seat.id]?.isEnabled = selected
            }
        }

        private func updateLighting(lightsOn: Bool, overview: Bool) {
            view?.environment.lighting.intensityExponent = overview ? 0.1 : lightsOn ? (showsStructure ? -0.1 : -0.2) : -1.8
            let bright = lightsOn || overview
            // Mode changes adjust lights only; shared upholstery materials stay resident.
            keyLight.light.intensity = overview ? 1600 : !lightsOn ? 120 : showsStructure ? 2200 : 1800
            fillLight.light.intensity = overview ? 400 : bright ? 400 : 70
            rimLight.light.intensity = overview ? 100 : bright ? 180 : 100
            projectionLight.light.intensity = overview ? 500 : !lightsOn ? 9000 : showsStructure ? 1000 : 3500
            // Keep the light-list layout warm while these fixtures are visually off.
            for light in downLights { light.light.intensity = overview || showsStructure ? 0.01 : bright ? 600 : 0.01 }
            for fixture in houseFixtures { fixture.isEnabled = lightsOn }
        }

        private func seatPose(_ seat: Seat) -> (position: SIMD3<Float>, target: SIMD3<Float>, fov: Float) {
            let eye = TheaterLayout.seatedEyePosition(for: seat)
            let distance = abs(eye.z - screenCenter.z)
            let fit = 2 * atan((TheaterLayout.screenWidth / 2) / (distance * 0.86)) * 180 / .pi
            return (eye, screenCenter, max(68, min(105, fit)))
        }

        private func structurePose() -> (position: SIMD3<Float>, target: SIMD3<Float>, fov: Float) {
            let target = SIMD3<Float>(0, 1.1, TheaterLayout.roomCenterZ)
            let horizontal = cos(structurePitch) * structureRadius
            let position = target + SIMD3<Float>(sin(structureAzimuth) * horizontal,
                                                 sin(structurePitch) * structureRadius,
                                                 cos(structureAzimuth) * horizontal)
            return (position, target, 64)
        }

        private func applyStructure() {
            let pose = structurePose()
            camera.look(at: pose.target, from: pose.position, relativeTo: nil)
        }

        private func overviewPose() -> (position: SIMD3<Float>, target: SIMD3<Float>, fov: Float) {
            // Preserve the original composition in the upper 72% without resizing ARView.
            let compositionOffset = Float((view?.bounds.height ?? 0) * 0.14) * overviewScale / Float(max(view?.bounds.width ?? 1, 1))
            let center = SIMD3<Float>(overviewPan.x, TheaterLayout.rowElevation(TheaterLayout.rowCount) / 2,
                                      TheaterLayout.overviewCenterZ + compositionOffset + overviewPan.y)
            return (center + SIMD3<Float>(0, 22, 0), center, 56)
        }

        private func usePerspective(fov: Float, far: Float = 120) {
            camera.components.remove(OrthographicCameraComponent.self)
            camera.components.set(PerspectiveCameraComponent(near: 0.04, far: far,
                fieldOfViewInDegrees: fov, fieldOfViewOrientation: .horizontal))
            isOrthographic = false
            cameraFOV = fov
        }

        private func useOrthographic() {
            camera.components.remove(PerspectiveCameraComponent.self)
            var projection = OrthographicCameraComponent()
            projection.near = 0.04
            projection.far = 120
            projection.scaleDirection = .horizontal
            // RealityKit's orthographic scale is the half-width of the view.
            projection.scale = overviewScale * 0.5
            camera.components.set(projection)
            isOrthographic = true
        }

        private func updatePerspectiveFOV(_ value: Float) {
            guard var projection = camera.components[PerspectiveCameraComponent.self] else { return }
            projection.fieldOfViewInDegrees = value
            camera.components.set(projection)
        }

        private func applyOverview() {
            let pose = overviewPose()
            camera.look(at: pose.target, from: pose.position,
                        upVector: SIMD3<Float>(0, 0, -1), relativeTo: nil)
            useOrthographic()
        }

        func viewportDidChange() {
            if hasPositioned && previewSeat == nil && tween == nil && !isPreparingProjection { applyOverview() }
            refreshAfterRender()
            preparePerspectiveProjection()
        }

        private func preparePerspectiveProjection() {
            guard !projectionPrepared, !isPreparingProjection, hasPositioned,
                  previewSeat == nil, tween == nil, isOrthographic,
                  let view, view.bounds.width > 0, view.environment.lighting.resource != nil else { return }
            guard !(view.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed } ?? false) else { return }
            isPreparingProjection = true
            projectionWarmupToken += 1
            let token = projectionWarmupToken
            let focus = SIMD3<Float>(camera.position.x, TheaterLayout.rowElevation(TheaterLayout.rowCount) / 2, camera.position.z)
            camera.position = focus + SIMD3<Float>(0, 320, 0)
            cameraFocusDistance = 320
            usePerspective(fov: 2 * atan(overviewScale / 640) * 180 / .pi, far: 1000)
            refreshAccessibility()
            projectionWarmupTask = Task { @MainActor [weak self, weak view] in
                await Task.yield()
                guard !Task.isCancelled, let self, let view,
                      self.projectionWarmupToken == token else { return }
                // Render the real textured scene through the perspective path once while
                // the long-lens composition still matches the plan. Discard the image.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    view.snapshot(saveToHDR: false) { _ in continuation.resume() }
                }
                guard !Task.isCancelled, self.projectionWarmupToken == token,
                      self.previewSeat == nil, self.tween == nil else { return }
                self.isPreparingProjection = false
                self.projectionPrepared = true
                self.projectionWarmupTask = nil
                self.applyOverview()
                self.cameraFocusDistance = 22
                self.refreshAfterRender()
                if let point = self.pendingSeatTap {
                    self.pendingSeatTap = nil
                    self.pickSeat(at: point)
                }
            }
        }

        private func ensureDisplayLink() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(animateCamera(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func refreshAfterRender() {
            viewportTask?.cancel()
            viewportTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                self?.refreshAccessibility()
            }
        }

        private func moveCamera(to position: SIMD3<Float>, lookingAt target: SIMD3<Float>, fov: Float, animated: Bool) {
            if animated { cameraDiagnostics.begin(label: previewSeat == nil ? "to_overview" : showsStructure ? "to_structure" : "to_seat") }
            displayLink?.isPaused = true
            tween = nil
            snapshotTask?.cancel()
            let goal = Entity()
            goal.look(at: target, from: position,
                      upVector: previewSeat == nil ? SIMD3<Float>(0, 0, -1) : SIMD3<Float>(0, 1, 0),
                      relativeTo: nil)
            if !animated {
                camera.transform = goal.transform
                cameraFocusDistance = simd_length(target - position)
                if previewSeat == nil { useOrthographic() } else { usePerspective(fov: fov) }
                refreshAfterRender()
                scheduleSnapshot()
                screenPlayback?.setPlaybackEnabled(playbackRequested)
                return
            }
            let startRotation = camera.orientation
            let forward = startRotation.act(SIMD3<Float>(0, 0, -1))
            var startDistance = max(0.1, cameraFocusDistance)
            var startFocus = camera.position + forward * startDistance
            var startSpan = 2 * startDistance * tan(cameraFOV * .pi / 360)
            if isOrthographic {
                // A long lens matches the plan before introducing perspective continuously.
                startFocus = SIMD3<Float>(camera.position.x, TheaterLayout.rowElevation(TheaterLayout.rowCount) / 2, camera.position.z)
                startDistance = 320
                startSpan = overviewScale
                camera.position = startFocus - forward * startDistance
            }
            let endDistance: Float = previewSeat == nil ? 320 : max(0.1, simd_length(target - position))
            let endSpan = previewSeat == nil ? overviewScale : 2 * endDistance * tan(fov * .pi / 360)
            usePerspective(fov: 2 * atan(startSpan / (2 * startDistance)) * 180 / .pi, far: 1000)
            cameraFocusDistance = startDistance
            tween = CameraTween(started: nil, duration: 1.15, endPosition: position,
                startRotation: startRotation, endRotation: goal.orientation, startFocus: startFocus, endFocus: target,
                startDistance: startDistance, endDistance: endDistance, startSpan: startSpan, endSpan: endSpan)
            ensureDisplayLink()
            displayLink?.isPaused = false
        }

        @objc private func animateCamera(_ link: CADisplayLink) {
            cameraDiagnostics.tick(timestamp: CACurrentMediaTime())
            guard var tween else { link.isPaused = true; return }
            let now = CACurrentMediaTime()
            if tween.started == nil {
                tween.started = now
                self.tween = tween
            }
            let elapsed = min(1, (now - (tween.started ?? now)) / tween.duration)
            let t = Float(elapsed)
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            camera.orientation = simd_slerp(tween.startRotation, tween.endRotation, eased)
            let focus = simd_mix(tween.startFocus, tween.endFocus, SIMD3<Float>(repeating: eased))
            cameraFocusDistance = exp(log(tween.startDistance) + (log(tween.endDistance) - log(tween.startDistance)) * eased)
            camera.position = focus - camera.orientation.act(SIMD3<Float>(0, 0, -1)) * cameraFocusDistance
            let span = tween.startSpan + (tween.endSpan - tween.startSpan) * eased
            cameraFOV = 2 * atan(span / (2 * cameraFocusDistance)) * 180 / .pi
            updatePerspectiveFOV(cameraFOV)
            if elapsed >= 1 {
                link.isPaused = true
                self.tween = nil
                cameraDiagnostics.finish()
                if previewSeat == nil {
                    applyOverview()
                    cameraFocusDistance = 22
                    preparePerspectiveProjection()
                } else {
                    camera.position = tween.endPosition
                    usePerspective(fov: cameraFOV)
                }
                refreshAfterRender()
                scheduleSnapshot()
                screenPlayback?.setPlaybackEnabled(playbackRequested)
            }
        }

        private func scheduleSnapshot() {
            snapshotTask?.cancel()
            guard !showsStructure, tween == nil, let id = previewSeat?.id else { return }
            snapshotTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, !self.showsStructure, self.tween == nil, let seat = self.previewSeat,
                      seat.id == id, let view = self.view else { return }
                let lights = self.lastLights ?? true
                let key = CinemaSceneSnapshots.key(for: seat, lightsOn: lights)
                view.snapshot(saveToHDR: false) { [weak self] image in
                    guard let image else { return }
                    Task { @MainActor [weak self] in
                        guard self?.showsStructure == false, self?.tween == nil,
                              self?.previewSeat?.id == id, self?.lastLights == lights else { return }
                        CinemaSceneSnapshots.shared.images[key] = image
                    }
                }
            }
        }

        private func refreshAccessibility() {
            guard let view, view.bounds.width > 0 else { return }
            if showsStructure {
                view.isAccessibilityElement = true
                view.accessibilityElements = nil
                view.accessibilityLabel = "三维影厅结构，靠近银幕最低，后排逐级升高"
                return
            }
            if let previewSeat {
                view.isAccessibilityElement = true
                view.accessibilityElements = nil
                view.accessibilityLabel = "三维观影视角，" + previewSeat.title
                return
            }
            view.isAccessibilityElement = false
            guard isOrthographic, tween == nil else { view.accessibilityElements = []; return }
            var elements: [SeatAccessibilityElement] = []
            guard let bounds = seatLocalBounds else { return }
            for seat in TheaterLayout.seats {
                // The seat instances share a mesh and differ only by translation.
                // A straight-down orthographic view needs two opposite X/Z corners.
                guard let first = overviewPoint(for: seat.position + bounds.min),
                      let second = overviewPoint(for: seat.position + bounds.max) else { continue }
                let minX = min(first.x, second.x), maxX = max(first.x, second.x)
                let minY = min(first.y, second.y), maxY = max(first.y, second.y)
                let frame = CGRect(x: minX, y: minY, width: max(8, maxX - minX), height: max(8, maxY - minY))
                guard frame.intersects(view.bounds) else { continue }
                let element = SeatAccessibilityElement(accessibilityContainer: view)
                element.accessibilityIdentifier = "seat." + seat.id
                element.accessibilityLabel = seat.title + "，" + (seat.isSold ? "已售" : "68元")
                element.accessibilityTraits = [.button]
                if selectedIDs.contains(seat.id) { element.accessibilityTraits.insert(.selected) }
                if seat.isSold { element.accessibilityTraits.insert(.notEnabled) }
                element.accessibilityFrameInContainerSpace = frame
                element.activate = { [weak self] in self?.onSeatTap?(seat) }
                elements.append(element)
            }
            view.accessibilityElements = elements
        }

        // Rendering, accessibility, and ray construction use the same explicit
        // orthographic viewport, including after a pan, pinch, or layout change.
        private func overviewPoint(for world: SIMD3<Float>) -> CGPoint? {
            guard let view, view.bounds.width > 0 else { return nil }
            let pointsPerMeter = Float(view.bounds.width) / overviewScale
            return CGPoint(x: view.bounds.midX + CGFloat((world.x - camera.position.x) * pointsPerMeter),
                           y: view.bounds.midY + CGFloat((world.z - camera.position.z) * pointsPerMeter))
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view, gesture.state == .ended, previewSeat == nil, tween == nil else { return }
            let point = gesture.location(in: view)
            guard view.bounds.contains(point), view.bounds.width > 0 else { return }
            if isPreparingProjection { pendingSeatTap = point; return }
            pickSeat(at: point)
        }

        private func pickSeat(at point: CGPoint) {
            guard let view, previewSeat == nil, tween == nil, isOrthographic,
                  view.bounds.contains(point), view.bounds.width > 0 else { return }
            let metersPerPoint = overviewScale / Float(view.bounds.width)
            let localOrigin = SIMD3<Float>(Float(point.x - view.bounds.midX) * metersPerPoint,
                                          Float(view.bounds.midY - point.y) * metersPerPoint, 0)
            let origin = camera.convert(position: localOrigin, to: nil)
            let direction = camera.convert(direction: SIMD3<Float>(0, 0, -1), to: nil)
            var entity = view.scene.raycast(origin: origin, direction: direction, length: 120,
                query: .nearest, mask: Self.seatCollisionGroup, relativeTo: nil).first?.entity
            while let current = entity {
                if current.name.hasPrefix("seat:") {
                    let id = String(current.name.dropFirst(5))
                    if let seat = TheaterLayout.seats.first(where: { $0.id == id }) { onSeatTap?(seat) }
                    return
                }
                entity = current.parent
            }
        }

        @objc private func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let translation = gesture.translation(in: view)
            if gesture.state == .began {
                acceptsPan = tween == nil && !isPreparingProjection
                panStart = showsStructure ? SIMD2<Float>(structureAzimuth, structurePitch)
                    : previewSeat == nil ? overviewPan : SIMD2<Float>(lookYaw, lookPitch)
            }
            guard acceptsPan else { return }
            if gesture.state == .changed || gesture.state == .ended {
                if showsStructure {
                    structureAzimuth = min(3.5, max(1.2, panStart.x - Float(translation.x) * 0.004))
                    structurePitch = min(0.82, max(0.18, panStart.y + Float(translation.y) * 0.003))
                    applyStructure()
                } else if let seat = previewSeat {
                    lookYaw = min(1.2, max(-1.2, panStart.x - Float(translation.x) * 0.0028))
                    lookPitch = min(0.30, max(-0.22, panStart.y + Float(translation.y) * 0.0021))
                    let base = seatPose(seat)
                    let direction = simd_normalize(base.target - base.position)
                    let yaw = simd_quatf(angle: lookYaw, axis: SIMD3<Float>(0, 1, 0))
                    let right = simd_normalize(simd_cross(direction, SIMD3<Float>(0, 1, 0)))
                    let pitch = simd_quatf(angle: lookPitch, axis: right)
                    camera.look(at: base.position + yaw.act(pitch.act(direction)), from: base.position, relativeTo: nil)
                } else {
                    let unitsPerPoint = overviewScale / Float(max(view.bounds.width, 1))
                    overviewPan.x = min(5, max(-5, panStart.x - Float(translation.x) * unitsPerPoint))
                    overviewPan.y = min(6, max(-6, panStart.y - Float(translation.y) * unitsPerPoint))
                    applyOverview()
                }
                if gesture.state == .ended { scheduleSnapshot(); refreshAfterRender(); preparePerspectiveProjection() }
            }
        }

        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                acceptsPinch = tween == nil && !isPreparingProjection
                pinchStart = showsStructure ? structureRadius : previewSeat == nil ? overviewScale : cameraFOV
            }
            guard acceptsPinch else { return }
            if showsStructure {
                structureRadius = min(34, max(13, pinchStart / Float(gesture.scale)))
                applyStructure()
            } else if previewSeat == nil {
                overviewScale = min(22, max(7, pinchStart / Float(gesture.scale)))
                applyOverview()
                if gesture.state == .ended { refreshAfterRender(); preparePerspectiveProjection() }
            } else {
                cameraFOV = min(110, max(45, pinchStart / Float(gesture.scale)))
                updatePerspectiveFOV(cameraFOV)
                if gesture.state == .ended { scheduleSnapshot() }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
