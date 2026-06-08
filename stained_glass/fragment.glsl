// ---- FRAGMENT ----

in vec3 vWorldPos;

uniform mat4 u_planeMatrix;
uniform mat4 u_heatSource;   // the object acting as heat — move it around

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Voronoi — returns distance to nearest cell center
float voronoi(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float minDist = 1.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 cell = neighbor + vec2(
                hash(i + neighbor),
                hash(i + neighbor + vec2(31.4, 17.9))
            ) - f;
            minDist = min(minDist, dot(cell, cell));
        }
    }
    return sqrt(minDist);
}

void main()
{
    vec3 heatPos = u_heatSource[3].xyz;

    // Distance from this fragment to the heat source
    float dist = distance(vWorldPos, heatPos);
    float heat = 1.0 - smoothstep(0.0, 4.0, dist);
    // Pulsing heat — breathes slowly
    heat *= 0.85 + 0.15 * sin(u_time * 1.2 - dist * 0.8);

    //--------------------------------
    // Voronoi cracks
    // Two layers at different scales for detail
    //--------------------------------
    float v1 = voronoi(vWorldPos.xz * 2.5);
    float v2 = voronoi(vWorldPos.xz * 6.0 + vec2(4.7, 2.3));

    // Crack = thin bands at cell edges (low voronoi value = near an edge)
    float crack1 = smoothstep(0.0, 0.12, v1);
    float crack2 = smoothstep(0.0, 0.08, v2);
    float crack = crack1 * crack2;  // both layers must agree = crack

    //--------------------------------
    // Rock color
    // Cool = near black basalt, hot = deep red/orange
    //--------------------------------
    vec3 coolRock = vec3(0.10, 0.08, 0.08);
    vec3 warmRock = vec3(0.35, 0.12, 0.04);
    vec3 rockColor = mix(coolRock, warmRock, heat * 0.6);

    // World-space variation so it's not uniform
    float variation = fract(
        sin(dot(floor(vWorldPos.xz * 3.0), vec2(12.9898, 78.233)))
        * 43758.5453
    );
    rockColor *= mix(0.8, 1.2, variation);

    //--------------------------------
    // Lava glow inside cracks
    // Hot cracks glow orange-white, cool cracks are just dark
    //--------------------------------
    vec3 coolCrack = vec3(0.04, 0.03, 0.03);
    vec3 hotCrack  = vec3(1.0,  0.45, 0.05);
    vec3 crackColor = mix(coolCrack, hotCrack, heat);

    // Crack edge brightening — the very lip of the crack is brightest
    float crackEdge = 1.0 - smoothstep(0.0, 0.18, v1);
    crackColor += vec3(0.6, 0.2, 0.0) * crackEdge * heat;

    //--------------------------------
    // Combine rock surface and cracks
    //--------------------------------
    vec3 color = mix(crackColor, rockColor, crack);

    //--------------------------------
    // Surface glow — rock itself gets
    // a red-hot tint directly under heat source
    //--------------------------------
    float innerGlow = heat * heat;
    color += vec3(0.4, 0.08, 0.0) * innerGlow * crack;  // only on rock, not cracks

    // Bright core directly under the source
    float core = exp(-dist * dist * 0.4);
    color += vec3(1.0, 0.6, 0.1) * core * 0.5;

    FragColor = vec4(color, 1.0);
}