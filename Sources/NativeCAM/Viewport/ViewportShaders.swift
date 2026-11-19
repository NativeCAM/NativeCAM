// Metal Shading Language source for the viewport, compiled at runtime with
// `MTLDevice.makeLibrary(source:options:)` (the Command Line Tools ship no offline `metal` compiler).
//
// Buffer bindings (both stages):
//   0  stage_in vertices (color / mesh pipelines) or BackgroundUniforms (background fragment)
//   1  FrameUniforms
//   2  MeshUniforms (color / mesh pipelines) or HeightUniforms (height field / walls)
// Texture 0: height field (r32Float, read access).
//
// Depth is reversed-Z (clear 0, compare greater-equal), which keeps float depth precise from 1 mm to many metres.

enum ViewportShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4x4 viewProj;
    float4 eye;       // xyz: camera position (world)
    float4 lightDir;  // xyz: unit vector towards the key light (world)
    float4 params;    // xy: viewport size in pixels, z: pixels per world unit at view depth 1
};

struct MeshUniforms {
    float4x4 model;
    float4 color;     // multiplied with vertex color (color pipeline) or base color (mesh pipeline)
    float4 params;    // x: specular strength, y: shininess, z: depth pull towards eye (fraction of view distance),
                      // w: grid spacing for distance fading (0 = off)
};

struct HeightUniforms {
    float4 dims;      // x: columns, y: rows, z: cell size (mm), w: floorZ
    float4 origin;    // xy: world XY of cell (0,0) centre, z: material thickness, w: cut-through epsilon
    float4 topColor;
    float4 cutColor;
    float4 deepColor;
    float4 sideColor;
};

struct BackgroundUniforms {
    float4 top;
    float4 bottom;
};

// ---------------------------------------------------------------- lighting

inline float3 shade(float3 base, float3 n, float3 world, constant FrameUniforms& f,
                    float specStrength, float shininess) {
    float3 v = normalize(f.eye.xyz - world);
    if (dot(n, v) < 0.0) { n = -n; }          // two-sided: always light the face we see
    float3 l = f.lightDir.xyz;
    float diff = max(dot(n, l), 0.0);
    float hemi = 0.5 + 0.5 * n.z;             // sky (up) vs ground fill
    float rim = max(dot(n, v), 0.0);          // gentle headlight so faces turned away never go black
    float3 h = normalize(l + v);
    float spec = specStrength * pow(max(dot(n, h), 0.0), shininess);
    return base * (0.22 + 0.12 * hemi + 0.14 * rim + 0.58 * diff) + spec;
}

// ---------------------------------------------------------------- background

struct BackgroundOut {
    float4 position [[position]];
    float t;
};

vertex BackgroundOut background_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    BackgroundOut o;
    o.position = float4(p, 0.0, 1.0);
    o.t = p.y * 0.5 + 0.5;
    return o;
}

fragment float4 background_fragment(BackgroundOut in [[stage_in]],
                                    constant BackgroundUniforms& u [[buffer(0)]]) {
    float t = saturate(in.t);
    t = t * t * (3.0 - 2.0 * t);
    return float4(mix(u.bottom.rgb, u.top.rgb, t), 1.0);
}

// ---------------------------------------------------------------- unlit per-vertex color (lines, grid, bed)

struct ColorIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct ColorOut {
    float4 position [[position]];
    float4 color;
    float viewDepth;
};

vertex ColorOut color_vertex(ColorIn in [[stage_in]],
                             constant FrameUniforms& f [[buffer(1)]],
                             constant MeshUniforms& m [[buffer(2)]]) {
    float3 p = (m.model * float4(in.position, 1.0)).xyz;
    // Pull towards the eye so lines lying on a surface win the depth test against it.
    p += (f.eye.xyz - p) * m.params.z;
    ColorOut o;
    o.position = f.viewProj * float4(p, 1.0);
    o.color = in.color * m.color;
    o.viewDepth = o.position.w;
    return o;
}

fragment float4 color_fragment(ColorOut in [[stage_in]],
                               constant FrameUniforms& f [[buffer(1)]],
                               constant MeshUniforms& m [[buffer(2)]]) {
    float4 c = in.color;
    if (m.params.w > 0.0) {
        float px = m.params.w * f.params.z / max(in.viewDepth, 1e-3);   // on-screen spacing in pixels
        c.a *= smoothstep(3.0, 10.0, px);
    }
    if (c.a <= 0.002) {
        discard_fragment();
    }
    return c;
}

// ---------------------------------------------------------------- lit meshes (tool, stock box)

struct MeshIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct LitOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
};

vertex LitOut mesh_vertex(MeshIn in [[stage_in]],
                          constant FrameUniforms& f [[buffer(1)]],
                          constant MeshUniforms& m [[buffer(2)]]) {
    float4 w = m.model * float4(in.position, 1.0);
    LitOut o;
    o.position = f.viewProj * w;
    o.world = w.xyz;
    o.normal = (m.model * float4(in.normal, 0.0)).xyz;
    return o;
}

fragment float4 mesh_fragment(LitOut in [[stage_in]],
                              constant FrameUniforms& f [[buffer(1)]],
                              constant MeshUniforms& m [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    return float4(shade(m.color.rgb, n, in.world, f, m.params.x, m.params.y), m.color.a);
}

// ---------------------------------------------------------------- height field (carved stock)

inline float hf_at(texture2d<float, access::read> t, int x, int y, int cols, int rows, float floorZ) {
    uint2 c = uint2(clamp(x, 0, cols - 1), clamp(y, 0, rows - 1));
    return max(t.read(c).r, floorZ);
}

struct HeightOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
};

