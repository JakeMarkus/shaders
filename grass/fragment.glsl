uniform float radius;
uniform float shadowStrength;

uniform mat4 u_shadowObject;
uniform mat4 u_shadowObject2;
uniform mat4 u_grassMatrix;

uniform vec3 colorSeed;

uniform vec3 bottomColor; //vec3(0.08, 0.35, 0.05);
uniform vec3 topColor; //vec3(0.45, 1.00, 0.25);
in vec3 vWorldPos;
in float vHeight;

void main()
{
    vec3 center1 = u_shadowObject[3].xyz;
    vec3 center2 = u_shadowObject2[3].xyz;

    vec3 grassColor = mix(bottomColor, topColor, vHeight);

    //--------------------------------
    // Vertical striations
    //--------------------------------
    float stripes =
        sin(vWorldPos.x * 40.0 +
            vWorldPos.z * 25.0) * 0.5 + 0.5;

    stripes = pow(stripes, 3.0);

    grassColor += stripes * 0.08;

    //--------------------------------
    // World-space variation
    //--------------------------------
    float variation =
        fract(
            sin(
                dot(
                    floor(vWorldPos.xz * 5.0),
                    vec2(12.9898, 78.233)
                )
            ) * 43758.5453
        );

    //--------------------------------
    // User-controlled color seed
    //--------------------------------
    float seedVariation =
        fract(
            sin(
                dot(u_grassMatrix[3].xyz,
                    vec3(127.1, 311.7, 74.7))
            ) * 43758.5453
        );

    vec3 tint = mix(
        vec3(0.85, 0.95, 0.85), // darker/desaturated
        vec3(1.20, 1.25, 0.80), // warmer/lighter
        seedVariation
    );

    grassColor *= mix(0.85, 1.15, variation);
    grassColor *= tint;

    //--------------------------------
    // Shadow 1
    //--------------------------------
    float d1 = distance(vWorldPos, center1);

    float shadow1 =
        1.0 -
        smoothstep(
            radius * 0.6,
            radius,
            d1
        );

    //--------------------------------
    // Shadow 2
    //--------------------------------
    float d2 = distance(vWorldPos, center2);

    float shadow2 =
        1.0 -
        smoothstep(
            radius * 0.6,
            radius,
            d2
        );

    //--------------------------------
    // Combine shadows
    //--------------------------------
    float shadow = max(shadow1, shadow2);

    grassColor *= mix(
        1.0,
        1.0 - shadowStrength,
        shadow
    );

    FragColor = vec4(grassColor, 1.0);
}