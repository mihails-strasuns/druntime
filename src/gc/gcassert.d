/**
 * Provides function with API similar to built-in `assert` but
 * one which always calls `abort` instead of trying to throw an exception.
 */
module gc.gcassert;

/**
 * Trivial utility to check if `condition` passes and abort otherwise.
 *
 * Allocating exception instance will cause GC deadlock if assert fires
 * within a GC implementation which is why a separate utility is needed.
 */
pragma(inline, true)
void gcassert(bool condition, string file = __FILE__, int line = __LINE__) nothrow @trusted @nogc pure
{
    version(assert)
    {
        import core.internal.abort;

        // technically not pure because of I/O but application will
        // abort right away anyway so it doesn't matter:
        auto _abort = cast(void function(string, string, int) pure nothrow @safe @nogc) &abort;

        if (!condition)
            _abort("GC internal assertion failure", file, line);
    }
}
