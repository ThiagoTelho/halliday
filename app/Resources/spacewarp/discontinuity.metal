// Copyright (c) 2026 Halliday contributors. MIT.
// Pair validity only. Optical flow and accepted colour composition are unchanged.
#include <metal_stdlib>
using namespace metal;
struct GuardConstants { uint4 dimensions, grid; float4 scaleResidualMotion, coverage; };
constexpr sampler guard_linear(coord::pixel,address::clamp_to_edge,filter::linear);
float2 guard_flow(texture2d<float,access::read> flow,float2 p,uint eye,constant GuardConstants& u) {
 float2 g=p/(u.scaleResidualMotion.xy*float(u.grid.w))-0.5;
 int2 lo=int2(floor(g));float2 f=fract(g);float2 v[4];
 for(uint i=0;i<4;i++){int2 q=clamp(lo+int2(i&1u,i>>1u),int2(0),int2(u.grid.xy)-1);v[i]=flow.read(uint2(q.x+eye*u.grid.x,q.y)).xy*u.scaleResidualMotion.xy;}
 return mix(mix(v[0],v[1],f.x),mix(v[2],v[3],f.x),f.y);
}
kernel void spacewarp_guard_tiles(texture2d<float,access::read> current [[texture(0)]],
 texture2d<float,access::sample> aligned [[texture(1)]], texture2d<float,access::read> flow [[texture(2)]],
 texture2d<uint,access::write> stats [[texture(3)]],texture2d<float,access::read> rawPrevious [[texture(4)]],constant GuardConstants& u [[buffer(0)]],
 device atomic_uint* changed [[buffer(1)]],uint2 p [[thread_position_in_grid]]) {
 if(any(p>=uint2(stats.get_width(),stats.get_height())))return;
 uint columns=(u.dimensions.z+15u)/16u,rows=(u.dimensions.y+15u)/16u,eye=p.x/columns;
 uint2 tile(p.x%columns,p.y);uint bad=0,large=0,rawChanged=0;
 for(uint k=0;k<4;k++) {
  float2 at=min(float2(tile*16u+uint2(4u+8u*(k&1u),4u+8u*(k>>1u)))+0.5,float2(u.dimensions.zy)-0.5);
  float2 v=guard_flow(flow,at,eye,u),old=at-v;
  bool valid=all(isfinite(v))&&all(old>=0.5)&&old.x<=float(u.dimensions.z)-0.5&&old.y<=float(u.dimensions.y)-0.5;
  float4 prior=valid?aligned.sample(guard_linear,float2(eye*u.dimensions.z,0)+old):float4(0);
  float3 now=current.read(uint2(eye*u.dimensions.z+uint(at.x),uint(at.y))).rgb;
  float residual=max(abs(prior.r-now.r),max(abs(prior.g-now.g),abs(prior.b-now.b)));
  float3 raw=rawPrevious.read(uint2(eye*u.dimensions.z+uint(at.x),uint(at.y))).rgb;
  rawChanged+=any(abs(raw-now)>float3(2.0/255.0+1e-6))?1u:0u;
  bad+=(!valid||prior.a<0.99||residual>u.scaleResidualMotion.z)?1u:0u;
  large+=(valid&&length(v/float2(u.dimensions.zy))>u.scaleResidualMotion.w)?1u:0u;
 }
 uint index=2u+eye*columns*rows+tile.y*columns+tile.x;
 bool didChange=rawChanged>=3u;
 uint bits=(bad>=3u?1u:0u)|(large>=3u&&didChange?2u:0u)|(didChange?4u:0u)|(bad>=3u&&didChange?8u:0u);
 // Raw source-change eligibility is read only. No tiled composition mask is written.
 stats.write(uint4(bits),p);
}
kernel void spacewarp_guard_reduce(texture2d<uint,access::read> stats [[texture(0)]],
 texture2d<uint,access::read> amd [[texture(1)]],texture2d<uint,access::write> cuts [[texture(2)]],
 constant GuardConstants& u [[buffer(0)]],uint3 group [[threadgroup_position_in_grid]],
 uint lane [[thread_index_in_threadgroup]]) {
 threadgroup uint bad[256],large[256],change[256],zones[256],newBad[256];
 uint columns=stats.get_width()/2u,rows=stats.get_height(),count=columns*rows,eye=group.x;
 uint b=0,l=0,c=0,z=0,n=0;
 for(uint i=lane;i<count;i+=256u) {uint2 p(i%columns,i/columns);uint bits=stats.read(uint2(p.x+eye*columns,p.y)).x;
 b+=(bits&1u)!=0;l+=(bits&2u)!=0;c+=(bits&4u)!=0;n+=(bits&8u)!=0;
 if((bits&3u)!=0)z|=1u<<(min(2u,p.x*3u/columns)+3u*min(2u,p.y*3u/rows));}
 bad[lane]=b;large[lane]=l;change[lane]=c;zones[lane]=z;newBad[lane]=n;threadgroup_barrier(mem_flags::mem_threadgroup);
 for(uint s=128u;s>0;s>>=1u){if(lane<s){bad[lane]+=bad[lane+s];large[lane]+=large[lane+s];change[lane]+=change[lane+s];zones[lane]|=zones[lane+s];newBad[lane]+=newBad[lane+s];}threadgroup_barrier(mem_flags::mem_threadgroup);}
 if(lane==0){bool broad=popcount(zones[0])>=6u&&float(change[0])>=u.coverage.z*count;
 uint flag=amd.read(uint2(eye,0)).x!=0?1u:0u;
 if(broad&&float(bad[0])>=u.coverage.x*count)flag|=2u;
 if(broad&&float(large[0])>=u.coverage.y*count)flag|=4u;
 if(popcount(zones[0])>=2u&&float(newBad[0])>=0.10*count&&float(newBad[0])>=0.75*change[0])flag|=8u;
 cuts.write(uint4(flag),uint2(eye,0));}
}
// Stereo is one temporal pair. A cut in either view suppresses BOTH views;
// never show a real left eye beside an extrapolated right eye.
kernel void spacewarp_guard_pair(texture2d<uint,access::read> eyes [[texture(0)]],
 texture2d<uint,access::write> paired [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
 if(any(p!=uint2(0)))return;
 uint flag=eyes.read(uint2(0,0)).x|eyes.read(uint2(1,0)).x;
 paired.write(uint4(flag),uint2(0,0));paired.write(uint4(flag),uint2(1,0));
}
