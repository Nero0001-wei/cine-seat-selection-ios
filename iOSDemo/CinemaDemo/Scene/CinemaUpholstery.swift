import Foundation
import UIKit
import RealityKit
import Metal
import simd

/// Upholstery only: this is not a material for the auditorium's floor or screen.
/// Four tileable maps are generated once and shared by every seat and colour.
@MainActor
enum CinemaUpholstery {
    static func fabric(_ color: UIColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: 0.79)
        material.specular = .init(floatLiteral: 0.32)
        material.metallic = .init(floatLiteral: 0)
        material.clearcoat = .init(floatLiteral: 0)
        material.anisotropyLevel = .init(floatLiteral: 0.10)
        material.anisotropyAngle = .init(floatLiteral: 0)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            // Coloured fibre fuzz has a subdued grazing-angle sheen, not a white clearcoat.
            material.sheen = .init(tint: UIColor(red: red * 0.075, green: green * 0.075,
                                               blue: blue * 0.075, alpha: 1))
        }
        if let maps = sharedMaps {
            material.baseColor.texture = maps.albedo
            material.normal = .init(texture: maps.normal)
            // The scalar map already contains the final roughness, so do not multiply by .79.
            material.roughness = .init(scale: 1, texture: maps.roughness)
            material.ambientOcclusion = .init(texture: maps.occlusion)
            // Keep the yarn bundles resolvable in the nearest seats instead of averaging
            // all 64 warp/weft crossings into a uniform mip level.
            material.textureCoordinateTransform = .init(scale: SIMD2<Float>(4, 4))
        }
        return material
    }

    private struct Maps {
        let albedo: MaterialParameters.Texture
        let normal: MaterialParameters.Texture
        let roughness: MaterialParameters.Texture
        let occlusion: MaterialParameters.Texture
    }

    private static let sharedMaps: Maps? = {
        do { return try makeMaps() }
        catch {
            assertionFailure("Could not create shared upholstery maps: \(error)")
            return nil
        }
    }()

    private enum MapError: Error { case invalidImage }
    private static let resolution = 512
    private static let yarnCount: Float = 64
    private static let tau = Float.pi * 2

    private static func makeMaps() throws -> Maps {
        let count = resolution * resolution
        var height = [Float](repeating: 0, count: count)
        var colour = [Float](repeating: 0, count: count)
        var roughness = [Float](repeating: 0, count: count)
        var occlusion = [Float](repeating: 0, count: count)

        // A plain weave: warp and weft bend over/under each other in alternating cells.
        // Tiny longitudinal filament grooves and strand dye variation replace random grit.
        for y in 0..<resolution {
            let v = Float(y) / Float(resolution)
            for x in 0..<resolution {
                let u = Float(x) / Float(resolution)
                let warpCoordinate = u * yarnCount + 0.025 * sin(tau * v * 4)
                let weftCoordinate = v * yarnCount + 0.025 * sin(tau * u * 4)
                let warpIndex = floor(warpCoordinate)
                let weftIndex = floor(weftCoordinate)
                let warpPhase = warpCoordinate - warpIndex
                let weftPhase = weftCoordinate - weftIndex
                let warpCross = yarnCrossSection(warpPhase)
                let weftCross = yarnCrossSection(weftPhase)
                let warpOver = 0.5 + 0.5 * cos(.pi * (weftCoordinate - 0.5 + warpIndex))
                let weftOver = 0.5 - 0.5 * cos(.pi * (warpCoordinate - 0.5 + weftIndex))
                let warpHeight = warpCross * (0.20 + 0.23 * warpOver)
                let weftHeight = weftCross * (0.20 + 0.23 * weftOver)
                let difference = warpHeight - weftHeight
                let wovenHeight = (warpHeight + weftHeight + sqrt(difference * difference + 0.0009)) * 0.5
                let warpFibre = sin(tau * (u * yarnCount * 3 + 0.075 * sin(tau * v * 12)))
                let weftFibre = sin(tau * (v * yarnCount * 3 + 0.075 * sin(tau * u * 12)))
                let warpWeight = warpHeight / max(0.001, warpHeight + weftHeight)
                let fibres = warpFibre * warpWeight + weftFibre * (1 - warpWeight)
                let clothUndulation = 0.10 * sin(tau * (u * 2 + v * 3))
                    + 0.075 * cos(tau * (u * 4 - v * 2) + 0.30 * sin(tau * u))
                let warpDye = strandVariation(Int(warpIndex), seed: 29)
                let weftDye = strandVariation(Int(weftIndex), seed: 173)
                let dye = warpDye * warpWeight + weftDye * (1 - warpWeight)
                let heather = 0.55 * sin(tau * (u * 3 + v * 2) + 0.6 * sin(tau * v * 2))
                    + 0.45 * cos(tau * (u * 5 - v * 3))
                let index = y * resolution + x
                height[index] = wovenHeight + 0.018 * fibres + clothUndulation
                // Neutral modulation preserves the supplied silver, charcoal and gold tints.
                // Heather is actual low-amplitude dye variation, independent of surface
                // height and light direction. It survives mipmapping without baked shading.
                colour[index] = clamp(0.94 + 0.060 * (dye - 0.5) + 0.018 * fibres + 0.025 * heather, 0.865, 1)
                roughness[index] = clamp(0.785 + 0.075 * (dye - 0.5) - 0.020 * fibres + 0.025 * heather, 0.71, 0.87)
                occlusion[index] = 0.87 + 0.13 * max(warpCross, weftCross)
            }
        }

        var albedoBytes = [UInt8](repeating: 255, count: count * 4)
        var normalBytes = albedoBytes
        var roughnessBytes = albedoBytes
        var occlusionBytes = albedoBytes
        for y in 0..<resolution {
            for x in 0..<resolution {
                let index = y * resolution + x
                let left = y * resolution + (x + resolution - 1) % resolution
                let right = y * resolution + (x + 1) % resolution
                let up = ((y + resolution - 1) % resolution) * resolution + x
                let down = ((y + 1) % resolution) * resolution + x
                let normal = simd_normalize(SIMD3<Float>((height[left] - height[right]) * 1.25,
                                                       (height[down] - height[up]) * 1.25, 1))
                let offset = index * 4
                let albedo = byte(colour[index])
                albedoBytes[offset] = albedo
                albedoBytes[offset + 1] = albedo
                albedoBytes[offset + 2] = albedo
                normalBytes[offset] = byte(normal.x * 0.5 + 0.5)
                normalBytes[offset + 1] = byte(normal.y * 0.5 + 0.5)
                normalBytes[offset + 2] = byte(normal.z * 0.5 + 0.5)
                for channel in 0..<3 {
                    roughnessBytes[offset + channel] = byte(roughness[index])
                    occlusionBytes[offset + channel] = byte(occlusion[index])
                }
            }
        }
        return try Maps(
            albedo: texture(albedoBytes, name: "CINE woven upholstery albedo", semantic: .color),
            normal: texture(normalBytes, name: "CINE woven upholstery normal", semantic: .normal),
            roughness: texture(roughnessBytes, name: "CINE woven upholstery roughness", semantic: .scalar),
            occlusion: texture(occlusionBytes, name: "CINE woven upholstery occlusion", semantic: .scalar)
        )
    }

    private static func yarnCrossSection(_ phase: Float) -> Float {
        let distance = abs(phase - 0.5) / 0.47
        guard distance < 1 else { return 0 }
        return pow(max(0, cos(distance * .pi / 2)), 0.8)
    }

    private static func strandVariation(_ index: Int, seed: UInt32) -> Float {
        let wrapped = (index % Int(yarnCount) + Int(yarnCount)) % Int(yarnCount)
        var value = UInt32(wrapped) &+ seed
        value = (value ^ (value >> 16)) &* 0x7feb352d
        value = (value ^ (value >> 15)) &* 0x846ca68b
        value ^= value >> 16
        return Float(value & 0xffff) / 65535
    }

    private static func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
        min(high, max(low, value))
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8((clamp(value, 0, 1) * 255).rounded())
    }

    private static func texture(_ bytes: [UInt8], name: String, semantic: TextureResource.Semantic) throws -> MaterialParameters.Texture {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: resolution, height: resolution, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: resolution * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { throw MapError.invalidImage }
        let resource = try TextureResource(image: image, withName: name, options: .init(semantic: semantic))
        var sampler = MaterialParameters.Texture.Sampler()
        sampler.modify {
            $0.sAddressMode = .repeat
            $0.tAddressMode = .repeat
            $0.minFilter = .linear
            $0.magFilter = .linear
            $0.mipFilter = .linear
            $0.maxAnisotropy = 8
        }
        return .init(resource, sampler: sampler)
    }
}
