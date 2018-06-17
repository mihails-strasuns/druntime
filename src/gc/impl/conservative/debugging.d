/**
 * Various debugging utilities that are not used when
 * none of `-debug` flags are supplied.
 *
 * Copyright: D Language Foundation 2018
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 */
module gc.impl.conservative.debugging;

/* ============================ SENTINEL =============================== */

debug (SENTINEL)
{
    import gc.gcassert;

    private extern(C) void onInvalidMemoryOperationError() @nogc nothrow;

    const size_t SENTINEL_PRE = cast(size_t) 0xF4F4F4F4F4F4F4F4UL; // 32 or 64 bits
    const ubyte SENTINEL_POST = 0xF5;           // 8 bits
    const uint SENTINEL_EXTRA = 2 * size_t.sizeof + 1;


    inout(size_t*) sentinel_size(inout void *p) nothrow { return &(cast(inout size_t *)p)[-2]; }
    inout(size_t*) sentinel_pre(inout void *p)  nothrow { return &(cast(inout size_t *)p)[-1]; }
    inout(ubyte*) sentinel_post(inout void *p)  nothrow { return &(cast(inout ubyte *)p)[*sentinel_size(p)]; }


    void sentinel_init(void *p, size_t size) nothrow
    {
        *sentinel_size(p) = size;
        *sentinel_pre(p) = SENTINEL_PRE;
        *sentinel_post(p) = SENTINEL_POST;
    }


    void sentinel_Invariant(const void *p) nothrow @nogc
    {
        debug
        {
            gcassert(*sentinel_pre(p) == SENTINEL_PRE);
            gcassert(*sentinel_post(p) == SENTINEL_POST);
        }
        else if(*sentinel_pre(p) != SENTINEL_PRE || *sentinel_post(p) != SENTINEL_POST)
            onInvalidMemoryOperationError(); // also trigger in release build
    }


    void *sentinel_add(void *p) nothrow @nogc
    {
        return p + 2 * size_t.sizeof;
    }


    void *sentinel_sub(void *p) nothrow @nogc
    {
        return p - 2 * size_t.sizeof;
    }
}
else
{
    const uint SENTINEL_EXTRA = 0;


    void sentinel_init(void *p, size_t size) nothrow
    {
    }


    void sentinel_Invariant(const void *p) nothrow @nogc
    {
    }


    void *sentinel_add(void *p) nothrow @nogc
    {
        return p;
    }


    void *sentinel_sub(void *p) nothrow @nogc
    {
        return p;
    }
}

/* ======================= Leak Detector =========================== */

debug (LOGGING)
{
    private {
        import core.stdc.stdio : printf;
        import core.stdc.stdlib : free, malloc;
        import core.stdc.string : memcpy, memmove;

        extern(C) void onOutOfMemoryErrorNoGC() @nogc nothrow;
    }

    struct Log
    {
        void*  p;
        size_t size;
        size_t line;
        char*  file;
        void*  parent;

        void print() nothrow
        {
            printf("    p = %p, size = %zd, parent = %p ", p, size, parent);
            if (file)
            {
                printf("%s(%u)", file, line);
            }
            printf("\n");
        }
    }


    struct LogArray
    {
        size_t dim;
        size_t allocdim;
        Log *data;

        void Dtor() nothrow
        {
            if (data)
                free(data);
            data = null;
        }

        void reserve(size_t nentries) nothrow
        {
            gcassert(dim <= allocdim);
            if (allocdim - dim < nentries)
            {
                allocdim = (dim + nentries) * 2;
                gcassert(dim + nentries <= allocdim);
                if (!data)
                {
                    data = cast(Log*)malloc(allocdim * Log.sizeof);
                    if (!data && allocdim)
                        onOutOfMemoryErrorNoGC();
                }
                else
                {   Log *newdata;

                    newdata = cast(Log*)malloc(allocdim * Log.sizeof);
                    if (!newdata && allocdim)
                        onOutOfMemoryErrorNoGC();
                    memcpy(newdata, data, dim * Log.sizeof);
                    free(data);
                    data = newdata;
                }
            }
        }


        void push(Log log) nothrow
        {
            reserve(1);
            data[dim++] = log;
        }

        void remove(size_t i) nothrow
        {
            memmove(data + i, data + i + 1, (dim - i) * Log.sizeof);
            dim--;
        }


        size_t find(void *p) nothrow
        {
            for (size_t i = 0; i < dim; i++)
            {
                if (data[i].p == p)
                    return i;
            }
            return size_t.max; // not found
        }


        void copy(LogArray *from) nothrow
        {
            reserve(from.dim - dim);
            gcassert(from.dim <= allocdim);
            memcpy(data, from.data, from.dim * Log.sizeof);
            dim = from.dim;
        }
    }
}
