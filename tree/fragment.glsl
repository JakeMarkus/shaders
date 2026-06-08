// =========================
// Fragment shader
// =========================

uniform float u_scale;          // 0.1 - 20.0
uniform float u_speed;          // 0.0 - 10.0
uniform float u_wind_strength;  // 0.0 - 1.5
uniform float u_leaf_density;   // 0.5 - 3.0

uniform vec3 u_shadow_color;    // deep canopy shadow
uniform vec3 u_mid_color;       // main leaf green
uniform vec3 u_light_color;     // sunlit green
uniform vec3 u_sun_color;       // warm highlight tint
uniform vec3 u_light_dir;       // e.g. vec3(0.4, 0.8, 0.2)

in vec3 vPos;

float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p)
{
    float n = hash12(p);
    return vec2(n, hash12(p + n + 19.19));
}

float noise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p)
{
    float v = 0.0;
    float a = 0.5;
    mat2 m = mat2(1.6, 1.2, -1.2, 1.6);

    for (int i = 0; i < 5; i++)
    {
        v += a * noise(p);
        p = m * p;
        a *= 0.5;
    }

    return v;
}

vec2 wind(vec2 p, float t)
{
    float g1 = fbm(p * 0.35 + vec2(t * 0.05, -t * 0.03));
    float g2 = fbm(p * 0.90 - vec2(t * 0.07,  t * 0.04));

    vec2 w = vec2(
        sin(t * 1.3 + p.x * 1.7 + g1 * 6.2831),
        cos(t * 1.1 + p.y * 1.4 + g2 * 6.2831)
    );

    return w;
}

float leafCluster(vec2 uv, float scale, float t, float seed)
{
    vec2 g = uv * scale;
    vec2 id = floor(g);
    vec2 f = fract(g) - 0.5;

    float n = hash12(id + seed);
    vec2 o = hash22(id + seed) - 0.5;

    o += 0.18 * vec2(
        sin(t * 1.4 + n * 6.2831 + id.x * 0.6),
        cos(t * 1.2 + n * 6.2831 + id.y * 0.6)
    );

    // Slightly leaf-like rather than perfectly circular.
    vec2 q = f - o * 0.35;
    float ellipse = abs(q.x) * 0.95 + abs(q.y) * 0.60;
    float d = mix(length(q), ellipse, 0.55);

    float leaf = smoothstep(0.46, 0.10, d);
    leaf *= 0.55 + 0.45 * n;

    return leaf;
}

void main()
{
    float t = u_time * u_speed;
    vec3 p = vPos * u_scale;

    // Wind-driven motion that gets stronger toward the outer canopy.
    vec2 warp = vec2(
        fbm(p.xz * 0.70 + vec2(t * 0.04, -t * 0.02)),
        fbm(p.zx * 0.70 - vec2(t * 0.03,  t * 0.05))
    );

    float gustMask = 0.35 + 0.65 * fbm(p.xz * 0.18 + t * 0.02);
    p.xz += (warp - 0.5) * u_wind_strength * 0.35 * gustMask;
    p.xz += wind(p.xz, t) * u_wind_strength * 0.08 * gustMask;

    // Layered foliage patterns.
    float broad  = fbm(p.xz * 0.85 + vec2(0.0, t * 0.03));
    float medium = fbm(p.xz * 3.00 - vec2(t * 0.06, t * 0.05));
    float fine   = fbm(p.xz * 10.0 + vec2(t * 0.18, -t * 0.14));

    float density = u_leaf_density;

    float leafA = leafCluster(p.xz + 0.12 * vec2(broad, medium), 2.4 * density, t, 1.7);
    float leafB = leafCluster(p.xz * 1.35 + 0.25 * vec2(medium, fine), 4.5 * density, t * 1.2, 3.3);
    float leafC = leafCluster(p.xz * 2.60 + 0.15 * vec2(fine, broad), 8.0 * density, t * 1.6, 5.9);

    float leaves = clamp(leafA * 0.85 + leafB * 0.55 + leafC * 0.30, 0.0, 1.0);
    leaves = smoothstep(0.20, 0.95, leaves);

    // Vertical canopy depth: brighter on top, darker inward.
    float canopyDepth = smoothstep(-1.1, 0.9, p.y);

    // Self-shadow pockets.
    float cavity = fbm(p.xz * 5.0 + vec2(t * 0.03, -t * 0.02));
    float pocketShadow = 1.0 - 0.45 * smoothstep(0.35, 0.85, cavity);

    // Fake normal from noise gradient for directional light response.
    float h  = fbm(p.xz * 1.15);
    float hx = fbm((p.xz + vec2(0.03, 0.0)) * 1.15);
    float hz = fbm((p.xz + vec2(0.0, 0.03)) * 1.15);

    vec3 n = normalize(vec3(h - hx, 0.45, h - hz));
    vec3 l = normalize(u_light_dir);
    float ndl = clamp(dot(n, l), 0.0, 1.0);
    float wrapLight = 0.25 + 0.75 * ndl;

    // Sun flecks that shimmer through the canopy.
    float sunFleck = pow(clamp(fbm(p.xz * 18.0 + vec2(t * 0.35, t * 0.21)), 0.0, 1.0), 4.0);
    float shimmer = 0.5 + 0.5 * sin(t * 2.0 + p.x * 3.0 + p.z * 4.0 + broad * 6.2831);

    vec3 col = mix(u_shadow_color, u_mid_color, canopyDepth);
    col = mix(col, u_light_color, wrapLight * 0.72);
    col *= mix(0.70, 1.18, leaves);
    col *= pocketShadow;

    col += u_sun_color * sunFleck * (0.10 + 0.55 * leaves) * (0.35 + 0.65 * wrapLight);
    col += u_sun_color * shimmer * 0.03 * leaves;

    // Slight edge darkening to help it read as a volume.
    float edgeDark = smoothstep(0.95, 0.10, length(p.xz) + max(0.0, -p.y) * 0.35);
    col *= mix(0.55, 1.0, edgeDark);

    col = clamp(col, 0.0, 1.0);
    col = pow(col, vec3(0.85));

    FragColor = vec4(col, 1.0);
}