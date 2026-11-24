#pragma once
#include "wire_layout.hpp"
#include "../coherent_frame_reader.hpp"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <cmath>
#include <ctime>
#include <vector>
struct SharedBridge {
 bool originProvisional=false;bool livePoseObserved=false; unsigned originSamples=0; XrPosef originPrevious{}; bool originReady=false; float originYaw=0, originX=0, originY=0, originZ=0;
 uint8_t* map=nullptr; wire::DoubleBufferHeader* header=nullptr; uint32_t sequence=0;
 wire::SharedFrame frame{}; wire::FrameProjection projection{}; std::vector<uint8_t> pixels, scratch;
 bool open(){const char* path=getenv("VERANTYX_SHARED_FRAME");if(!path)return false;int fd=::open(path,O_RDWR|O_CREAT,0644);if(fd<0)return false;struct stat st{};if(fstat(fd,&st)||((size_t)st.st_size<wire::kSharedMapSize&&ftruncate(fd,wire::kSharedMapSize))){close(fd);return false;}void* p=mmap(nullptr,wire::kSharedMapSize,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);close(fd);if(p==MAP_FAILED)return false;map=(uint8_t*)p;header=(wire::DoubleBufferHeader*)p;__atomic_store_n(&header->captureSourceMode,0,__ATOMIC_RELEASE);return true;}
 ~SharedBridge(){if(map)munmap(map,wire::kSharedMapSize);}
 static void matrix(const XrPosef& p,float* m){auto q=p.orientation;float x=q.x,y=q.y,z=q.z,w=q.w;memset(m,0,64);m[0]=1-2*(y*y+z*z);m[1]=2*(x*y+z*w);m[2]=2*(x*z-y*w);m[4]=2*(x*y-z*w);m[5]=1-2*(x*x+z*z);m[6]=2*(y*z+x*w);m[8]=2*(x*z+y*w);m[9]=2*(y*z-x*w);m[10]=1-2*(x*x+y*y);m[12]=p.position.x;m[13]=p.position.y;m[14]=p.position.z;m[15]=1;}
 void tracking(const XrView* v,bool valid,const wire::SharedHands& controls){wire::SharedHands hands=controls;XrPosef head=v[0].pose;head.position={(v[0].pose.position.x+v[1].pose.position.x)/2,(v[0].pose.position.y+v[1].pose.position.y)/2,(v[0].pose.position.z+v[1].pose.position.z)/2};matrix(head,hands.headTransform);
 const float dist=head.position.x*head.position.x+head.position.y*head.position.y+head.position.z*head.position.z;
 const auto orientation=head.orientation;
 const bool live=std::isfinite(dist)&&(dist>0.000001f||orientation.x*orientation.x+orientation.y*orientation.y+orientation.z*orientation.z>0.0001f);
 if(valid&&(!originReady||(originProvisional&&live))){
  // A neutral but valid runtime pose must not block game startup. Rebase once
  // when live tracking arrives, preserving the default camera/menu location.
  originYaw=atan2f(hands.headTransform[8],hands.headTransform[10]);
  originX=head.position.x;originY=head.position.y-1.6f;originZ=head.position.z;
  originReady=true;originProvisional=!live;originSamples=1;
  printf("Tracking origin: %s, game head height 1.6m\n",originProvisional?"provisional":"live");
 }
 if(originReady){float c=cosf(originYaw),s=sinf(originYaw);for(int col=0;col<3;col++){float x=hands.headTransform[col*4],z=hands.headTransform[col*4+2];hands.headTransform[col*4]=c*x-s*z;hands.headTransform[col*4+2]=s*x+c*z;}float x=head.position.x-originX,z=head.position.z-originZ;hands.headTransform[12]=c*x-s*z;hands.headTransform[13]=head.position.y-originY;hands.headTransform[14]=s*x+c*z;}
 if(originReady){float c=cosf(originYaw),s=sinf(originYaw);for(int h=0;h<2;h++){float* m=h?hands.rightTransform:hands.leftTransform;bool tracked=h?hands.rightTracked:hands.leftTracked;if(!tracked)continue;for(int col=0;col<3;col++){float x=m[col*4],z=m[col*4+2];m[col*4]=c*x-s*z;m[col*4+2]=s*x+c*z;}float x=m[12]-originX,z=m[14]-originZ;m[12]=c*x-s*z;m[13]-=originY;m[14]=s*x+c*z;for(float* velocity:{h?hands.rightVelocity:hands.leftVelocity,h?hands.rightAngularVelocity:hands.leftAngularVelocity}){float x=velocity[0],z=velocity[2];velocity[0]=c*x-s*z;velocity[2]=s*x+c*z;}}}
 hands.headTracked=valid;struct timespec ts{};clock_gettime(CLOCK_MONOTONIC,&ts);hands.visionTimestamp=ts.tv_sec+ts.tv_nsec*1e-9;for(int e=0;e<2;e++){float* t=e?hands.rightTangents:hands.leftTangents;t[0]=tan(v[e].fov.angleLeft);t[1]=tan(v[e].fov.angleRight);t[2]=tan(v[e].fov.angleDown);t[3]=tan(v[e].fov.angleUp);}int32_t seq=__atomic_load_n(&header->poseSequence,__ATOMIC_RELAXED);seq=(seq+1)|1;__atomic_store_n(&header->poseSequence,seq,__ATOMIC_RELEASE);memcpy(map+wire::kHandsOffset,&hands,sizeof(hands));__atomic_store_n(&header->poseSequence,seq+1,__ATOMIC_RELEASE);}
 bool read(){
  struct Access {
   SharedBridge& bridge;
   uint32_t mode()const{return uint32_t(__atomic_load_n(&bridge.header->captureSourceMode,__ATOMIC_ACQUIRE));}
   uint32_t latest()const{return uint32_t(__atomic_load_n(&bridge.header->latestReadyIndex,__ATOMIC_ACQUIRE));}
   wire::SharedFrame* frame(unsigned slot)const{return reinterpret_cast<wire::SharedFrame*>(bridge.map+sizeof(wire::DoubleBufferHeader)+wire::kFrameBlockSize*slot);}
   uint32_t sequence(unsigned slot)const{return __atomic_load_n(&frame(slot)->sequenceNumber,__ATOMIC_ACQUIRE);}
   void copyFrame(unsigned slot,wire::SharedFrame& out)const{memcpy(&out,frame(slot),sizeof(out));}
   void copyPixels(unsigned slot,uint8_t* out,size_t size)const{memcpy(out,reinterpret_cast<uint8_t*>(frame(slot))+sizeof(wire::SharedFrame),size);}
   void copyProjection(unsigned slot,wire::FrameProjection& out)const{memcpy(&out,bridge.map+wire::kProjectionOffset+slot*sizeof(out),sizeof(out));}
   void acquireFence()const{__atomic_thread_fence(__ATOMIC_ACQUIRE);}
  } access{*this};
  const bool accepted=halliday::alyx::readCoherentFrame(access,sequence,frame,projection,pixels,scratch,wire::kMaxPixelBytes);
  if(accepted)sequence=frame.sequenceNumber;
  return accepted;
 }
 XrPosef renderPose(int eye,float ipd)const{float world[16];memcpy(world,frame.renderHeadTransform,sizeof(world));
 if(originReady){float c=cosf(originYaw),s=sinf(originYaw);for(int col=0;col<4;col++){float x=world[col*4],z=world[col*4+2];world[col*4]=c*x+s*z;world[col*4+2]=-s*x+c*z;}world[12]+=originX;world[13]+=originY;world[14]+=originZ;}
 const float* m=world;XrPosef p{};p.orientation.w=sqrtf(fmaxf(0,1+m[0]+m[5]+m[10]))/2;p.orientation.x=copysignf(sqrtf(fmaxf(0,1+m[0]-m[5]-m[10]))/2,m[6]-m[9]);p.orientation.y=copysignf(sqrtf(fmaxf(0,1-m[0]+m[5]-m[10]))/2,m[8]-m[2]);p.orientation.z=copysignf(sqrtf(fmaxf(0,1-m[0]-m[5]+m[10]))/2,m[1]-m[4]);float side=(eye?1.f:-1.f)*ipd/2;p.position={m[12]+m[0]*side,m[13]+m[1]*side,m[14]+m[2]*side};return p;}
};
