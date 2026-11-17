import simd

/// A pinhole camera, looking from `eye` at `target`, in render space (x east, y up, z = -north).
public struct Camera: Sendable, Equatable {
    public var eye: SIMD3<Float>
    public var target: SIMD3<Float>
    public var fovDegrees: Float
    /// Roll about the view direction, radians (positive tilts the horizon). Zero keeps the world up.
    public var roll: Float

    public init(eye: SIMD3<Float>, target: SIMD3<Float>, fovDegrees: Float = 55, roll: Float = 0) {
        self.eye = eye
        self.target = target
        self.fovDegrees = fovDegrees
        self.roll = roll
    }

    /// Reverse-Z view-projection with an infinite far plane. Clear depth is 0 and the
    /// depth test is `.greater`. Copied from the spike; a point at distance d ahead maps to depth 1/d.
    public func viewProjection(aspect: Float) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        // Up is the world up, rolled about the view direction. With roll 0 this is exactly (0, 1, 0).
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(f, worldUp))
        let up = cos(roll) * worldUp + sin(roll) * right
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        let view = simd_float4x4(rows: [
            SIMD4(s, -simd_dot(s, eye)),
            SIMD4(u, -simd_dot(u, eye)),
            SIMD4(-f, simd_dot(f, eye)),
            SIMD4(0, 0, 0, 1),
        ])
        let t = 1 / tan(fovDegrees * .pi / 360)
        let near: Float = 1
        let proj = simd_float4x4(rows: [
            SIMD4(t / aspect, 0, 0, 0),
            SIMD4(0, t, 0, 0),
            SIMD4(0, 0, 0, near),
            SIMD4(0, 0, -1, 0),
        ])
        return proj * view
    }
}
