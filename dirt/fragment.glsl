uniform vec3 darkDirt;
uniform vec3 lightDirt;

uniform float patchScale;   // Large color regions
uniform float detailScale;  // Medium detail
uniform float grainScale;   // Fine grains

in vec3 vWorldPos;

float hash(vec2 p)
{
    return fract(
        sin(dot(p, vec2(127.1, 311.7))) *
        43758.5453123
    );
}

float noise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);

    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    vec2 u = f * f * (3.0 - 2.0 * f);

    return mix(
        mix(a, b, u.x),
        mix(c, d, u.x),
        u.y
    );
}

float fbm(vec2 p)
{
    float v = 0.0;
    float a = 0.5;

    for(int i = 0; i < 5; i++)
    {
        v += noise(p) * a;
        p *= 2.0;
        a *= 0.5;
    }

    return v;
}

void main()
{
    vec2 uv = vWorldPos.xz;

    //--------------------------------
    // Dirt layers
    //--------------------------------

    float large  = fbm(uv * patchScale);
    float medium = fbm(uv * detailScale);
    float grains = fbm(uv * grainScale);

    //--------------------------------
    // Base dirt colors
    //--------------------------------

    vec3 color = mix(
        darkDirt,
        lightDirt,
        large
    );

    //--------------------------------
    // Medium variation
    //--------------------------------

    color *= 0.85 + medium * 0.3;

    //--------------------------------
    // Grain speckles
    //--------------------------------

    float specks =
        smoothstep(
            0.75,
            0.95,
            grains
        );

    color += specks * 0.08;

    //--------------------------------
    // Slight warmth variation
    //--------------------------------

    color.r += medium * 0.05;
    color.g += medium * 0.02;

    FragColor = vec4(color, 1.0);
}