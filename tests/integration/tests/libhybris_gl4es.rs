//! Tests for the LibhybrisGl4es edge-case backend: gl4es (desktop-GL →
//! GLES2 userspace translator) layered ahead of libhybris on
//! `LD_LIBRARY_PATH`, for legacy fixed-function desktop-GL apps
//! (`glxgears`) that the default `Libhybris` backend's GLES-only
//! `gl-shims/` wrapper can't run at all — see
//! `notes/libhybris-gl4es.md`.
//!
//! Not a general desktop-GL fix (gl4es caps at GL 2.1/GLSL 1.20, X11/GLX
//! only) — this backend is never the build-time or runtime default.
//! Every spawn here pins [`GraphicsBackend::LibhybrisGl4es`] explicitly.
//!
//! libhybris (and therefore gl4es, which depends on it) is aarch64-only
//! in tawc. `scripts/run-integration-tests.sh` marks the active tests
//! in this module ignored on x86 devices.

use std::time::{Duration, Instant};

use tawc_integration::helpers::{assert_compositor_clean, TIMEOUT};
use tawc_integration::rootfs_process::RootfsProcess;
use tawc_integration::{adb, compositor, GraphicsBackend};

const BACKEND: GraphicsBackend = GraphicsBackend::LibhybrisGl4es;

/// `glxgears` fails outright under the default `Libhybris` backend
/// (`symbol lookup error: glxgears: undefined symbol: glTranslated` —
/// GLES has no fixed-function pipeline). Under `LibhybrisGl4es` it must
/// link, initialise gl4es against libhybris's real GLESv2/EGL, and
/// render real frames — proven by AHB imports landing in the
/// compositor, not just process exit status (a stub/no-op renderer
/// could exit 0 without ever presenting).
#[test]
#[cfg_attr(
    tawc_skip_libhybris_on_target,
    ignore = "libhybris-gl4es skipped on x86 device"
)]
fn test_glxgears_renders_via_ahb() {
    tawc_integration::helpers::test_init();

    let before = compositor::query_state(TIMEOUT).expect("query compositor state before glxgears");
    // RootfsEnv's LIBHYBRIS_GL4ES case already sets HYBRIS_EGLPLATFORM=x11
    // and LIBGL_NOTEST=1 — no per-command env override needed here,
    // unlike xwayland::test_es2gears_x11_renders_via_ahb which pins
    // HYBRIS_EGLPLATFORM=x11 inline because it runs under the
    // Libhybris backend (whose default is HYBRIS_EGLPLATFORM=wayland).
    let mut app = RootfsProcess::spawn_with(BACKEND, "glxgears > /dev/null 2>&1")
        .expect("spawn glxgears");

    // Same shape as test_es2gears_x11_renders_via_ahb: wait for the
    // pipe to prove itself healthy rather than sleeping a fixed window
    // (Xwayland spawn + gl4es's own EGL/GLES init can eat a few seconds
    // on a cold start).
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let state = compositor::query_state(TIMEOUT).expect("query compositor state");
        let create_count = state
            .wlegl_create_buffer_total
            .saturating_sub(before.wlegl_create_buffer_total);
        if create_count >= 50 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "glxgears pipe never got healthy under LibhybrisGl4es: \
             {create_count} AHB imports (want >=50). Either gl4es failed \
             to initialise (check LIBGL_NOTEST / HYBRIS_EGLPLATFORM=x11 \
             still reach the child — see notes/libhybris-gl4es.md), or \
             it fell back to a non-GPU path. before={before:?} state={state:?}",
        );
        std::thread::sleep(Duration::from_millis(200));
    }

    app.stop().expect("glxgears failed to stop cleanly");
    assert_compositor_clean();
}

/// `vulkaninfo`/GLES-native apps must still work unmodified under this
/// backend's libhybris dir — `LibhybrisGl4es`'s `LD_LIBRARY_PATH` keeps
/// the raw libhybris tree (not `gl-shims/`) behind gl4es's `libGL.so.1`,
/// so anything that dlopens `libGLESv2.so`/`libEGL.so` directly (not
/// through gl4es's `libGL.so.1`) must resolve the same real libhybris
/// libraries the default `Libhybris` backend uses.
#[test]
#[cfg_attr(
    tawc_skip_libhybris_on_target,
    ignore = "libhybris-gl4es skipped on x86 device"
)]
fn test_eglinfo_reports_real_gles_renderer() {
    tawc_integration::helpers::test_init();

    let out = adb::rootfs_run_with(BACKEND, "eglinfo -B")
        .expect("failed to run eglinfo in chroot");
    assert!(
        out.status.success(),
        "eglinfo exited non-zero under LibhybrisGl4es: status={:?}\nstdout:\n{}\nstderr:\n{}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("OpenGL ES profile renderer:"),
        "no GLES renderer reported\nstdout:\n{stdout}"
    );
    assert!(
        !stdout.contains("llvmpipe"),
        "LibhybrisGl4es fell back to llvmpipe instead of the real \
         vendor GLES driver\nstdout:\n{stdout}"
    );
}
