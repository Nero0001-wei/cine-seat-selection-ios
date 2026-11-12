import RealityKit
import UIKit
import simd
import OSLog

/// Shared, linear-light studio illumination, independent of the visible background.
@MainActor
enum CinemaLightingEnvironment {
    static let resource = Task<EnvironmentResource?, Never> { @MainActor in
        guard let image = panorama() else { return nil }
        do {
            let resource = try await EnvironmentResource(equirectangular: image, withName: "CINE auditorium lighting")
            Logger(subsystem: "com.cine.seatdemo", category: "Rendering").info("Shared HDR lighting environment ready")
            return resource
        } catch {
            Logger(subsystem: "com.cine.seatdemo", category: "Rendering").error("Lighting environment generation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func panorama() -> CGImage? {
        let width = 512, height = 256
        let warmDirection = simd_normalize(SIMD3<Float>(-0.6, 0.72, -0.35))
        let coolDirection = simd_normalize(SIMD3<Float>(0.55, 0.38, 0.74))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let latitude = (0.5 - (Float(y) + 0.5) / Float(height)) * .pi
            for x in 0..<width {
                let longitude = ((Float(x) + 0.5) / Float(width) - 0.5) * 2 * .pi
                let direction = SIMD3<Float>(sin(longitude) * cos(latitude), sin(latitude),
                                             cos(longitude) * cos(latitude))
                let ceiling = pow(max(0, direction.y), 4)
                let warm = pow(max(0, simd_dot(direction, warmDirection)), 46)
                let cool = pow(max(0, simd_dot(direction, coolDirection)), 28)
                let rgb = SIMD3<Float>(0.050, 0.056, 0.070)
                    + SIMD3<Float>(0.16, 0.17, 0.19) * ceiling
                    + SIMD3<Float>(2.2, 2.15, 2.0) * warm
                    + SIMD3<Float>(0.48, 0.58, 0.78) * cool
                let offset = (y * width + x) * 4
                pixels[offset] = rgb.x
                pixels[offset + 1] = rgb.y
                pixels[offset + 2] = rgb.z
                pixels[offset + 3] = 1
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            .union(.floatComponents).union(.byteOrder32Little)
        return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                       bytesPerRow: width * 16, space: space, bitmapInfo: bitmap,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
