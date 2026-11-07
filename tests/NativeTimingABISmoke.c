// Small ABI / unavailable-data check. No model/GPU initialization or benchmark.
#include <assert.h>
#include <stdio.h>
#include "../native/FSRCNNXMetal/include/IIVEFSR.h"
#include "../native/RIFEBackend/include/IIVERIFE.h"

static void check(int32_t (*read_timing)(void *, double *, double *))
{
    double gpu = 123, wait = 456;
    assert(read_timing(NULL, &gpu, &wait) == 0);
    assert(gpu == -1 && wait == -1);
    assert(read_timing(NULL, NULL, &wait) == 0);
    assert(read_timing(NULL, &gpu, NULL) == 0);
}
int main(void)
{
    check(iive_fsr_timing);
    check(iive_stream_timing);
    assert(iive_stream_compilation_cache_hit(NULL)==-1);
    double preparation[6]={17,17,17,17,17,99};
    assert(iive_stream_preparation_timing(NULL,preparation,4)==0);
    for(int i=0;i<5;i++)assert(preparation[i]==17);
    assert(iive_stream_preparation_timing(NULL,preparation,6)==0);
    for(int i=0;i<5;i++)assert(preparation[i]==-1);
    assert(preparation[5]==99);
    assert(iive_stream_preparation_timing(NULL,NULL,5)==0);
    puts("PASS native timing symbols and unavailable-data contract (no GPU run)");
}
