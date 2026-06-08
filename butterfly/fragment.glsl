// The MIT License
// Copyright © 2021 Inigo Quilez
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.



// The left butterfly implements a naive and wrong way to
// transition a stationary object into constant motion. The
// butterfly to the right implements the integral of the
// smoothstep() function in order to smoohtly transition
// between the two states.
//
// More information here:
//
// https://iquilezles.org/articles/smoothstepintegral



// Incorrect EaseInOut/Smoothstep velocity
float position_bad( float t, in float T )
{
    return smoothstep(0.0,T,t)*t;
    //return (t<T) ? (t*t*t)/(T*T*T)*(3.0*T-2.0*t) : t;
}

// Correct integral of EaseInOut/Smoothstep
float position_good( float t, in float T )
{
    if( t>=T ) return t - 0.5*T;
    float f = t/T;
    return f*f*f*(T-t*0.5);
}


// =======================================

vec3 trackMin( in vec3 v, in float d )
{
         if( d<v.x ) v=vec3(d,v.x,v.y); 
    else if( d<v.y ) v=vec3(v.x,d,v.y);
    else if( d<v.z ) v=vec3(v.x,v.y,d);
    return v;
}

vec4 butterfly( in vec2 p )
{
    p.x = abs(p.x);

    p.y *= 0.9;
    vec4 col = vec4(0.0);

    float a = atan(p.x,p.y);
    float r = length(p);
    
    if( p.y<0.0 )
    {
        float f = 0.6 + 0.01*sin( 24.0*a );
        float w = 1.1*a-0.8;
        f *= sin(w)*sin(w);

        float th = f + 0.001;
        float th2 = th;
        
        vec3 wcol = mix( vec3(210,119,40)/255.0, 
                         vec3(232,79,12)/255.0, smoothstep( 0.0, 0.7, r ) );
        wcol *= 1.5;

        wcol *= 1.0+0.1*sin(17.0*p.x+vec3(0,0,4))*sin(23.0*p.y+vec3(0,0,4));

        vec2 q = p;
        q.xy += 0.02*sin(q.yx*12.0);
        q.y = min(q.y,0.0);
        vec3 v = vec3(10);
        v = trackMin(v,length(q-vec2(0.29,-0.20)));
        v = trackMin(v,length(q-vec2(0.10,-0.30)));
        v = trackMin(v,length(q-vec2(0.20,-0.26)));
        v = trackMin(v,length(q-vec2(0.28,-0.29)));
        v = trackMin(v,length(q-vec2(0.34,-0.27)));
        v = trackMin(v,length(q-vec2(0.38,-0.24)));
        v = trackMin(v,length(q-vec2(0.39,-0.20)));
        v = trackMin(v,length(q-vec2(0.38,-0.15)));
        v = trackMin(v,length(q-vec2(0.35,-0.08)));

        v.yz -= v.x;
        float g = 1.25*v.y*v.z/max(v.y+v.z,0.001);
        wcol *= smoothstep(0.0,0.01,g);
        th -= 0.05*(1.0-smoothstep(0.0,0.05,g))-0.02;

        wcol *= smoothstep(0.02,0.03,(th-r)*th);

        q = vec2( mod(a,0.1)-0.05, (r-th+0.025)*3.1415*0.5 );
        float d = length( q )-0.015;
        wcol = mix( wcol, vec3(1,1,1), 1.0-smoothstep( 0.0, 0.005,d) );
        
        wcol *= smoothstep(0.01,0.03,length(p-vec2(0.235,-0.2)));
        
        d = r-(th+th2)*0.5;
        col = vec4(wcol,smoothstep( 0.0,2.0*fwidth(d),-d) );
    }
    
    if( a<2.2 )
    {
        float f = 0.65 + 0.015*sin( 24.0*a );
        float w = a*(3.1416/2.356);
        float th = f*sin(w)*sin(w) + 0.001;
        float th2 = th;
        th += 0.25*exp2( -50.0*(w-1.4)*(w-1.4) );
            
        vec3 wcol = mix( vec3(0.7,0.5,0.2), 
                         vec3(0.8,0.2,0.0), smoothstep( 0.0, 1.0, r ) );
        wcol *= 1.4;
        wcol *= 1.0+0.1*sin(13.0*p.x+vec3(0,0,4))*sin(19.0*p.y+vec3(0,0,4));

        vec3 v = vec3(10);
        v = trackMin(v,length(p-vec2(0.25,0.2)));
        v = trackMin(v,length(p-vec2(0.35,0.0)));
        v = trackMin(v,length(p-vec2(0.4,0.1)));
        v = trackMin(v,length(p-vec2(0.45,0.2)));
        v = trackMin(v,length(p-vec2(0.45,0.3)));

        v.yz -= v.x;
        float g = 2.0*v.y*v.z/max(v.y+v.z,0.001);
        wcol *= smoothstep(0.0,0.02,g);
        th2 -= 0.05*(1.0-smoothstep(0.0,0.05,g));

        float isblack = smoothstep(0.02,0.03,(th2-r)*th2);

        vec2 q = vec2( mod(a,0.1)-0.05, (r-th+0.025)*3.1415*0.5 );
        float d = length( q )-0.015;
        float ww = 1.0-smoothstep( 0.0, 0.01,d);
        
        if( r>th2 )
        {
        vec2 q = fract(p*18.0)-0.5;
        vec2 iq = floor(p*18.0);
        float id= iq.x*111.0+iq.y*13.0;
        q += 0.25*sin(id*vec2(15,17)+vec2(0,2));
        float r = 1.0+0.75*sin(id*431.0);
        ww = max( ww, 1.0-smoothstep(0.0,0.01,length(q)-0.2*r));
        }
        
        wcol = mix( wcol, vec3(ww), 1.0-isblack );
        
        d = r-th;
        
        float al = smoothstep( 0.0,2.0*fwidth(d),-d);
        col.xyz = mix( col.xyz, wcol, al );
        col.w = 1.0 - (1.0-col.w)*(1.0-al);
    }
    
    return col;
}

