uniform vec3 u_target_pos;
uniform vec3 u_object_pos;
uniform float u_effect_radius;

uniform vec3 u_color_near;
uniform vec3 u_color_far;

in vec3 vWorldPos;

void main()
{
    float dist = distance(vWorldPos, u_target_pos);

    float influence =
        1.0 - smoothstep(
            0.0,
            u_effect_radius,
            dist
        );

    vec3 color = mix(
        u_color_far,
        u_color_near,
        influence
    );

    FragColor = vec4(
    fract(u_object_pos * 0.1),
    1.0
);
}