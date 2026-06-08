out vec3 vPos;

void main()
{
    vPos = pos;
    gl_Position = ModelViewProjectionMatrix * vec4(pos, 1.0);
}