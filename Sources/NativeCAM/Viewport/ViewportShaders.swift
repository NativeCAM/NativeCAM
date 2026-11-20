// Metal Shading Language source for the viewport, compiled at runtime with
// `MTLDevice.makeLibrary(source:options:)` (the Command Line Tools ship no offline `metal` compiler).
//
// Buffer bindings (both stages):
//   0  stage_in vertices (color / mesh pipelines) or BackgroundUniforms (background fragment)
//   1  FrameUniforms
//   2  MeshUniforms (color / mesh pipelines), HeightUniforms (height field / walls) or RotaryUniforms (rotary blank)
//   3  face angles in radians, one float per face (rotary blank)
// Texture 0: height field (r32Float, read access); a 2D array with one slice per face for the rotary blank.
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

// ---------------------------------------------------------------- rotary blank
//
// An indexed rotary job is simulated as one height field per face, each in its face's frame (world coordinates
// as they are with the blank turned to that face's angle). The material left is the blank minus everything above
// any face's height field, so its surface is drawn as the parts of each surface that are inside every other
// solid: the blank's own surface where no face cut it, and each face's carved surface where it's inside the blank
// and no other face cut it away. "Blank frame" is relative to the axis with the blank at A0; a face turned to
// angle a maps a blank-frame point p to face coordinates rot(a) p, right-hand rule about +X.

struct RotaryUniforms {
    float4 dims;      // x: columns, y: rows, z: cell size (mm), w: floorZ of the face grids
    float4 origin;    // xy: world XY of cell (0,0) centre, z: axis to the faces (mm), w: epsilon (mm)
    float4 axis;      // xy: world Y and Z of the rotation axis, z: blank angle now (radians), w: 1 = square bar
    float4 counts;    // x: number of faces
    float4 topColor;
    float4 cutColor;
    float4 deepColor;
    float4 sideColor;
};

struct RotaryOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 blank;     // blank frame, relative to the axis
    float depth;      // below the face top (face surfaces only)
    int layer [[flat]];
};

inline float2 rot2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

inline float hfa_at(texture2d_array<float, access::read> t, int x, int y, int layer, int cols, int rows, float floorZ) {
    uint2 c = uint2(clamp(x, 0, cols - 1), clamp(y, 0, rows - 1));
    return max(t.read(c, uint(layer)).r, floorZ);
}

// True when a face other than `skip` cut away the blank-frame point `b`.
inline bool rotary_removed(float3 b, int skip, constant RotaryUniforms& u, constant float* angles,
                           texture2d_array<float, access::read> t) {
    int cols = int(u.dims.x), rows = int(u.dims.y);
    float cs = u.dims.z;
    int col = int(round((b.x - u.origin.x) / cs));
    int faces = int(u.counts.x);
    for (int i = 0; i < faces; i++) {
        if (i == skip) { continue; }
        float2 q = rot2(b.yz, angles[i]) + u.axis.xy;    // face i's coordinates (world, with the blank at its angle)
        int row = int(round((q.x - u.origin.y) / cs));
        float h = hfa_at(t, col, row, i, cols, rows, u.dims.w);
        if (q.y > h + u.origin.w) { return true; }
    }
    return false;
}

inline float rotary_extent(float2 b, constant RotaryUniforms& u) {
    return u.axis.w > 0.5 ? max(abs(b.x), abs(b.y)) : length(b);
}

