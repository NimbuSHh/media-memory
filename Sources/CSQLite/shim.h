#include <sqlite3.h>
#include <sys/file.h>

// Swift's Darwin overlay exposes `flock` as both a C struct name and a
// function, making a qualified call ambiguous. Keep the tiny C boundary here.
static inline int media_memory_flock(int descriptor, int operation) {
    return flock(descriptor, operation);
}
