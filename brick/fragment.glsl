uniform vec3 baseColor;
uniform vec3 darkColor;
uniform vec3 lightColor;
uniform vec3 veinColor;

in vec3 vPos;

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

    return mix(
        mix(a, b, f.x),
        mix(c, d, f.x),
        f.y
    );
}

float fbm(vec2 p)
{
    float s = 0.0;
    float a = 0.5;

    for(int i = 0; i < 5; i++)
    {
        s += a * noise(p);
        p *= 2.03;
        a *= 0.5;
    }

    return s;
}

float brickHeight(vec2 uv, out float mortarMask)
{
    uv *= 6.0;

    float row = floor(uv.y);

    if(mod(row, 2.0) > 0.5)
        uv.x += 0.5;

    vec2 cell = fract(uv);

    float mortar =
        max(
            smoothstep(0.00, 0.06, cell.x) *
            (1.0 - smoothstep(0.94, 1.00, cell.x)),
            smoothstep(0.00, 0.06, cell.y) *
            (1.0 - smoothstep(0.94, 1.00, cell.y))
        );

    mortarMask = mortar;

    vec2 local = floor(uv);

    float brickRand = hash21(local);

    float surface =
        fbm(uv * 1.8 + brickRand * 20.0);

    float grain =
        fbm(uv * 8.0 + brickRand * 50.0);

    float chips =
        smoothstep(
            0.82,
            0.96,
            noise(uv * 10.0 + brickRand * 80.0)
        );

    float brick =
        0.25 +
        surface * 0.20 +
        grain * 0.06 -
        chips * 0.08;

    return mix(0.0, brick, mortar);
}

void main()
{
    vec2 uv = vPos.xy;

    float mortar;

    float h =
        brickHeight(uv, mortar);

    float hx =
        brickHeight(
            uv + vec2(0.003,0.0),
            mortar
        ) - h;

    float hy =
        brickHeight(
            uv + vec2(0.0,0.003),
            mortar
        ) - h;

    vec3 N =
        normalize(
            vec3(
                -hx * 28.0,
                -hy * 28.0,
                1.0
            )
        );

    vec3 L =
        normalize(
            vec3(
                -0.35,
                 0.55,
                 0.78
            )
        );

    vec3 V =
        normalize(
            vec3(
                0.15,
               -0.10,
                1.0
            )
        );

    float diffuse =
        clamp(
            dot(N,L) * 0.5 + 0.5,
            0.0,
            1.0
        );

    vec2 brickUV = uv * 6.0;

    float row = floor(brickUV.y);

    if(mod(row,2.0) > 0.5)
        brickUV.x += 0.5;

    vec2 brickID = floor(brickUV);

    float brickVariation =
        hash21(brickID);

    vec3 col =
        mix(
            darkColor,
            baseColor,
            brickVariation
        );

    float surface =
        fbm(brickUV * 1.6);

    col =
        mix(
            col,
            lightColor,
            surface * 0.25
        );

    col =
        mix(
            veinColor,
            col,
            mortar
        );

    col *=
        0.72 +
        diffuse * 0.55;

    vec3 R = reflect(-L, N);

    float spec =
        pow(
            max(dot(R, V), 0.0),
            16.0
        );

    col +=
        lightColor *
        spec *
        0.08;

    FragColor = vec4(col, 1.0);
}