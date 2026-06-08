out vec3 vWorldPos;

void main()
{
    vec4 worldPos = ModelMatrix * vec4(pos, 1.0);

    vWorldPos = worldPos.xyz;

    gl_Position = ModelViewProjectionMatrix * vec4(pos, 1.0);
}