/**
 * For allocating small objects GC interprets some of pages
 * as free lists of bin-size chunks. This module provides
 * a pool of such pages.
 *
 * Copyright: D Language Foundation 2018
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 */
module gc.impl.conservative.freelist;

import gc.impl.conservative.pool;
import gc.impl.conservative.debugging;
import gc.gcassert;
import gc.gcinterface : BlkInfo, BlkAttr;
import gc.impl.conservative.stats;

immutable uint[B_MAX] binsize = [ 16,32,64,128,256,512,1024,2048,4096 ];
immutable size_t[B_MAX] notbinsize = [ ~(16-1),~(32-1),~(64-1),~(128-1),~(256-1),
                                ~(512-1),~(1024-1),~(2048-1),~(4096-1) ];
struct Buckets
{
    private FreeList[B_PAGE] lists;

    /**
     * Computes the bin table using CTFE.
     */
    private static byte[2049] ctfeBins()
    {
        byte[2049] ret;
        size_t p = 0;
        for (Bins b = B_16; b <= B_2048; b++)
            for ( ; p <= binsize[b]; p++)
                ret[p] = b;

        return ret;
    }

    private static immutable byte[2049] binTable = ctfeBins();

    nothrow:

    FreeList opIndex(size_t idx) @nogc
    {
        return this.lists[idx];
    }

    void* alloc(size_t requested_size, ref size_t allocated_size,
        scope SmallObjectPool* delegate() nothrow more_memory, uint bits)
    {
        auto bin = binTable[requested_size];
        allocated_size = binsize[bin];

        if (!lists[bin].head)
        {
            auto pool = more_memory();
            gcassert(pool !is null);
            lists[bin].initialize(pool, allocated_size, bin);
        }

        FreeNode* item = lists[bin].alloc();
        auto pool = item.host;
        gcassert(!pool.isLargeObject);

        void* p = item;
        if (bits)
            pool.setBits((p - pool.baseAddr) >> pool.shiftBy, bits);
        debug (MEMSTOMP) memset(p, 0xF0, alloc_size);

        return p;
    }
}

struct FreeList
{
    FreeNode* head;

    void free(FreeNode* item) @nogc nothrow
    {
        gcassert(item !is null);
        gcassert(item.host !is null);

        item.next = head;
        head = item;
    }

    FreeNode* alloc() @nogc nothrow
    {
        gcassert(head !is null);
        gcassert(head.host !is null);

        auto p = head;
        head = head.next;
        return p;
    }

    /**
     * Params:
     *  pool = pointer to the pool which to allocate new page from
     *  size = size of an individual bin
     */
    void initialize(SmallObjectPool* pool, size_t size, Bins bin) nothrow
    {
        gcassert(pool !is null);

        void* page = pool.allocPage(bin);
        gcassert(page !is null);

        void* p = page;
        void* p_end = page + PAGESIZE - size;

        for (; p < p_end; p += size)
        {
            auto item = cast(FreeNode*) p;
            item.next = cast(FreeNode*) (p + size);
            item.host = pool;
        }

        auto item = cast(FreeNode*) p;
        item.next = null;
        item.host = pool;

        this.head = cast(FreeNode*) page;
    }

    struct Range
    {
        FreeNode* current;

        nothrow @nogc:

        this(FreeList list)
        {
            current = list.head;
        }

        bool empty()
        {
            return current is null;
        }

        void popFront()
        {
            current = current.next;
        }

        FreeNode* front()
        {
            return current;
        }
    }

    Range range ( ) nothrow @nogc
    {
        return Range(this);
    }
}

/**
 * Free list implementation for a small object pool.
 * Wraps a pointer to the begging of an individual bin.
 *
 * This actual struct can be both list head and nodes depending on the
 * context.
 */
struct FreeNode
{
    /// Pointer to the next list node, `null` for tail node
    FreeNode* next;
    /// Pointer to the pool which allocated this list page
    SmallObjectPool* host;

    /// See `from`
    @disable this();
    /// See `from`
    @disable this(this);
}

private extern(C)
{
    int rt_hasFinalizerInSegment(void* p, size_t size, uint attr, in void[] segment) nothrow;
    void rt_finalizeFromGC(void* p, size_t size, uint attr) nothrow;
}

struct SmallObjectPool
{
    Pool base;
    alias base this;

    /**
    * Get size of pointer p in pool.
    */
    size_t getSize(void *p) const nothrow @nogc
    in
    {
        gcassert(p >= baseAddr);
        gcassert(p < topAddr);
    }
    do
    {
        size_t pagenum = pagenumOf(p);
        Bins bin = cast(Bins)pagetable[pagenum];
        gcassert(bin < B_PAGE);
        return binsize[bin];
    }

    BlkInfo getInfo(void* p) nothrow
    {
        BlkInfo info;
        size_t offset = cast(size_t)(p - baseAddr);
        size_t pn = offset / PAGESIZE;
        Bins   bin = cast(Bins)pagetable[pn];

        if (bin >= B_PAGE)
            return info;

        info.base = cast(void*)((cast(size_t)p) & notbinsize[bin]);
        info.size = binsize[bin];
        offset = info.base - baseAddr;
        info.attr = getBits(cast(size_t)(offset >> ShiftBy.Small));

        return info;
    }

    void runFinalizers(in void[] segment) nothrow
    {
        foreach (pn; 0 .. npages)
        {
            Bins bin = cast(Bins)pagetable[pn];
            if (bin >= B_PAGE)
                continue;

            immutable size = binsize[bin];
            auto p = baseAddr + pn * PAGESIZE;
            const ptop = p + PAGESIZE;
            immutable base = pn * (PAGESIZE/16);
            immutable bitstride = size / 16;

            bool freeBits;
            PageBits toFree;

            for (size_t i; p < ptop; p += size, i += bitstride)
            {
                immutable biti = base + i;

                if (!finals.test(biti))
                    continue;

                auto q = sentinel_add(p);
                uint attr = getBits(biti);

                if(!rt_hasFinalizerInSegment(q, size, attr, segment))
                    continue;

                rt_finalizeFromGC(q, size, attr);

                freeBits = true;
                toFree.set(i);

                debug(COLLECT_PRINTF) printf("\tcollecting %p\n", p);
                //log_free(sentinel_add(p));

                debug (MEMSTOMP) memset(p, 0xF3, size);
            }

            if (freeBits)
                freePageBits(pn, toFree);
        }
    }

    /**
     * Allocate a single page.
     *
     * Returns:
     *   pointer to the beginning of the page, null on failure
     */
    void* allocPage(Bins bin) nothrow
    {
        size_t pn;
        for (pn = searchStart; pn < npages; pn++)
        {
            if (pagetable[pn] == B_FREE)
            {
                this.searchStart = pn + 1;
                freepages--;
                pagetable[pn] = cast(ubyte) bin;
                ++usedSmallPages;
                return baseAddr + pn * PAGESIZE;
            }
        }

        return null;
    }
}
