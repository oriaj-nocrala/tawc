/**
 * Shared body for the generated desktop-GL ABI stubs.
 *
 * See deps/libhybris-shims/gl-desktop-abi.txt for why the stubs exist: they
 * are there so binaries linked against a full libGL can *load*, not so they
 * can render. Anything that actually calls one is asking for desktop GL,
 * which this stack does not have — say so once and return zero rather than
 * abort()ing an X server mid-startup.
 */

#include <string.h>
#include <unistd.h>

long tawc_gl_desktop_stub(const char *name)
{
    static int warned;

    if (!warned) {
        static const char prefix[] = "tawc: desktop GL is unavailable (GLES-only stack), stubbed call: ";
        warned = 1;
        (void)!write(2, prefix, sizeof(prefix) - 1);
        (void)!write(2, name, strlen(name));
        (void)!write(2, "\n", 1);
    }
    return 0;
}
