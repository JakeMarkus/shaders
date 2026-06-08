uniform vec3 baseColor; 
void main()
{
    FragColor = vec4(baseColor.x, baseColor.y, baseColor.z, 1.0);
}