module gc.impl.conservative.freelist;

import gc.impl.conservative.pool;
import gc.impl.conservative.debugging;
import gc.gcassert;
import gc.gcinterface : BlkInfo, BlkAttr;

immutable uint[B_MAX] binsize = [ 16,32,64,128,256,512,1024,2048,4096 ];
immutable size_t[B_MAX] notbinsize = [ ~(16-1),~(32-1),~(64-1),~(128-1),~(256-1),
                                ~(512-1),~(1024-1),~(2048-1),~(4096-1) ];

struct FreeList
{
    FreeList* next;
    Pool* host;

    @disable this();

    static FreeList* from(Pool* pool, void* page, size_t size) nothrow
    {
        void* p = page;
        void* p_end = page + PAGESIZE - size;

        for (; p < p_end; p += size)
        {
            auto item = cast(FreeList*) p;
            item.next = cast(FreeList*) (p + size);
            item.host = pool;
        }

        auto item = cast(FreeList*) p;
        item.next = null;
        item.host = pool;

        auto head = cast(FreeList*) page;
        return head;
    }

    struct Range
    {
        FreeList* current;

        nothrow @nogc:

        this(FreeList* list)
        {
            current = list;
        }

        bool empty()
        {
            return current is null;
        }

        void popFront()
        {
            current = current.next;
        }

        FreeList* front()
        {
            return current;
        }
    }

    Range range ( ) nothrow @nogc
    {
        return Range(&this);
    }
}

void add(ref FreeList* head, FreeList* item) @nogc nothrow
{
    item.next = head;
    head = item;
}

FreeList* take(ref FreeList* head) @nogc nothrow
{
    auto p = head;
    head = head.next;
    return p;
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
    * Allocate a page of bin's.
    * Returns:
    *           head of a single linked list of new entries
    */
    FreeList* allocPage(Bins bin) nothrow
    {
        size_t pn;
        for (pn = searchStart; pn < npages; pn++)
            if (pagetable[pn] == B_FREE)
                goto L1;

        return null;

    L1:
        searchStart = pn + 1;
        pagetable[pn] = cast(ubyte)bin;
        freepages--;
        size_t size = binsize[bin];
        return FreeList.from(&base, baseAddr + pn * PAGESIZE, size);
    }
}
