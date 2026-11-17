import simd

/// The view frustum as five half-spaces in render space, for culling tiles.
///
/// The planes come from the rows of the view-projection matrix (Gribb and Hartmann). A box is culled
/// only when its positive vertex lies outside one plane, so the whole box is outside the frustum.
/// Anything not certainly outside is drawn. There is no far plane: the projection has an infinite
/// far plane (reverse-Z), so nothing far ahead is culled.
///
/// The planes, in clip coordinates with `k = 1 + margin`:
/// - left `x + k·w ≥ 0`, right `k·w − x ≥ 0`, bottom and top likewise with y;
/// - near `w ≥ 0.5`, the same cut as `lineV` in `Shaders.swift`, which drops anything nearer.
///
/// Why the margin is 0.02. A line is widened on screen by `halfW = 0.5·widthPx + 1` pixels, where
/// `widthPx = 1.6·H/1440` for a frame H pixels high, and it is extended past its endpoints by
/// `0.5·widthPx`. A tile whose box is outside the frustum by `margin` in NDC is outside the screen by
/// `margin·H/2` pixels in height (and `margin·W/2` in width). Its segments reach at most
/// `0.5·widthPx + 1 + 0.5·widthPx` pixels past the box, so they cannot touch the screen when
/// `margin·H/2 > 1.6·H/1440 + 1`. At H = 360 (640 × 360, the smallest size) the left side is 3.6 px and
/// the right side is about 1.4 px. The margin is in clip space, so the same fraction of the screen
/// holds at any depth. Width is larger than height at a 16:9 frame, so height is the binding case.
public struct Frustum: Sendable {
    /// Each plane `p` keeps points with `p.x·x + p.y·y + p.z·z + p.w ≥ 0`.
    private let left: SIMD4<Float>
    private let right: SIMD4<Float>
    private let bottom: SIMD4<Float>
    private let top: SIMD4<Float>
    private let near: SIMD4<Float>
    public let margin: Float

    /// `viewProjection` is `Camera.viewProjection(aspect:)`, the same matrix as the uniforms.
    public init(viewProjection m: simd_float4x4, margin: Float = 0.02) {
        self.margin = margin
        // Row i of the matrix is column i of its transpose.
        let t = m.transpose
        let r0 = t.columns.0, r1 = t.columns.1, r3 = t.columns.3
        let k = 1 + margin
        left = r0 + k * r3
        right = k * r3 - r0
        bottom = r1 + k * r3
        top = k * r3 - r1
        near = r3 - SIMD4<Float>(0, 0, 0, 0.5)
    }

    /// True unless the box, in render space (x east, y up, z minus north), is wholly outside a plane.
    public func intersects(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> Bool {
        !(outside(left, lo, hi) || outside(right, lo, hi) || outside(bottom, lo, hi)
            || outside(top, lo, hi) || outside(near, lo, hi))
    }

    /// The box's positive vertex for this plane: the corner furthest along the plane's normal.
    @inline(__always)
    private func outside(_ p: SIMD4<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Bool {
        let x = p.x >= 0 ? hi.x : lo.x
        let y = p.y >= 0 ? hi.y : lo.y
        let z = p.z >= 0 ? hi.z : lo.z
        return p.x * x + p.y * y + p.z * z + p.w < 0
    }
}
