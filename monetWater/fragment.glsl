// ===============================
// Fragment Shader
// ===============================

uniform float u_scale;        // 0.1 - 20.0
uniform float u_speed;        // 0.0 - 10.0
uniform float u_wave_height;  // 0.0 - 1.0
uniform float u_anime_steps;  // 1.0 - 10.0
uniform float u_foam_amount;  // 0.0 - 1.0
uniform float u_brush_scale;  // 0.5 - 12.0

uniform vec3 u_color_deep;    // deep water
uniform vec3 u_color_mid;     // mid water
uniform vec3 u_color_light;   // highlights / sky tint
uniform vec3 u_color_foam;    // foam / paint highlights

in vec3 vPos;
mat2 rot(float a)
{
    float s = sin(a);
    float c = cos(a);
    return mat2(c, -s, s, c);
}

float hash21(vec2 p)
{
    p = fract(p * vec2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
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
    mat2 m = mat2(1.6, 1.2, -1.2, 1.6);

    for (int i = 0; i < 5; i++)
    {
        s += a * noise(p);
        p = m * p + 0.13;
        a *= 0.5;
    }

    return s;
}

float waterHeight(vec2 uv, float t)
{
    vec2 p = uv * u_scale;

    // Gentle domain warp for painterly movement
    vec2 warp;
    warp.x = fbm(p * 0.65 + vec2(0.0, t * 0.08));
    warp.y = fbm(p * 0.65 + vec2(t * 0.06, 2.7));
    p += (warp - 0.5) * 1.8;

    // Broad swells
    float swell = 0.0;
    swell += sin(p.x * 1.15 + t * 0.65);
    swell += sin(p.y * 1.35 - t * 0.72);
    swell += sin((p.x + p.y) * 0.85 + t * 0.42);
    swell += sin((p.x - p.y) * 0.95 - t * 0.58);

    // Fine surface detail
    float ripples = 0.0;
    ripples += sin(p.x * 8.0 + t * 3.0 + fbm(p * 1.4) * 3.5);
    ripples += sin(p.y * 9.0 - t * 2.7 + fbm(p * 1.9 + 5.2) * 3.0);
    ripples += sin((p.x + p.y) * 7.0 + t * 2.2);

    float micro = fbm(p * 3.2 + vec2(t * 0.12, -t * 0.09));
    micro += 0.5 * fbm(p * 7.0 - vec2(t * 0.18, t * 0.14));

    float h = swell * 0.18 + ripples * 0.045 + micro * 0.22;

    return h * u_wave_height;
}

vec3 shadeStroke(vec2 uv, float t, float h, float diffuse, float foam, float strokeNoise)
{
    // Base watercolor / impressionist palette blending
    float depthMix = smoothstep(-0.15, 0.18, h);
    vec3 col = mix(u_color_deep, u_color_mid, depthMix);

    // Monet-like light bloom in the brighter areas
    float lightMix = smoothstep(0.22, 0.92, diffuse);
    col = mix(col, u_color_light, lightMix * 0.38);

    // Brush-stroke direction and broken paint texture
    vec2 brushDir = normalize(vec2(0.86, 0.50));
    vec2 brushDir2 = normalize(vec2(-0.42, 0.91));

    float s1 = sin(dot(uv * u_brush_scale, brushDir) * 10.0 + t * 0.8 + strokeNoise * 6.0);
    float s2 = sin(dot(uv * u_brush_scale, brushDir2) * 14.0 - t * 0.6 + strokeNoise * 4.0);

    float strokes = 0.5 + 0.5 * s1;
    strokes *= 0.65 + 0.35 * (0.5 + 0.5 * s2);

    float blotch = fbm(uv * u_brush_scale * 0.65 + vec2(t * 0.05, -t * 0.04));
    blotch = smoothstep(0.22, 0.86, blotch);

    // Blend the brush texture into the color
    col *= mix(0.88, 1.12, strokes);
    col = mix(col, col * (0.93 + 0.18 * blotch), 0.55);

    // Anime-style stepped lighting
    float steps = max(u_anime_steps, 1.0);
    float toon = floor(diffuse * steps) / steps;
    col *= 0.58 + 0.72 * toon;

    // Soft foam and paint highlights
    col = mix(col, u_color_foam, foam * u_foam_amount);

    // Wet specular glint, kept painterly and soft
    vec3 L = normalize(vec3(-0.35, 0.65, 0.68));
    vec3 V = normalize(vec3(0.15, -0.08, 1.0));
    vec3 N = normalize(vec3(0.0, 0.0, 1.0));
    vec3 R = reflect(-L, N);
    float spec = pow(max(dot(R, V), 0.0), 22.0);
    col += spec * u_color_light * 0.20;

    // Slight color separation for a painted look
    col.r *= 0.98 + 0.02 * sin(t + uv.x * 3.0);
    col.g *= 0.99 + 0.01 * sin(t * 0.8 + uv.y * 2.0);
    col.b *= 1.01 + 0.02 * sin(t * 0.6 + (uv.x + uv.y) * 1.5);

    return col;
}

void main()
{
    float t = u_time * u_speed;

    // Standard Blender plane assumption: use x/y.
    // If your plane is in a different orientation, try vPos.xz.
    vec2 uv = vPos.xy;

    float h  = waterHeight(uv, t);
    float hx = waterHeight(uv + vec2(0.006, 0.0), t) - h;
    float hy = waterHeight(uv + vec2(0.0, 0.006), t) - h;

    // Fake normal from the height field for stylized water lighting
    vec3 N = normalize(vec3(-hx * 14.0, -hy * 14.0, 1.0));

    vec3 L = normalize(vec3(-0.25, 0.55, 0.80));
    vec3 V = normalize(vec3(0.12, -0.10, 1.0));

    float diffuse = dot(N, L) * 0.5 + 0.5;
    diffuse = clamp(diffuse, 0.0, 1.0);

    // Impressionist foam concentrates on crests and steeper areas
    float slope = clamp((abs(hx) + abs(hy)) * 18.0, 0.0, 1.0);
    float crest = smoothstep(0.02, 0.16, h + fbm(uv * (u_brush_scale * 0.9) + t * 0.25) * 0.08);
    float foam = crest * slope;

    // Soft foam streaks
    foam *= 0.55 + 0.45 * fbm(uv * (u_brush_scale * 2.2) + vec2(t * 0.2, -t * 0.15));
    foam = clamp(foam, 0.0, 1.0);

    float strokeNoise = fbm(uv * u_brush_scale * 1.25 + vec2(t * 0.12, t * 0.07));

    vec3 col = shadeStroke(uv, t, h, diffuse, foam, strokeNoise);

    // Watercolor softness and a little glow
    col = pow(max(col, 0.0), vec3(0.92));
    col += u_color_light * foam * 0.06;

    FragColor = vec4(col, 1.0);
}