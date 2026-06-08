// ===============================
// Fragment Shader
// Single Cartoon Cloud
// Transparent Background
// ===============================

uniform float u_scale;   // 0.2 - 20.0
uniform vec3  u_seed;    // object position seed

in vec3 vPos;

float hash31(vec3 p)
{
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

float hash21(vec2 p)
{
    return hash31(vec3(p, dot(p, vec2(127.1, 311.7))));
}

float noise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p)
{
    float s = 0.0;
    float a = 0.5;

    for (int i = 0; i < 5; i++)
    {
        s += a * noise(p);
        p = p * 2.03 + vec2(17.2, 9.1);
        a *= 0.5;
    }

    return s;
}

float puff(vec2 p, vec2 c, float r, float soft)
{
    float d = length(p - c);
    return 1.0 - smoothstep(r - soft, r, d);
}

void main()
{
    vec2 uv = vPos.xy * u_scale;
    float t = u_time * 0.18;

    // Seeded variation from object position
    float s1 = hash31(u_seed + vec3(1.7, 4.2, 9.1));
    float s2 = hash31(u_seed + vec3(8.3, 2.4, 6.6));
    float s3 = hash31(u_seed + vec3(5.1, 7.7, 3.9));

    // Center shift so every plane gets a different cloud layout
    vec2 center = (vec2(s1, s2) - 0.5) * 0.45;
    uv -= center;

    // Very gentle animation / deformation
    vec2 drift = vec2(
        sin(t + s1 * 6.2831),
        cos(t * 1.17 + s2 * 6.2831)
    ) * 0.05;

    vec2 warp;
    warp.x = fbm(uv * 1.5 + vec2(0.0, t * 0.7) + s3 * 8.0);
    warp.y = fbm(uv * 1.5 + vec2(5.3, -t * 0.6) + s1 * 8.0);
    uv += (warp - 0.5) * 0.10 + drift;

    // One cloud made from several puffs
    float cloud = 0.0;

    // Main body
    cloud = max(cloud, puff(uv, vec2(0.00, -0.01), 0.30, 0.12));
    cloud = max(cloud, puff(uv, vec2(-0.14, 0.00), 0.22, 0.10));
    cloud = max(cloud, puff(uv, vec2( 0.16, 0.02), 0.24, 0.11));
    cloud = max(cloud, puff(uv, vec2(-0.05, 0.14), 0.20, 0.09));
    cloud = max(cloud, puff(uv, vec2( 0.10, 0.15), 0.18, 0.09));

    // Seeded extra puffs so each cloud feels random
    for (int i = 0; i < 4; i++)
    {
        float fi = float(i);
        float a = 6.2831 * hash31(u_seed + vec3(fi * 1.3, fi * 2.1, fi * 3.7));
        float rr = mix(0.08, 0.20, hash31(u_seed + vec3(fi * 5.2, 2.9, 8.1)));
        vec2 off = vec2(cos(a), sin(a)) * rr;

        off += vec2(
            sin(t * 0.8 + fi * 2.0),
            cos(t * 0.9 + fi * 1.4)
        ) * 0.015;

        float r = mix(0.12, 0.19, hash31(u_seed + vec3(fi * 7.1, 4.4, 1.9)));
        float soft = mix(0.08, 0.11, hash31(u_seed + vec3(3.1, fi * 6.2, 8.8)));
        cloud = max(cloud, puff(uv, off, r, soft));
    }

    // Slightly stretch the top for a cartoon cloud silhouette
    float dome = puff(uv * vec2(1.0, 0.92), vec2(0.0, 0.08), 0.34, 0.14);
    cloud = max(cloud, dome);

    // Soft edge / alpha
    float alpha = smoothstep(0.18, 0.88, cloud);

    // Tiny internal breakup so it doesn't look flat
    float detail = fbm(uv * 5.0 + vec2(s1 * 10.0, s2 * 10.0) + t * 0.4);
    alpha *= 0.90 + detail * 0.10;

    // Cartoon shading
    vec3 cloudTop    = vec3(1.00, 1.00, 1.00);
    vec3 cloudMid    = vec3(0.94, 0.95, 0.98);
    vec3 cloudShadow = vec3(0.79, 0.83, 0.90);

    float light = smoothstep(-0.18, 0.30, uv.y + 0.12);
    float shade = fbm(uv * 2.2 + vec2(2.0, -1.5) + t * 0.25);
    shade = smoothstep(0.35, 0.85, shade);

    vec3 col = mix(cloudShadow, cloudMid, light);
    col = mix(col, cloudTop, smoothstep(0.55, 0.95, cloud));
    col = mix(col, cloudShadow, shade * 0.55);

    // Bright top highlight
    col += cloudTop * pow(max(0.0, 1.0 - length(uv * vec2(1.0, 0.9)) * 2.0), 2.0) * 0.10;

    // Keep background transparent
    col *= alpha;

    FragColor = vec4(col, alpha);
}