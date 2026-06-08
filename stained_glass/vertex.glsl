// ---- VERTEX ----

out vec3 vWorldPos;

uniform mat4 u_planeMatrix;
uniform mat4 u_heatSource;

uniform float radius; 
uniform float strength;
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float smoothNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i + vec2(0,0)), hash(i + vec2(1,0)), u.x),
        mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), u.x),
        u.y
    );
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * smoothNoise(p);
        p *= 2.1;
        a *= 0.5;
    }
    return v;
}

void main()
{
    vec3 p = pos;

    vec3 heatPos = u_heatSource[3].xyz;
    vec3 worldP = (u_planeMatrix * vec4(p, 1.0)).xyz;

    float dist = length(worldP.xy - heatPos.xy);
    float repulsion = smoothstep(radius, 0.0, dist) * strength;

    float disp = fbm(p.xy * 1.4 + u_time * 0.04);
    disp += fbm(p.xy * 3.1 - u_time * 0.06) * 0.4;
    p.z += (disp - 0.5) * 0.6;

    p.z -= repulsion;

    vec4 worldPos = u_planeMatrix * vec4(p, 1.0);
    vWorldPos = worldPos.xyz;

    gl_Position = ModelViewProjectionMatrix * vec4(p, 1.0);
}