module gc.impl.conservative.freelist;

enum
{
    B_16,
    B_32,
    B_64,
    B_128,
    B_256,
    B_512,
    B_1024,
    B_2048,
    B_PAGE,             // start of large alloc
    B_PAGEPLUS,         // continuation of large alloc
    B_FREE,             // free page
    B_MAX
}

alias ubyte Bins;

struct List(Pool)
{
    List *next;
    Pool *pool;
}

immutable uint[B_MAX] binsize = [ 16,32,64,128,256,512,1024,2048,4096 ];
immutable size_t[B_MAX] notbinsize = [ ~(16-1),~(32-1),~(64-1),~(128-1),~(256-1),
                                ~(512-1),~(1024-1),~(2048-1),~(4096-1) ];
