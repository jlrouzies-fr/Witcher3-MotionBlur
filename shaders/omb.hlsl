// Object Motion Blur - compute passes, run right after DLSS on the 4K linear-HDR image (before bloom / tonemap / UI).
//
// Inputs (render resolution, from the game's own DLSS preparation):
//   MV    r16g16_float, written by ConvertMotionVectors (0x9F1C32F1): prevUV - uv per pixel, camera + object motion
//   Depth r32 (D32S8 copy the game makes right after), raw device depth
// The camera part of the motion is rebuilt exactly like 0x9F1C32F1 does (depth + previous-frame matrix from its
// constant buffer), so "objects only" removes it and keeps the true per-object motion.
//
// Reconstruction filter after McGuire et al. 2012 / Jimenez 2014: tile max -> 3x3 neighbour max -> depth-aware gather
// along the dominant neighbourhood velocity. Normalised weights in linear HDR (exposure unchanged), no jitter (no grain,
// nothing for the eye to see flicker frame to frame).

struct Params
{
    float2 outSize;     // output (post-DLSS) size, px
    float2 mvSize;      // motion-vector / depth size, px
    float shutter;      // fraction of the frame time the shutter is open (0.5 = 180 degrees)
    float maxLen;       // max blur length, output px (full length, centre to both ends)
    float objectsOnly;  // 1 = subtract the camera motion
    float reversedZ;    // 1 = depth 0 is the far plane
    float tile;         // tile size, MV px
    float samples;      // gather samples
    float debug;        // 1 = output the blur vectors as colours
    float pad;
    float4 unused[5];
};
cbuffer Push : register(b0) { Params P; }
// GPU copy of ConvertMotionVectors' constants: [0] = (w, h, 1/w, 1/h), [1..4] reprojection rows
cbuffer Cam : register(b1) { float4 cam[5]; }

Texture2D<float4> Color : register(t0);
Texture2D<float2> MV : register(t1);
Texture2D<float> Depth : register(t2);
Texture2D<float2> Tiles : register(t3);
RWTexture2D<float4> Out : register(u0);
RWTexture2D<float2> TilesOut : register(u1);

float2 CameraMV(int2 pix, float d)
{
    float2 uv = (float2(pix) + 0.5) * cam[0].zw;
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float cx = cam[1].x * ndc.x + cam[2].x * ndc.y + cam[3].x * d + cam[4].x;
    float cy = cam[1].y * ndc.x + cam[2].y * ndc.y + cam[3].y * d + cam[4].y;
    float cw = cam[1].w * ndc.x + cam[2].w * ndc.y + cam[3].w * d + cam[4].w;
    float2 prevUV = float2(0.5 * cx / cw + 0.5, -0.5 * cy / cw + 0.5);
    return prevUV - uv;
}

// blur vector at an MV pixel, in output pixels (shutter applied, length clamped)
float2 VelocityPx(int2 pix)
{
    pix = clamp(pix, int2(0, 0), int2(P.mvSize) - 1);
    float2 mv = MV.Load(int3(pix, 0));
    if (P.objectsOnly > 0.5)
    {
        // The sky (far plane) is not reprojected by the game: its motion vector is the raw velocity buffer (0), so it
        // has no camera part to remove. Camera cuts give huge reprojections: no object motion there either.
        float d = Depth.Load(int3(pix, 0));
        float2 c = CameraMV(pix, d);
        bool far = P.reversedZ > 0.5 ? d <= 1e-6 : d >= 1.0 - 1e-6;
        bool raw = all(mv == 0.0);
        mv = (far || raw || dot(c, c) > 0.04) ? 0.0 : mv - c;
    }
    float2 v = mv * P.outSize * P.shutter;
    float len = length(v);
    return len > P.maxLen ? v * (P.maxLen / len) : v;
}

float LinZ(int2 pix)
{
    float d = Depth.Load(int3(clamp(pix, int2(0, 0), int2(P.mvSize) - 1), 0));
    return P.reversedZ > 0.5 ? 1.0 / max(d, 1e-7) : 1.0 / max(1.0 - d, 1e-7);
}

// pass 1: one thread per tile, longest blur vector inside it
[numthreads(8, 8, 1)]
void TileMax(uint3 id : SV_DispatchThreadID)
{
    int t = (int)P.tile;
    int2 base = int2(id.xy) * t;
    if (any(base >= int2(P.mvSize))) return;
    float2 best = 0;
    float bestLen = 0;
    for (int y = 0; y < t; ++y)
        for (int x = 0; x < t; ++x)
        {
            float2 v = VelocityPx(base + int2(x, y));
            float l = dot(v, v);
            if (l > bestLen) { bestLen = l; best = v; }
        }
    TilesOut[id.xy] = best;
}