// Each face's carved surface: one strip per row pair, instanced over rows and then faces.
vertex RotaryOut rotary_face_vertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    constant FrameUniforms& f [[buffer(1)]],
                                    constant RotaryUniforms& u [[buffer(2)]],
                                    constant float* angles [[buffer(3)]],
                                    texture2d_array<float, access::read> tex [[texture(0)]]) {
    int cols = int(u.dims.x);
    int rows = int(u.dims.y);
    float cs = u.dims.z;
    float floorZ = u.dims.w;
    int strips = max(rows - 1, 1);
    int layer = int(iid) / strips;
    int col = int(vid >> 1);
    int row = int(iid) % strips + int(vid & 1u);

    float z = hfa_at(tex, col, row, layer, cols, rows, floorZ);
    int c0 = max(col - 1, 0), c1 = min(col + 1, cols - 1);
    int r0 = max(row - 1, 0), r1 = min(row + 1, rows - 1);
    float zA = hfa_at(tex, c0, r0, layer, cols, rows, floorZ), zB = hfa_at(tex, col, r0, layer, cols, rows, floorZ);
    float zC = hfa_at(tex, c1, r0, layer, cols, rows, floorZ), zD = hfa_at(tex, c0, row, layer, cols, rows, floorZ);
    float zE = hfa_at(tex, c1, row, layer, cols, rows, floorZ), zF = hfa_at(tex, c0, r1, layer, cols, rows, floorZ);
    float zG = hfa_at(tex, col, r1, layer, cols, rows, floorZ), zH = hfa_at(tex, c1, r1, layer, cols, rows, floorZ);
    float dzdx = ((zC + 2.0 * zE + zH) - (zA + 2.0 * zD + zF)) / (4.0 * max(float(c1 - c0), 1.0) * cs);
    float dzdy = ((zF + 2.0 * zG + zH) - (zA + 2.0 * zB + zC)) / (4.0 * max(float(r1 - r0), 1.0) * cs);

    float3 d = float3(u.origin.x + float(col) * cs, u.origin.y + float(row) * cs, z);
    float2 rel = d.yz - u.axis.xy;
    float face = angles[layer];
    float turn = u.axis.z - face;
    float3 world = float3(d.x, rot2(rel, turn) + u.axis.xy);
    float3 n = float3(-dzdx, -dzdy, 1.0);
    n.yz = rot2(n.yz, turn);

    RotaryOut o;
    o.position = f.viewProj * float4(world, 1.0);
    o.world = world;
    o.normal = n;
    o.blank = float3(d.x, rot2(rel, -face));
    o.depth = -z;
    o.layer = layer;
    return o;
}

fragment float4 rotary_face_fragment(RotaryOut in [[stage_in]],
                                     constant FrameUniforms& f [[buffer(1)]],
                                     constant RotaryUniforms& u [[buffer(2)]],
                                     constant float* angles [[buffer(3)]],
                                     texture2d_array<float, access::read> tex [[texture(0)]]) {
    float eps = u.origin.w;
    float radius = max(u.origin.z, 1e-3);
    // Cut right through to the far side of the blank: nothing left to draw.
    if (-in.depth <= u.dims.w + eps) { discard_fragment(); }
    // Only where the face was cut into the blank: its uncut sheet is the blank's own surface (or air beside a
    // round blank).
    if (rotary_extent(in.blank.yz, u) >= radius - eps) { discard_fragment(); }
    if (rotary_removed(in.blank, in.layer, u, angles, tex)) { discard_fragment(); }

    float depth = saturate(in.depth / radius);
    float3 base = mix(u.cutColor.rgb, u.deepColor.rgb, depth);
    return float4(shade(base, normalize(in.normal), in.world, f, 0.05, 24.0), 1.0);
}

// The blank's uncut surface and end caps, turned to the blank's angle.
vertex RotaryOut rotary_blank_vertex(MeshIn in [[stage_in]],
                                     constant FrameUniforms& f [[buffer(1)]],
                                     constant RotaryUniforms& u [[buffer(2)]]) {
    float a = u.axis.z;
    float3 world = float3(in.position.x, rot2(in.position.yz, a) + u.axis.xy);
    RotaryOut o;
    o.position = f.viewProj * float4(world, 1.0);
    o.world = world;
    o.normal = float3(in.normal.x, rot2(in.normal.yz, a));
    o.blank = in.position;
    o.depth = 0.0;
    o.layer = -1;
    return o;
}

fragment float4 rotary_blank_fragment(RotaryOut in [[stage_in]],
                                      constant FrameUniforms& f [[buffer(1)]],
                                      constant RotaryUniforms& u [[buffer(2)]],
                                      constant float* angles [[buffer(3)]],
                                      texture2d_array<float, access::read> tex [[texture(0)]]) {
    if (rotary_removed(in.blank, -1, u, angles, tex)) { discard_fragment(); }
    float3 n = normalize(in.normal);
    bool cap = abs(n.x) > 0.5;
    float3 base = cap ? u.sideColor.rgb : u.topColor.rgb;
    if (!cap) {
        // Faint grain running along the blank.
        float around = atan2(in.blank.z, in.blank.y) * u.origin.z;
        float phase = around * 0.75 + 4.0 * sin(in.blank.x * 0.004 + around * 0.021);
        float grainAA = saturate(1.5 - 2.0 * fwidth(phase));
        base *= 1.0 - 0.06 * pow(abs(sin(phase)), 8.0) * grainAA;
    }
    return float4(shade(base, n, in.world, f, 0.05, 24.0), 1.0);
}
"""#
}
