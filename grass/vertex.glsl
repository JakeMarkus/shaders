out vec3 vWorldPos;
out float vHeight;

uniform mat4 u_grassMatrix;
uniform float u_windStrength;

void main()
{
    vec3 p = pos;

    // Height mask (bottom stays planted)
    vHeight = clamp(p.y, 0.0, 1.0);

    // Wind
    float phase =
        u_time * 2.5 +
        p.x * 3.1 +
        p.y * 2.7;

    float sway =
        (sin(phase) * 0.08 +
         sin(phase * 2.3) * 0.03)
        * u_windStrength;

    p.x += sway * vHeight;
    p.y += sway * 0.35 * vHeight;

    vec4 worldPos = u_grassMatrix * vec4(p, 1.0);

    vWorldPos = worldPos.xyz;

    gl_Position = ModelViewProjectionMatrix * vec4(p, 1.0);
}