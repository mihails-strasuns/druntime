module gc.impl.conservative.pool;

import gc.bits;
import gc.gcinterface : BlkInfo, BlkAttr;
import gc.gcassert;
import gc.os;
import gc.impl.conservative.debugging;
import core.bitop;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : memset;

private extern(C){
    void onOutOfMemoryErrorNoGC() @nogc nothrow;
    void rt_finalizeFromGC(void* p, size_t size, uint attr) nothrow;
    int rt_hasFinalizerInSegment(void* p, size_t size, uint attr, in void[] segment) nothrow;
}

enum
{
    PAGESIZE =    4096,
    POOLSIZE =   (4096*256),
}

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

alias PageBits = GCBits.wordtype[PAGESIZE / 16 / GCBits.BITS_PER_WORD];
static assert(PAGESIZE % (GCBits.BITS_PER_WORD * 16) == 0);

void set(ref PageBits bits, size_t i) @nogc pure nothrow
{
    gcassert(i < PageBits.sizeof * 8);
    bts(bits.ptr, i);
}

struct Pool
{
    void* baseAddr;
    void* topAddr;
    GCBits mark;        // entries already scanned, or should not be scanned
    GCBits freebits;    // entries that are on the free list
    GCBits finals;      // entries that need finalizer run on them
    GCBits structFinals;// struct entries that need a finalzier run on them
    GCBits noscan;      // entries that should not be scanned
    GCBits appendable;  // entries that are appendable
    GCBits nointerior;  // interior pointers should be ignored.
                        // Only implemented for large object pools.
    size_t npages;
    size_t freepages;     // The number of pages not in use.
    ubyte* pagetable;

    bool isLargeObject;

    enum ShiftBy
    {
        Small = 4,
        Large = 12
    }
    ShiftBy shiftBy;    // shift count for the divisor used for determining bit indices.

    // This tracks how far back we have to go to find the nearest B_PAGE at
    // a smaller address than a B_PAGEPLUS.  To save space, we use a uint.
    // This limits individual allocations to 16 terabytes, assuming a 4k
    // pagesize.
    uint* bPageOffsets;

    // This variable tracks a conservative estimate of where the first free
    // page in this pool is, so that if a lot of pages towards the beginning
    // are occupied, we can bypass them in O(1).
    size_t searchStart;
    size_t largestFree; // upper limit for largest free chunk in large object pool

    void initialize(size_t npages, bool isLargeObject) nothrow
    {
        this.isLargeObject = isLargeObject;
        size_t poolsize;

        shiftBy = isLargeObject ? ShiftBy.Large : ShiftBy.Small;

        //debug(PRINTF) printf("Pool::Pool(%u)\n", npages);
        poolsize = npages * PAGESIZE;
        gcassert(poolsize >= POOLSIZE);
        baseAddr = cast(byte *)os_mem_map(poolsize);

        // Some of the code depends on page alignment of memory pools
        gcassert((cast(size_t)baseAddr & (PAGESIZE - 1)) == 0);

        if (!baseAddr)
        {
            //debug(PRINTF) printf("GC fail: poolsize = x%zx, errno = %d\n", poolsize, errno);
            //debug(PRINTF) printf("message = '%s'\n", sys_errlist[errno]);

            npages = 0;
            poolsize = 0;
        }
        //gcassert(baseAddr);
        topAddr = baseAddr + poolsize;
        auto nbits = cast(size_t)poolsize >> shiftBy;

        mark.alloc(nbits);

        // pagetable already keeps track of what's free for the large object
        // pool.
        if(!isLargeObject)
        {
            freebits.alloc(nbits);
        }

        noscan.alloc(nbits);
        appendable.alloc(nbits);

        pagetable = cast(ubyte*) malloc(npages);
        if (!pagetable)
            onOutOfMemoryErrorNoGC();

        if(isLargeObject)
        {
            bPageOffsets = cast(uint*) malloc(npages * uint.sizeof);
            if (!bPageOffsets)
                onOutOfMemoryErrorNoGC();
        }

        memset(pagetable, B_FREE, npages);

        this.npages = npages;
        this.freepages = npages;
        this.searchStart = 0;
        this.largestFree = npages;
    }


    void Dtor() nothrow
    {
        if (baseAddr)
        {
            int result;

            if (npages)
            {
                result = os_mem_unmap(baseAddr, npages * PAGESIZE);
                gcassert(result == 0);
                npages = 0;
            }

            baseAddr = null;
            topAddr = null;
        }
        if (pagetable)
        {
            free(pagetable);
            pagetable = null;
        }

        if(bPageOffsets)
            free(bPageOffsets);

        mark.Dtor();
        if(isLargeObject)
        {
            nointerior.Dtor();
        }
        else
        {
            freebits.Dtor();
        }
        finals.Dtor();
        structFinals.Dtor();
        noscan.Dtor();
        appendable.Dtor();
    }

