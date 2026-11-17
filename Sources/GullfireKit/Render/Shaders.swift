/// Metal shader source, from the verified spike. It is compiled at start with
/// `makeLibrary(source:)`, so no build step is needed.
///
/// The solid vertex buffer is `packed_float3`: `solids.bin` is 12 bytes per vertex.
/// Reading it as a 16-byte `float3` gives garbage that still half-looks like a city.
public enum Shaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4x4 vp; float2 viewport; float widthPx; float bias; float4 color; float fadeDist; float cutoff; float3 eye; };
    struct Seg { packed_float3 a; packed_float3 b; };
    struct SolidOut { float4 pos [[position]]; };
    vertex SolidOut solidV(uint vid [[vertex_id]], const device packed_float3 *p [[buffer(0)]], constant U &u [[buffer(1)]]) {
        SolidOut o; o.pos = u.vp * float4(float3(p[vid]), 1); return o;
    }
    fragment void solidF() {}
    struct LineOut { float4 pos [[position]]; float across; float halfW; float dist; float3 world; };
    vertex LineOut lineV(uint vid [[vertex_id]], uint iid [[instance_id]], const device Seg *s [[buffer(0)]], constant U &u [[buffer(1)]]) {
        const float2 corner[6] = { {0,-1},{1,-1},{0,1},{0,1},{1,-1},{1,1} };
        float4 A = u.vp * float4(float3(s[iid].a), 1), B = u.vp * float4(float3(s[iid].b), 1);
        LineOut o; o.across = 0; o.halfW = 0; o.dist = 0;
        const float nearW = 0.5;
        if (A.w < nearW && B.w < nearW) { o.pos = float4(2, 2, 2, 1); return o; }
        if (A.w < nearW) A = mix(A, B, (nearW - A.w) / (B.w - A.w));
        if (B.w < nearW) B = mix(B, A, (nearW - B.w) / (A.w - B.w));
        float2 hv = 0.5 * u.viewport;
        float2 sa = A.xy / A.w * hv, sb = B.xy / B.w * hv;
        float2 d = sb - sa; float len = length(d);
        float2 dir = len > 1e-5 ? d / len : float2(1, 0);
        float2 n = float2(-dir.y, dir.x);
        float halfW = 0.5 * u.widthPx + 1.0;
        float2 c = corner[vid];
        float4 P = c.x > 0.5 ? B : A;
        float2 off = n * c.y * halfW + dir * (c.x > 0.5 ? 0.5 : -0.5) * u.widthPx;
        o.pos = float4(P.xy + off / hv * P.w, P.z * (1.0 + u.bias), P.w);
        o.across = c.y * halfW; o.halfW = 0.5 * u.widthPx; o.dist = P.w; o.world = c.x > 0.5 ? float3(s[iid].b) : float3(s[iid].a);
        return o;
    }
    fragment float4 lineF(LineOut i [[stage_in]], constant U &u [[buffer(1)]]) {
        float a = saturate(i.halfW + 0.5 - abs(i.across));
        float fade = u.fadeDist > 0 ? saturate(u.fadeDist / max(i.dist, 1.0)) : 1.0;
        float edge = u.cutoff > 0 ? saturate((u.cutoff - distance(i.world, u.eye)) / (0.2 * u.cutoff)) : 1.0;
        return u.color * a * mix(0.25, 1.0, fade) * edge;
    }
    """
}
