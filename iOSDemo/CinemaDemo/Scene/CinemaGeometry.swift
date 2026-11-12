import RealityKit
import simd

/// Shared, smooth procedural geometry for both the plan and seated camera views.
@MainActor
enum CinemaGeometry {
    // A gentle shared cylinder keeps the film, surround and plan rim on one curve.
    static let screenRadius = TheaterLayout.screenRadius

    enum PillowFace: Equatable {
        case top
        /// The upholstered front of the backrest, towards the screen (negative Z).
        case front
        /// The reverse of the backrest seen from the row behind (positive Z).
        case back
    }

    /// A gently inflated superellipsoid, rather than a box with beveled corners.
    static func pillow(size: SIMD3<Float>, latitudePower: Float = 0.44, longitudePower: Float = 0.48) -> MeshResource {
        let columns = 40
        let rows = 24
        let half = size * 0.5
        func signedPower(_ value: Float, _ power: Float) -> Float {
            (value < 0 ? -1 : 1) * pow(abs(value), power)
        }
        func point(_ latitude: Float, _ longitude: Float) -> SIMD3<Float> {
            let ring = pow(max(0, cos(latitude)), latitudePower)
            return SIMD3<Float>(half.x * ring * signedPower(cos(longitude), longitudePower),
                                half.y * signedPower(sin(latitude), latitudePower),
                                half.z * ring * signedPower(sin(longitude), longitudePower))
        }
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var tangents: [SIMD3<Float>] = []
        var bitangents: [SIMD3<Float>] = []
        var uv: [SIMD2<Float>] = []
        for row in 0...rows {
            let latitude = -.pi / 2 + Float(row) / Float(rows) * .pi
            for column in 0...columns {
                let longitude = Float(column % columns) / Float(columns) * .pi * 2
                let vertex = point(latitude, longitude)
                let normal = pillowNormal(at: vertex, half: half,
                                          latitudePower: latitudePower, longitudePower: longitudePower)
                let cloth = pillowTextureFrame(at: vertex, normal: normal, half: half)
                positions.append(vertex)
                normals.append(normal)
                tangents.append(cloth.tangent)
                bitangents.append(cloth.bitangent)
                uv.append(cloth.uv)
            }
        }
        var indices: [UInt32] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let a = UInt32(row * (columns + 1) + column)
                let b = a + 1
                let c = a + UInt32(columns + 1)
                let d = c + 1
                if row > 0 { indices += [a, c, b] }
                if row < rows - 1 { indices += [b, c, d] }
            }
        }
        return mesh(name: "Soft upholstery pillow", positions: positions, normals: normals, uv: uv,
                    indices: indices, tangents: tangents, bitangents: bitangents)
    }

    /// A fine, partly embedded upholstery welt following the actual pillow surface.
    /// Instantiate this shared mesh with the same local transform as its pillow.
    /// The 2.2 mm cord stays within the body's silhouette and needs no collision shape.
    static func piping(size: SIMD3<Float>, face: PillowFace, inset: Float = 0.0035,
                       radius: Float = 0.0011, latitudePower: Float = 0.44,
                       longitudePower: Float = 0.48) -> MeshResource {
        let segments = 112
        let sides = 6
        let half = size * 0.5
        let smallestHalf = min(half.x, min(half.y, half.z))
        precondition(smallestHalf > 0 && latitudePower > 0 && longitudePower > 0)
        let safeInset = min(max(inset, 0.0015), smallestHalf * 0.20)
        let tubeRadius = min(max(radius, 0.0004), safeInset * 0.40)
        let xRing = 1 - safeInset / half.x
        let yRing = 1 - safeInset / half.y
        let zRing = 1 - safeInset / half.z

        func signedPower(_ value: Float, _ power: Float) -> Float {
            (value < 0 ? -1 : 1) * pow(abs(value), power)
        }

        var surfacePoints: [SIMD3<Float>] = []
        var surfaceNormals: [SIMD3<Float>] = []
        for index in 0..<segments {
            let angle = Float(index) / Float(segments) * .pi * 2
            let x = half.x * xRing * signedPower(cos(angle), longitudePower)
            let point: SIMD3<Float>
            switch face {
            case .top:
                let z = half.z * zRing * signedPower(sin(angle), longitudePower)
                let radial = pow(abs(x / half.x), 2 / longitudePower)
                    + pow(abs(z / half.z), 2 / longitudePower)
                let y = half.y * pow(max(0, 1 - pow(radial, longitudePower / latitudePower)), latitudePower / 2)
                point = SIMD3<Float>(x, y, z)
            case .front, .back:
                let y = half.y * yRing * signedPower(sin(angle), latitudePower)
                let remaining = pow(max(0, 1 - pow(abs(y / half.y), 2 / latitudePower)), latitudePower / longitudePower)
                    - pow(abs(x / half.x), 2 / longitudePower)
                let z = half.z * pow(max(0, remaining), longitudePower / 2)
                point = SIMD3<Float>(x, y, face == .front ? -z : z)
            }
            let normal = pillowNormal(at: point, half: half,
                                      latitudePower: latitudePower, longitudePower: longitudePower)
            surfacePoints.append(point - normal * (tubeRadius * 0.40))
            surfaceNormals.append(normal)
        }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uv: [SIMD2<Float>] = []
        for ring in 0...segments {
            let index = ring % segments
            let previous = surfacePoints[(index + segments - 1) % segments]
            let next = surfacePoints[(index + 1) % segments]
            let tangent = simd_normalize(next - previous)
            let side = simd_normalize(simd_cross(tangent, surfaceNormals[index]))
            let outward = simd_normalize(simd_cross(side, tangent))
            for sample in 0...sides {
                let angle = Float(sample) / Float(sides) * .pi * 2
                let normal = outward * cos(angle) + side * sin(angle)
                positions.append(surfacePoints[index] + normal * tubeRadius)
                normals.append(normal)
                uv.append(SIMD2<Float>(Float(ring) / Float(segments), Float(sample) / Float(sides)))
            }
        }
        var indices: [UInt32] = []
        for ring in 0..<segments {
            for side in 0..<sides {
                let a = UInt32(ring * (sides + 1) + side)
                let b = a + UInt32(sides + 1)
                indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        return mesh(name: "Fine \(face) upholstery welt", positions: positions,
                    normals: normals, uv: uv, indices: indices)
    }

    /// Analytic gradient of the superellipsoid's implicit equation, avoiding
    /// derivative noise at the flat face centres and at the angular seam.
    private static func pillowNormal(at point: SIMD3<Float>, half: SIMD3<Float>,
                                     latitudePower: Float, longitudePower: Float) -> SIMD3<Float> {
        let normalized = point / half
        let radial = pow(abs(normalized.x), 2 / longitudePower)
            + pow(abs(normalized.z), 2 / longitudePower)
        let radialFactor = pow(max(radial, 1e-12), longitudePower / latitudePower - 1)
        func derivative(_ value: Float, power: Float) -> Float {
            (value < 0 ? -1 : 1) * pow(abs(value), power)
        }
        let gradient = SIMD3<Float>(
            radialFactor * derivative(normalized.x, power: 2 / longitudePower - 1) / half.x,
            derivative(normalized.y, power: 2 / latitudePower - 1) / half.y,
            radialFactor * derivative(normalized.z, power: 2 / longitudePower - 1) / half.z)
        return simd_normalize(gradient)
    }

    /// A continuous cloth chart with its only singularity hidden underneath the cushion.
    /// Longitude/latitude UVs collapse the broad top into a fan, which makes normal maps
    /// and anisotropic highlights inherit a different tangent on every top triangle.
    /// Derive this chart's basis from its own gradients rather than per-triangle UVs.
    private static func pillowTextureFrame(at point: SIMD3<Float>, normal: SIMD3<Float>,
                                           half: SIMD3<Float>) -> (uv: SIMD2<Float>, tangent: SIMD3<Float>, bitangent: SIMD3<Float>) {
        let p = point / half
        let distance = simd_length(p)
        let denominator = distance + p.y
        if denominator < 1e-5 {
            return (SIMD2<Float>(0.5, 0.5), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1))
        }
        let denominatorGradient = SIMD3<Float>(p.x / (distance * half.x),
                                               (1 + p.y / distance) / half.y,
                                               p.z / (distance * half.z))
        let scale = 0.5 / (denominator * denominator)
        let uGradient = (SIMD3<Float>(denominator / half.x, 0, 0)
                         - denominatorGradient * p.x) * scale
        let vGradient = (denominatorGradient * p.z
                         - SIMD3<Float>(0, 0, denominator / half.z)) * scale
        var tangent = simd_normalize(simd_cross(vGradient, normal))
        if simd_dot(tangent, uGradient) < 0 { tangent = -tangent }
        let bitangent = simd_normalize(simd_cross(normal, tangent))
        return (SIMD2<Float>(0.5 + 0.5 * p.x / denominator,
                            0.5 - 0.5 * p.z / denominator), tangent, bitangent)
    }

    /// A vertical cylindrical patch. Horizontal UVs follow the arc continuously.
    static func screen(width: Float, height: Float) -> MeshResource {
        let segments = 64
        let angle = asin(width * 0.5 / screenRadius)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uv: [SIMD2<Float>] = []
        for column in 0...segments {
            let u = Float(column) / Float(segments)
            let theta = -angle + angle * 2 * u
            let x = screenRadius * sin(theta)
            let z = screenRadius * (1 - cos(theta))
            for v: Float in [0, 1] {
                positions.append(SIMD3<Float>(x, (v - 0.5) * height, z))
                normals.append(SIMD3<Float>(-sin(theta), 0, cos(theta)))
                uv.append(SIMD2<Float>(u, v))
            }
        }
        var indices: [UInt32] = []
        for column in 0..<segments {
            let a = UInt32(column * 2)
            indices += [a, a + 2, a + 1, a + 2, a + 3, a + 1]
        }
        return mesh(name: "Continuous curved cinema screen", positions: positions, normals: normals, uv: uv, indices: indices)
    }

    /// The same screen curve viewed from above, with a small physical front/back thickness.
    static func screenRibbon(width: Float, depth: Float) -> MeshResource {
        let segments = 64
        let angle = asin(width * 0.5 / screenRadius)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uv: [SIMD2<Float>] = []
        for column in 0...segments {
            let u = Float(column) / Float(segments)
            let theta = -angle + angle * 2 * u
            let center = SIMD3<Float>(screenRadius * sin(theta), 0, screenRadius * (1 - cos(theta)))
            let normal = SIMD3<Float>(-sin(theta), 0, cos(theta))
            for v: Float in [0, 1] {
                positions.append(center + normal * ((v - 0.5) * depth))
                normals.append(SIMD3<Float>(0, 1, 0))
                uv.append(SIMD2<Float>(u, v))
            }
        }
        var indices: [UInt32] = []
        for column in 0..<segments {
            let a = UInt32(column * 2)
            indices += [a, a + 1, a + 2, a + 2, a + 1, a + 3]
        }
        return mesh(name: "Silver screen arc", positions: positions, normals: normals, uv: uv, indices: indices)
    }

    private static func mesh(name: String, positions: [SIMD3<Float>], normals: [SIMD3<Float>], uv: [SIMD2<Float>], indices: [UInt32],
                             tangents: [SIMD3<Float>]? = nil, bitangents: [SIMD3<Float>]? = nil) -> MeshResource {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        if let tangents { descriptor.tangents = .init(tangents) }
        if let bitangents { descriptor.bitangents = .init(bitangents) }
        descriptor.textureCoordinates = .init(uv)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            preconditionFailure("Invalid deterministic cinema mesh: \(error)")
        }
    }
}
