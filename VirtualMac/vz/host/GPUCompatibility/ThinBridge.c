#include "ThinBridge.h"
#include <string.h>

static uint16_t u16(const uint8_t *p) {uint16_t v;memcpy(&v,p,2);return v;}
static uint32_t u32(const uint8_t *p) {uint32_t v;memcpy(&v,p,4);return v;}
static uint64_t u64(const uint8_t *p) {uint64_t v;memcpy(&v,p,8);return v;}
static void put32(uint8_t *p,uint32_t v) {memcpy(p,&v,4);}
static bool fail(const char **error,const char *message) {*error=message;return false;}

bool ThinDecodeObjectLists68(const void *input,size_t length,ThinObjectLists68 *result){
    if(!input||!result||length!=28)return false;
    const uint8_t *p=input;
    *result=(ThinObjectLists68){.task=u32(p),.objectBytes=u32(p+20),
        .placementBytes=u32(p+24),.objectOffset=u64(p+4),.placementOffset=u64(p+12)};
    return true;
}

bool ThinLocalObjectLists68To51(const void *input,size_t length,uint64_t taskBytes,
                              uint8_t output[12],const char **error){
    if(!output||!error)return false;*error=NULL;ThinObjectLists68 p;
    if(!ThinDecodeObjectLists68(input,length,&p))return fail(error,"expected exact28-byte object/placement metadata");
    if(p.objectBytes%12)return fail(error,"partial12-byte object entry");
    if((p.objectOffset&0x3fff)||(p.objectOffset>>14)>UINT32_MAX)
        return fail(error,"object byte offset not representable by old51 page");
    if(p.objectOffset>=taskBytes||p.objectBytes>=taskBytes-p.objectOffset)
        return fail(error,"object table outside task range");
    if(p.placementOffset>=taskBytes||p.placementBytes>=taskBytes-p.placementOffset)
        return fail(error,"placement table outside task range");
    uint64_t required=(uint64_t)(p.objectBytes/12)*16;
    if(p.placementOffset&&p.placementBytes<required)
        return fail(error,"placement table shorter than object count requires");
    // Native27 PGLocalTask intentionally ignores placement after these range
    // checks. This is NOT a remote/service placement implementation or a NOP:
    // original wire51 sets the actual object table and signals completion.
    put32(output,p.task);put32(output+4,(uint32_t)(p.objectOffset>>14));put32(output+8,p.objectBytes);
    return true;
}

bool ThinTexture52To1(const void *input,size_t length,uint8_t output[44],
                     ThinTextureExtras *extras,const char **error) {
    if(!input||!output||!extras||!error) return false;
    *error=NULL;
    const uint8_t *p=input;
    if(length!=52||u32(p)!=52||u32(p+4)!=52)
        return fail(error,"expected exact 52-byte operation 52");
    const uint8_t *d=p+12;
    uint32_t usage=u32(d+3);
    // Restrict this spike to the two known high bits; never truncate unknowns.
    if(usage&~UINT32_C(0x140ff)) return fail(error,"unexamined high usage bit");
    for(unsigned i=0;i<4;i++)
        if(d[35+i]>5) return fail(error,"unexamined swizzle channel");
    memset(output,0,44);
    put32(output,1);put32(output+4,44);memcpy(output+8,p+8,4);
    uint8_t *old=output+12;
    put32(old,(d[0]&0x7f)|((usage&0xff)<<8)|((uint32_t)u16(d+1)<<16));
    memcpy(old+4,d+7,12);       // dimensions
    memcpy(old+16,d+19,8);      // levels, samples, array length, options
    memcpy(old+24,d+27,8);      // protection options
    *extras=(ThinTextureExtras){.usage=usage,.writeSwizzle=(d[0]>>7)&1};
    memcpy(extras->swizzle,d+35,4);
    return true;
}

bool ThinExec3To2(const void *input,size_t length,void *output,size_t capacity,
                 size_t *written,const char **error) {
    if(!input||!output||!written||!error) return false;
    *error=NULL;*written=0;
    if(length<12||length>65536) return fail(error,"payload outside bounded spike");
    const uint8_t *p=input;
    uint8_t *q=output;
    uint32_t task=u32(p),resources=u32(p+4),buffers=u32(p+8);
    uint64_t inSize=12+(uint64_t)resources*8+(uint64_t)buffers*16;
    uint64_t outSize=12+(uint64_t)resources*24+(uint64_t)buffers*16;
    if(!task||inSize!=length||outSize>capacity)
        return fail(error,"task/count/length/capacity mismatch");
    // Exact27.2 producers leave high bits/bytes as padding. Native GPUTask
    // prepare/completeResources consume ONLY byte+4 bits0..2. Do not reject
    // arbitrary padding as a capability; preserve the three semantic flags.
    memset(q,0,(size_t)outSize);memcpy(q,p,12);
    for(uint32_t i=0;i<resources;i++) {
        const uint8_t *r=p+12+(size_t)i*8;
        uint8_t *s=q+12+(size_t)i*24;
        memcpy(s,r,4);
        uint32_t flags=u32(r+4);
        s[4]=flags&1;s[5]=(flags>>1)&1;s[6]=(flags>>2)&1;
    }
    memcpy(q+12+(size_t)resources*24,p+12+(size_t)resources*8,(size_t)buffers*16);
    *written=(size_t)outSize;return true;
}
