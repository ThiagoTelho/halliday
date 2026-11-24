// Inert ABI fixture: no Steam code, hardware, network, or game entry points.
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static const char *mode(void) { const char *s=getenv("HALLIDAY_FAKE_STEAM_MODE"); return s?s:"ready"; }
static void record(char letter) {
    const char *path=getenv("HALLIDAY_FAKE_STEAM_CALLS"); if(!path)return;
    FILE *f=fopen(path,"a"); if(f){fputc(letter,f);fclose(f);}
}
int Steam_CreateSteamPipe(void) {
    record('c');
    if(!strcmp(mode(),"hang")) {
        const char *path=getenv("HALLIDAY_FAKE_STEAM_PID");
        if(path){FILE*f=fopen(path,"w");if(f){fprintf(f,"%d",getpid());fclose(f);}}
        sleep(10);
    }
    if(!strcmp(mode(),"no-pipe"))return 0;
    if(!strcmp(mode(),"eventually")) {
        const char*path=getenv("HALLIDAY_FAKE_STEAM_ATTEMPTS"); int count=0;
        FILE*f=fopen(path,"r");if(f){fscanf(f,"%d",&count);fclose(f);}
        f=fopen(path,"w");if(f){fprintf(f,"%d",++count);fclose(f);}
        if(count<3)return 0;
    }
    return 41;
}
int Steam_ConnectToGlobalUser(int pipe) { record('u'); return pipe==41 && strcmp(mode(),"no-user") ? 73 : 0; }
#ifndef HALLIDAY_FAKE_MISSING_RELEASE
void Steam_ReleaseUser(int pipe,int user) { record(pipe==41 && user==73?'r':'!'); }
#endif
bool Steam_BReleaseSteamPipe(int pipe) { record(pipe==41?'p':'!');return pipe==41; }
bool Steam_BLoggedOn(int user,int pipe) { record('l');return user==73 && pipe==41 && strcmp(mode(),"offline"); }