    /**
    *
    */
    uint getBits(size_t biti) nothrow
    {
        uint bits;

        if (finals.nbits && finals.test(biti))
            bits |= BlkAttr.FINALIZE;
        if (structFinals.nbits && structFinals.test(biti))
            bits |= BlkAttr.STRUCTFINAL;
        if (noscan.test(biti))
            bits |= BlkAttr.NO_SCAN;
        if (nointerior.nbits && nointerior.test(biti))
            bits |= BlkAttr.NO_INTERIOR;
        if (appendable.test(biti))
            bits |= BlkAttr.APPENDABLE;
        return bits;
    }

    /**
     *
     */
    void clrBits(size_t biti, uint mask) nothrow @nogc
    {
        immutable dataIndex =  biti >> GCBits.BITS_SHIFT;
        immutable bitOffset = biti & GCBits.BITS_MASK;
        immutable keep = ~(GCBits.BITS_1 << bitOffset);

        if (mask & BlkAttr.FINALIZE && finals.nbits)
            finals.data[dataIndex] &= keep;

        if (structFinals.nbits && (mask & BlkAttr.STRUCTFINAL))
            structFinals.data[dataIndex] &= keep;

        if (mask & BlkAttr.NO_SCAN)
            noscan.data[dataIndex] &= keep;
        if (mask & BlkAttr.APPENDABLE)
            appendable.data[dataIndex] &= keep;
        if (nointerior.nbits && (mask & BlkAttr.NO_INTERIOR))
            nointerior.data[dataIndex] &= keep;
    }

    /**
     *
     */
    void setBits(size_t biti, uint mask) nothrow
    {
        // Calculate the mask and bit offset once and then use it to
        // set all of the bits we need to set.
        immutable dataIndex = biti >> GCBits.BITS_SHIFT;
        immutable bitOffset = biti & GCBits.BITS_MASK;
        immutable orWith = GCBits.BITS_1 << bitOffset;

        if (mask & BlkAttr.STRUCTFINAL)
        {
            if (!structFinals.nbits)
                structFinals.alloc(mark.nbits);
            structFinals.data[dataIndex] |= orWith;
        }

        if (mask & BlkAttr.FINALIZE)
        {
            if (!finals.nbits)
                finals.alloc(mark.nbits);
            finals.data[dataIndex] |= orWith;
        }

        if (mask & BlkAttr.NO_SCAN)
        {
            noscan.data[dataIndex] |= orWith;
        }
//        if (mask & BlkAttr.NO_MOVE)
//        {
//            if (!nomove.nbits)
//                nomove.alloc(mark.nbits);
//            nomove.data[dataIndex] |= orWith;
//        }
        if (mask & BlkAttr.APPENDABLE)
        {
            appendable.data[dataIndex] |= orWith;
        }

        if (isLargeObject && (mask & BlkAttr.NO_INTERIOR))
        {
            if(!nointerior.nbits)
                nointerior.alloc(mark.nbits);
            nointerior.data[dataIndex] |= orWith;
        }
    }

    void freePageBits(size_t pagenum, in ref PageBits toFree) nothrow
    {
        gcassert(!isLargeObject);
        gcassert(!nointerior.nbits); // only for large objects

        import core.internal.traits : staticIota;
        immutable beg = pagenum * (PAGESIZE / 16 / GCBits.BITS_PER_WORD);
        foreach (i; staticIota!(0, PageBits.length))
        {
            immutable w = toFree[i];
            if (!w) continue;

            immutable wi = beg + i;
            freebits.data[wi] |= w;
            noscan.data[wi] &= ~w;
            appendable.data[wi] &= ~w;
        }

        if (finals.nbits)
        {
            foreach (i; staticIota!(0, PageBits.length))
                if (toFree[i])
                    finals.data[beg + i] &= ~toFree[i];
        }

        if (structFinals.nbits)
        {
            foreach (i; staticIota!(0, PageBits.length))
                if (toFree[i])
                    structFinals.data[beg + i] &= ~toFree[i];
        }
    }

    /**
     * Given a pointer p in the p, return the pagenum.
     */
    size_t pagenumOf(void *p) const nothrow @nogc
    in
    {
        gcassert(p >= baseAddr);
        gcassert(p < topAddr);
    }
    do
    {
        return cast(size_t)(p - baseAddr) / PAGESIZE;
    }

    @property bool isFree() const pure nothrow
    {
        return npages == freepages;
    }

    void Invariant() const {}