// One triangle strip per row pair, instanced over rows: vertex_id walks the columns
// (even = this row, odd = next row), instance_id selects the row. No vertex or index buffers.
vertex HeightOut heightfield_vertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    constant FrameUniforms& f [[buffer(1)]],
                                    constant HeightUniforms& h [[buffer(2)]],
                                    texture2d<float, access::read> tex [[texture(0)]]) {
    int cols = int(h.dims.x);
    int rows = int(h.dims.y);
    float cs = h.dims.z;
    float floorZ = h.dims.w;
    int col = int(vid >> 1);
    int row = int(iid) + int(vid & 1u);

    float z = hf_at(tex, col, row, cols, rows, floorZ);
    // Sobel gradient: smoother than a plain central difference on the staircase edges of the grid.
    int c0 = max(col - 1, 0), c1 = min(col + 1, cols - 1);
    int r0 = max(row - 1, 0), r1 = min(row + 1, rows - 1);
    float zA = hf_at(tex, c0, r0, cols, rows, floorZ), zB = hf_at(tex, col, r0, cols, rows, floorZ);
    float zC = hf_at(tex, c1, r0, cols, rows, floorZ), zD = hf_at(tex, c0, row, cols, rows, floorZ);
    float zE = hf_at(tex, c1, row, cols, rows, floorZ), zF = hf_at(tex, c0, r1, cols, rows, floorZ);
    float zG = hf_at(tex, col, r1, cols, rows, floorZ), zH = hf_at(tex, c1, r1, cols, rows, floorZ);
    float dzdx = ((zC + 2.0 * zE + zH) - (zA + 2.0 * zD + zF)) / (4.0 * max(float(c1 - c0), 1.0) * cs);
    float dzdy = ((zF + 2.0 * zG + zH) - (zA + 2.0 * zB + zC)) / (4.0 * max(float(r1 - r0), 1.0) * cs);

    float3 world = float3(h.origin.x + float(col) * cs, h.origin.y + float(row) * cs, z);
    HeightOut o;
    o.position = f.viewProj * float4(world, 1.0);
    o.world = world;
    o.normal = float3(-dzdx, -dzdy, 1.0);
    return o;
}

fragment float4 heightfield_fragment(HeightOut in [[stage_in]],
                                     constant FrameUniforms& f [[buffer(1)]],
                                     constant HeightUniforms& h [[buffer(2)]]) {
    float floorZ = h.dims.w;
    float eps = h.origin.w;

    // Cut-through: only the floor itself is removed (fragments whose interpolated height is at the
    // floor). Triangles spanning a cut and an uncut cell are the walls of the through-cut and stay.
    if (in.world.z <= floorZ + eps) {
        discard_fragment();
    }

    float thickness = max(h.origin.z, 1e-3);
    float depth = saturate(-in.world.z / thickness);
    float cut = smoothstep(0.02, 0.30, -in.world.z);
    float3 cutColor = mix(h.cutColor.rgb, h.deepColor.rgb, depth);
    float3 base = mix(h.topColor.rgb, cutColor, cut);

    // Faint wandering grain lines along X on the uncut face, faded out before they can alias.
    float phase = in.world.y * 0.75 + 4.0 * sin(in.world.x * 0.004 + in.world.y * 0.021)
                + 2.0 * sin(in.world.y * 0.093 + in.world.x * 0.0017);
    float grainAA = saturate(1.5 - 2.0 * fwidth(phase));
    float strength = 0.35 + 0.65 * saturate(0.5 + 0.5 * sin(in.world.y * 0.31 + in.world.x * 0.0031)
                                                  * sin(in.world.y * 0.047 + 1.3));
    float grainLine = pow(abs(sin(phase)), 8.0) * strength;
    base *= 1.0 - 0.06 * grainLine * grainAA * (1.0 - cut);

    float3 n = normalize(in.normal);
    return float4(shade(base, n, in.world, f, 0.05, 24.0), 1.0);
}

// Four side walls of the block, from the border cells' heights down to floorZ.
// Instances 0/1: front (row 0) / back (last row), walking columns. 2/3: left / right, walking rows.
vertex HeightOut wall_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant FrameUniforms& f [[buffer(1)]],
                             constant HeightUniforms& h [[buffer(2)]],
                             texture2d<float, access::read> tex [[texture(0)]]) {
    int cols = int(h.dims.x);
    int rows = int(h.dims.y);
    float cs = h.dims.z;
    float floorZ = h.dims.w;
    int i = int(vid >> 1);
    bool bottom = (vid & 1u) != 0;

    int col;
    int row;
    float3 n;
    if (iid == 0) {
        col = i; row = 0; n = float3(0.0, -1.0, 0.0);
    } else if (iid == 1) {
        col = i; row = rows - 1; n = float3(0.0, 1.0, 0.0);
    } else if (iid == 2) {
        col = 0; row = i; n = float3(-1.0, 0.0, 0.0);
    } else {
        col = cols - 1; row = i; n = float3(1.0, 0.0, 0.0);
    }
    float top = hf_at(tex, col, row, cols, rows, floorZ);
    float z = bottom ? floorZ : top;
    float3 world = float3(h.origin.x + float(clamp(col, 0, cols - 1)) * cs,
                          h.origin.y + float(clamp(row, 0, rows - 1)) * cs, z);
    HeightOut o;
    o.position = f.viewProj * float4(world, 1.0);
    o.world = world;
    o.normal = n;
    return o;
}

fragment float4 wall_fragment(HeightOut in [[stage_in]],
                              constant FrameUniforms& f [[buffer(1)]],
                              constant HeightUniforms& h [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    // Subtle plywood-ish banding through the thickness.
    float band = sin(in.world.z * 2.2);
    float3 base = h.sideColor.rgb * (1.0 + 0.03 * band);
    return float4(shade(base, n, in.world, f, 0.03, 16.0), 1.0);
}
"""#
}