// pass 2: longest of the 3x3 neighbouring tiles, so a moving object's blur can spread over the static background
[numthreads(8, 8, 1)]
void NeighborMax(uint3 id : SV_DispatchThreadID)
{
    uint w, h;
    Tiles.GetDimensions(w, h);
    if (id.x >= w || id.y >= h) return;
    float2 best = 0;
    float bestLen = 0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
        {
            float2 v = Tiles.Load(int3(clamp(int2(id.xy) + int2(x, y), int2(0, 0), int2(w, h) - 1), 0));
            float l = dot(v, v);
            if (l > bestLen) { bestLen = l; best = v; }
        }
    TilesOut[id.xy] = best;
}

float Cone(float dist, float len) { return saturate(1.0 - dist / max(len, 1e-3)); }
float Cylinder(float dist, float len) { return 1.0 - smoothstep(0.95 * len, 1.05 * len + 1e-3, dist); }

// pass 3: gather at output resolution
[numthreads(8, 8, 1)]
void Gather(uint3 id : SV_DispatchThreadID)
{
    int2 p = int2(id.xy);
    if (any(p >= int2(P.outSize))) return;
    float4 c0 = Color.Load(int3(p, 0));
    float2 scale = P.mvSize / P.outSize;
    int2 mp = int2((float2(p) + 0.5) * scale);
    float2 vn = Tiles.Load(int3(mp / (int)P.tile, 0));
    float lenN = length(vn);
    [branch] if (P.debug > 0.5)
    {
        // 1 = blur vector, 2 = raw game motion vector, 3 = rebuilt camera motion, 4 = depth
        // hue = direction, brightness = sqrt(length / 64 px); tile max shown as a dim overlay
        int2 mc = clamp(mp, int2(0, 0), int2(P.mvSize) - 1);
        float dd = Depth.Load(int3(mc, 0));
        if (P.debug > 3.5)
        {
            Out[p] = float4(saturate(dd * 100.0), dd == 0.0 ? 1.0 : 0.0, saturate((log10(max(dd, 1e-12)) + 8.0) / 8.0), c0.a);
            return;
        }
        float2 v = P.debug > 2.5 ? CameraMV(mc, dd) * P.outSize : P.debug > 1.5 ? MV.Load(int3(mc, 0)) * P.outSize : VelocityPx(mp);
        float l = saturate(sqrt(length(v) / 64.0));
        float a = atan2(v.y, v.x) / 6.2831853 + 0.5;
        float3 hue = saturate(abs(frac(a + float3(0, 2, 1) / 3.0) * 6.0 - 3.0) - 1.0);
        Out[p] = float4(hue * l + 0.15 * saturate(lenN / 32.0), c0.a);
        return;
    }
    [branch] if (lenN < 0.5)
    {
        Out[p] = c0;
        return;
    }

    float2 vc = VelocityPx(mp);
    float lenC = length(vc);
    float zc = LinZ(mp);
    float wc = 1.0 / max(lenC, 1.0);
    float3 acc = c0.rgb * wc;
    float tot = wc;
    int n = (int)P.samples;
    [loop] for (int j = 0; j < n; ++j)
    {
        float t = lerp(-0.5, 0.5, (j + 0.5) / n);
        float2 o = vn * t;
        float dist = length(o);
        int2 sp = clamp(int2(float2(p) + o + 0.5), int2(0, 0), int2(P.outSize) - 1);
        int2 ms = int2((float2(sp) + 0.5) * scale);
        float2 vs = VelocityPx(ms);
        float lenS = length(vs);
        float zs = LinZ(ms);
        float front = saturate((zc - zs) / (0.04 * zc) * 0.5 + 0.5);  // 1 = sample in front of this pixel
        float w = front * Cone(dist, lenS) + (1.0 - front) * Cone(dist, lenC) + Cylinder(dist, lenS) * Cylinder(dist, lenC) * 2.0;
        acc += Color.Load(int3(sp, 0)).rgb * w;
        tot += w;
    }
    float3 blurred = acc / tot;
    Out[p] = float4(lerp(c0.rgb, blurred, saturate(lenN - 0.5)), c0.a);
}
