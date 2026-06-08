uniform float u_scale;      // 0.1 - 20.0
uniform float u_speed;      // 0.0 - 10.0

uniform vec3 u_color_a;     // e.g. vec3(1,0,0)
uniform vec3 u_color_b;     // e.g. vec3(0,1,1)
uniform vec3 u_color_c;     // e.g. vec3(1,0,1)

in vec3 vPos;

mat2 rot(float a)
{
    float s = sin(a);
    float c = cos(a);
    return mat2(c, -s, s, c);
}

void main()
{
    float t = u_time * u_speed;

    vec3 p = vPos * u_scale;

    p.xy *= rot(p.z * 0.8 + t * 0.7);
    p.xz *= rot(p.y * 0.6 - t * 0.5);
    p.yz *= rot(p.x * 0.4 + t * 0.9);

    float c = 0.0;

    c += sin(p.x * 8.0 + t);
    c += sin(p.y * 9.0 - t * 1.3);
    c += sin(p.z * 10.0 + t * 0.7);

    c += sin(length(p.xy) * 12.0 - t * 4.0);
    c += sin(length(p.xz) * 14.0 + t * 3.0);
    c += sin(length(p.yz) * 16.0 - t * 2.0);

    p += 0.35 * sin(vec3(
        p.y * 3.0 + t,
        p.z * 3.0 - t,
        p.x * 3.0 + t
    ));

    c += sin((p.x + p.y + p.z) * 7.0);

    float bands = 0.5 + 0.5 * sin(c * 2.5);

    // Three-color gradient
    vec3 col;

    if (bands < 0.5)
    {
        col = mix(u_color_a, u_color_b, bands * 2.0);
    }
    else
    {
        col = mix(u_color_b, u_color_c, (bands - 0.5) * 2.0);
    }

    float glow = 1.5 + 0.8 * abs(sin(c));

    col *= glow;

    col = pow(col, vec3(0.7));

    FragColor = vec4(col, 1.0);
}