    debug(INVARIANT)
    invariant()
    {
        //mark.Invariant();
        //scan.Invariant();
        //freebits.Invariant();
        //finals.Invariant();
        //structFinals.Invariant();
        //noscan.Invariant();
        //appendable.Invariant();
        //nointerior.Invariant();

        if (baseAddr)
        {
            //if (baseAddr + npages * PAGESIZE != topAddr)
                //printf("baseAddr = %p, npages = %d, topAddr = %p\n", baseAddr, npages, topAddr);
            gcassert(baseAddr + npages * PAGESIZE == topAddr);
        }

        if(pagetable !is null)
        {
            for (size_t i = 0; i < npages; i++)
            {
                Bins bin = cast(Bins)pagetable[i];
                gcassert(bin < B_MAX);
            }
        }
    }
}

struct LargeObjectPool
{
    Pool base;
    alias base this;

    void updateOffsets(size_t fromWhere) nothrow
    {
        gcassert(pagetable[fromWhere] == B_PAGE);
        size_t pn = fromWhere + 1;
        for(uint offset = 1; pn < npages; pn++, offset++)
        {
            if(pagetable[pn] != B_PAGEPLUS) break;
            bPageOffsets[pn] = offset;
        }

        // Store the size of the block in bPageOffsets[fromWhere].
        bPageOffsets[fromWhere] = cast(uint) (pn - fromWhere);
    }

    /**
     * Allocate n pages from Pool.
     * Returns size_t.max on failure.
     */
    size_t allocPages(size_t n) nothrow
    {
        if(largestFree < n || searchStart + n > npages)
            return size_t.max;

        //debug(PRINTF) printf("Pool::allocPages(n = %d)\n", n);
        size_t largest = 0;
        if (pagetable[searchStart] == B_PAGEPLUS)
        {
            searchStart -= bPageOffsets[searchStart]; // jump to B_PAGE
            searchStart += bPageOffsets[searchStart];
        }
        while (searchStart < npages && pagetable[searchStart] == B_PAGE)
            searchStart += bPageOffsets[searchStart];

        for (size_t i = searchStart; i < npages; )
        {
            gcassert(pagetable[i] == B_FREE);
            size_t p = 1;
            while (p < n && i + p < npages && pagetable[i + p] == B_FREE)
                p++;

            if (p == n)
                return i;

            if (p > largest)
                largest = p;

            i += p;
            while(i < npages && pagetable[i] == B_PAGE)
            {
                // we have the size information, so we skip a whole bunch of pages.
                i += bPageOffsets[i];
            }
        }

        // not enough free pages found, remember largest free chunk
        largestFree = largest;
        return size_t.max;
    }

    /**
     * Free npages pages starting with pagenum.
     */
    void freePages(size_t pagenum, size_t npages) nothrow @nogc
    {
        //memset(&pagetable[pagenum], B_FREE, npages);
        if(pagenum < searchStart)
            searchStart = pagenum;

        for(size_t i = pagenum; i < npages + pagenum; i++)
        {
            if(pagetable[i] < B_FREE)
            {
                freepages++;
            }

            pagetable[i] = B_FREE;
        }
        largestFree = freepages; // invalidate
    }

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
        gcassert(bin == B_PAGE);
        return bPageOffsets[pagenum] * PAGESIZE;
    }

    /**
    *
    */
    BlkInfo getInfo(void* p) nothrow
    {
        BlkInfo info;

        size_t offset = cast(size_t)(p - baseAddr);
        size_t pn = offset / PAGESIZE;
        Bins bin = cast(Bins)pagetable[pn];

        if (bin == B_PAGEPLUS)
            pn -= bPageOffsets[pn];
        else if (bin != B_PAGE)
            return info;           // no info for free pages

        info.base = baseAddr + pn * PAGESIZE;
        info.size = bPageOffsets[pn] * PAGESIZE;

        info.attr = getBits(pn);
        return info;
    }

    void runFinalizers(in void[] segment) nothrow
    {
        foreach (pn; 0 .. npages)
        {
            Bins bin = cast(Bins)pagetable[pn];
            if (bin > B_PAGE)
                continue;
            size_t biti = pn;

            if (!finals.test(biti))
                continue;

            auto p = sentinel_add(baseAddr + pn * PAGESIZE);
            size_t size = bPageOffsets[pn] * PAGESIZE - SENTINEL_EXTRA;
            uint attr = getBits(biti);

            if(!rt_hasFinalizerInSegment(p, size, attr, segment))
                continue;

            rt_finalizeFromGC(p, size, attr);

            clrBits(biti, ~BlkAttr.NONE);

            if (pn < searchStart)
                searchStart = pn;

            debug(COLLECT_PRINTF) printf("\tcollecting big %p\n", p);
            //log_free(sentinel_add(p));

            size_t n = 1;
            for (; pn + n < npages; ++n)
                if (pagetable[pn + n] != B_PAGEPLUS)
                    break;
            debug (MEMSTOMP) memset(baseAddr + pn * PAGESIZE, 0xF3, n * PAGESIZE);
            freePages(pn, n);
        }
    }
}
