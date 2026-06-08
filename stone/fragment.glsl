// ===============================
// Fragment Shader
// Simple Stone / Marble
// ===============================

uniform vec3 baseColor; // = vec3(0.62, 0.60, 0.57);
uniform vec3 darkColor; // = vec3(0.28, 0.26, 0.25);
uniform vec3 lightColor;//= vec3(0.84, 0.82, 0.79);
uniform vec3 veinColor;  //= vec3(0.47, 0.45, 0.43);


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
        p = m * p + 0.17;
        a *= 0.5;
    }

    return s;
}

float stoneHeight(vec2 uv)
{
    vec2 p = uv * 5.0;

    // Soft domain warp for natural variation
    vec2 w;
    w.x = fbm(p * 0.55 + vec2(1.3, 4.7));
    w.y = fbm(p * 0.55 + vec2(8.1, 2.2));
    p += (w - 0.5) * 1.8;

    // Broad stone flow
    float bands = sin(p.x * 1.3 + fbm(p * 0.9) * 2.8);
    bands += 0.6 * sin((p.x + p.y) * 0.8 + fbm(p * 1.2) * 2.0);

    // Fine grain
    float grain = fbm(p * 4.0);
    grain += 0.5 * fbm(p * 8.0 + 3.7);

    // Slight crackle / mineral breakup
    float speck = noise(p * 14.0);
    speck = smoothstep(0.55, 0.95, speck);

    return bands * 0.18 + grain * 0.22 + speck * 0.08;
}

void main()
{
    // Use vPos.xy for planes / flat surfaces.
    // If needed, try vPos.xz for your object.
    vec2 uv = vPos.xy;

    float h  = stoneHeight(uv);
    float hx = stoneHeight(uv + vec2(0.006, 0.0)) - h;
    float hy = stoneHeight(uv + vec2(0.0, 0.006)) - h;

    vec3 N = normalize(vec3(-hx * 18.0, -hy * 18.0, 1.0));
    vec3 L = normalize(vec3(-0.35, 0.55, 0.78));
    vec3 V = normalize(vec3(0.15, -0.10, 1.0));

    float diffuse = clamp(dot(N, L) * 0.5 + 0.5, 0.0, 1.0);

    // Hardcoded stone colors
    
    // Color breakup
    float m1 = fbm(uv * 4.5);
    float m2 = fbm(uv * 9.0 + 2.3);
    float veins = smoothstep(0.48, 0.80, abs(sin((uv.x + fbm(uv * 1.5) * 0.9) * 4.0)));
    float blotch = smoothstep(0.25, 0.85, m1);

    vec3 col = mix(darkColor, baseColor, blotch);
    col = mix(col, lightColor, m2 * 0.18);
    col = mix(col, veinColor, veins * 0.35);

    // Lighting
    col *= 0.72 + 0.55 * diffuse;

    // Soft polish highlight
    vec3 R = reflect(-L, N);
    float spec = pow(max(dot(R, V), 0.0), 24.0);
    col += lightColor * spec * 0.18;

    // Tiny mineral flecks
    float fleck = noise(uv * 35.0);
    fleck = smoothstep(0.86, 0.98, fleck);
    col += fleck * 0.06;

    FragColor = vec4(col, 1.0);
}