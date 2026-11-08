#import <Foundation/Foundation.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <string.h>
#include "ThinRuntime.h"
#include "RuntimeLog.h"
static _Atomic(VMMThinLogSink) sink;
static _Atomic(void *) sinkContext;
typedef struct { _Atomic bool ready;char kind[40];uint32_t opcode,stamp,slot;size_t bytes; } Diagnostic;
static Diagnostic events[64];static _Atomic unsigned count;
void VMMThinRuntimeSetLogSink(VMMThinLogSink callback,void *context){atomic_store(&sinkContext,context);atomic_store(&sink,callback);}
static int emit(const char *format,va_list args){
    char message[2048];int length=vsnprintf(message,sizeof(message),format,args);
    VMMThinLogSink callback=atomic_load(&sink);
    if(callback)callback(message,atomic_load(&sinkContext));else fputs(message,stderr);
    return length;
}
int VMMThinRuntimePrint(const char *format,...){va_list args;va_start(args,format);int n=emit(format,args);va_end(args);return n;}
int VMMThinRuntimeFPrint(FILE *stream,const char *format,...){(void)stream;va_list args;va_start(args,format);int n=emit(format,args);va_end(args);return n;}
void VMMThinRuntimeRecord(const char *kind,uint32_t opcode,uint32_t stamp,size_t bytes,uint32_t slot){
    unsigned index=atomic_fetch_add(&count,1);
    if(index<64){Diagnostic *e=&events[index];snprintf(e->kind,sizeof(e->kind),"%s",kind);e->opcode=opcode;e->stamp=stamp;e->bytes=bytes;e->slot=slot;atomic_store_explicit(&e->ready,true,memory_order_release);}
    if(index<64)VMMThinRuntimePrint("runtime-diagnostic kind=%s opcode=%u stamp=%u bytes=%zu slot=%u\n",kind,opcode,stamp,bytes,slot);
}
NSArray *VMMThinRuntimeDiagnostics(void){
    NSMutableArray *result=[NSMutableArray new];unsigned n=atomic_load(&count);
    for(unsigned i=0;i<MIN(n,64u);i++)if(atomic_load_explicit(&events[i].ready,memory_order_acquire)){
        Diagnostic *e=&events[i];[result addObject:@{@"kind":@(e->kind),@"opcode":@(e->opcode),@"stamp":@(e->stamp),@"bytes":@(e->bytes),@"slot":@(e->slot)}];
    }
    if(n>64)[result addObject:@{@"dropped":@(n-64)}];return result;
}