int hash( ivec2 z )
{
    int n = z.x+z.y*11111;
    n = (n<<13)^n;
    return (n*(n*n*15731+789221)+1376312589)>>16;
}

#if HW_PERFORMANCE==0
const int AA = 2;
#else
const int AA = 4;
#endif

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    float stime = mod( iTime, 6.0 );
    
    vec3 col = vec3(0.0);
    for( int j=0; j<AA; j++ )
    for( int i=0; i<AA; i++ )
    {
        vec2 of = vec2(i,j)/float(AA);
        vec2 p = (2.0*(fragCoord+of)-iResolution.xy)/iResolution.y;
        
        p *= 1.6;
        //p.y += 0.5;

        float di = float( hash(ivec2(fragCoord)*AA+ivec2(i,j))&255 )/255.0;
        float time = stime + ((float(j*AA+i)+di)/float(AA*AA))*(0.5/30.0) - 0.5*0.5/30.0;
        
        time += 0.07*sin( p.y );
        
        float wing = (p.x<0.0)?position_bad(time, 2.0):
                               position_good(time, 2.0);
        
        if( p.x>0.0 ) p.x=p.x-1.4;
        else          p.x=p.x+1.4;

       
        float an = 1.55*(0.5-0.5*cos(2.0*6.283185*wing));
        vec2  pl = vec2(sign(p.x)*sin(an),-cos(an));

        vec3 ro = vec3(0.0,0.085,2.1);
        vec3 rd = vec3(p,-3.0);
        vec3 pos = ro - rd*dot(ro.xz,pl)/dot(rd.xz,pl);
        vec2 q = vec2( length(pos.xz), pos.y );

        vec4 tmp = butterfly( q );
        tmp = clamp(tmp,0.0,1.0);
        tmp.xyz *= 0.1+0.9*mix(1.0,abs(q.y)*0.5+min(q.x*2.0,1.0),pl.x*pl.x);
        tmp.xyz *= clamp(0.25+0.75*(pl.x-pl.y+1.0),0.0,1.0);
        
        
        col += mix( vec3(0.5), tmp.xyz, tmp.w );
    }
    col /= float(AA*AA);

    vec2 q = fragCoord/iResolution.xy;
    col += sin(fragCoord.x*114.0)*sin(fragCoord.y*211.1)/512.0;
    
    fragColor = vec4(col,1.0);
}