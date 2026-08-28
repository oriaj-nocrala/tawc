# libhybris + gl4es (edge-case legacy desktop-GL backend)

**Status:** implemented end-to-end as the `LIBHYBRIS_GL4ES` graphics
backend (`libhybris-gl4es` wire key). Not the default, not a fix for
the general desktop-GL-3.x gap
([plans/gl-on-gles-translator.md](../plans/gl-on-gles-translator.md)) —
a narrow escape hatch for legacy fixed-function desktop-GL apps
(`glxgears`, anything calling `glTranslated`/`glRotatef`/immediate-mode
`glBegin`/`glEnd`) that the default `LIBHYBRIS` backend's GLES-only
`gl-shims/` wrapper can't run at all (`glxgears` fails outright:
`symbol lookup error: glxgears: undefined symbol: glTranslated`).

## Why this exists

`LIBHYBRIS` shadows `libGL.so.1` with `gl-shims/`, which forwards
straight to real GLESv2 — GLES has no fixed-function pipeline, so any
app using legacy immediate-mode GL 1.x/2.1 calls fails to link at all.
`LIBHYBRIS_ZINK` (see [notes/libhybris-zink.md](libhybris-zink.md))
would be the "real" fix, translating GL through Mesa to Vulkan, but
it's gated on `VK_KHR_dynamic_rendering` (Vulkan 1.3) — every Adreno
device tested so far (OnePlus 9, Pixel 4a, Lenovo Tab P11: all Vulkan
1.1.128) fails that gate regardless of how well its base Vulkan works.
[gl4es](https://github.com/ptitSeb/gl4es) sidesteps Vulkan entirely —
translates GL calls straight to GLES2 in userspace — so it's the only
path that actually runs `glxgears`-shaped apps on this hardware today.

`MobileGlues` (GL 4.0 on ES 3.2, higher ceiling than gl4es) was
evaluated as an alternative and rejected: it's a Minecraft/LWJGL
renderer component, not a system-wide `libGL.so` with GLX support — it
wouldn't run any generic X11/GLX binary at all, let alone `glxgears`.
gl4es remains the only viable general-purpose desktop-GL translator for
this use case.

## Stack

```
GLX app (glxgears, …)
  └─ libGL.so.1                      →  /usr/lib/gl4es/  (gl4es, real glX*)
       └─ dlopen("libEGL.so"/"libGLESv2.so") at runtime
            └─ /usr/lib/hybris/       (libhybris, real files)
                 └─ android_dlopen → Adreno GLES driver
                      → AHB present via android_wlegl (x11 ws / TAWC-DRI)
```

**No Zink, no Mesa, no Vulkan anywhere in this path.** gl4es creates its
GL context through libhybris's `x11` EGL platform (TAWC-DRI present,
the same XWayland-backed path `notes/xwayland.md` documents), not the
`wayland` platform `LIBHYBRIS` uses — GLX only exists on X11.

## The gl4es build

[deps/gl4es](https://github.com/ptitSeb/gl4es) pinned in
`deps/deps.list`. `scripts/build-gl4es.sh` cross-compiles just the `GL`
CMake target for `aarch64-linux-gnu`:

- No platform macro (`-DPANDORA`/`-DBCMHOST`/`-DODROID`/`-DCHIP`/
  `-DANDROID`/`-DHYBRIS`/`-DAMIGAOS4`) — every one of those forces
  `NOX11` and/or a vendor-specific context-creation path we don't want.
  Plain generic-Linux build → real `glX*` symbols, gl4es creates its
  own EGL context.
- **Do not use gl4es's own `-DHYBRIS` option** ("targeting Android
  drivers on GNU/Linux") despite the name match — that's Ubuntu
  Touch's route (`eglGetPlatformDisplay(EGL_PLATFORM_ANDROID_KHR, …)`),
  which selects libhybris's passthrough "null" window-system and
  segfaults in `eglCreateWindowSurface`. Use the plain generic build
  and set `HYBRIS_EGLPLATFORM=x11` at runtime instead (below).
- `-DDEFAULT_ES=2` picks the GLES2 backend (cmake defaults to GLES1.1
  otherwise). `NO_GBM` is forced on by gl4es's own `CMakeLists.txt`
  whenever `-DGBM` isn't passed, so no libdrm/gbm/egl pkg-config is
  needed for the cross sysroot.
- Host Khronos headers (`EGL/`, `GLES2/` — pure portable C, ABI-clean
  across host/target) via `-idirafter /usr/include`, same trick
  `scripts/build-libhybris.sh` uses for wayland/vulkan headers.
- Only `libX11` needs a link-time stub (`target_link_libraries(GL X11 m
  dl)` in gl4es's `src/CMakeLists.txt`) — reuses the
  `build/libhybris-aarch64/stubs/libX11.so.6` stub `build-libhybris.sh`
  already generates (builds libhybris first if that stub dir doesn't
  exist yet). `libm`/`libc` resolve from the aarch64-linux-gnu sysroot
  itself. gl4es dlopens `libEGL.so`/`libGLESv2.so` **by name** at
  runtime — no link-time EGL/GLES dependency at all, so no libhybris
  stub needed for those either.
- Output: `libGL.so.1` (SONAME `libGL.so.1`, real `glX*` exports),
  stripped, tarred as a single-file `.tar` (`gl4es.tar`) — same
  extract/bind shape as libhybris/mesa-zink even though it's one file,
  so `CompositorService.ensureGl4esExtracted` doesn't need a
  single-file special case.
- Readelf verify checks: uses an `awk`-with-`END`-exit pattern instead
  of `grep -q` for the large symbol-table scan — `grep -q`'s early exit
  on match sends `readelf` `SIGPIPE` mid-dump, which `set -o pipefail`
  reports as a pipeline failure even though the symbol was actually
  found. Same trap `build-libhybris.sh`'s `check_glx_export` avoids the
  same way.

## What ships

- `deps/gl4es-aarch64/install/usr/lib/gl4es/libGL.so.1`, tarred into
  `assets/gl4es/arm64-v8a/gl4es.tar` by Gradle's `packGl4es` task,
  extracted to `<filesDir>/gl4es/` by
  `CompositorService.ensureGl4esExtracted`, exposed in each rootfs at
  `/usr/lib/gl4es/` — RO bind under tawcroot
  (`TawcrootMethod.assetBinds`), copy under proot/chroot
  (`Gl4esInstallProvider`).
- aarch64-only (same constraint as libhybris — no x86_64/emulator
  asset).

## Env (`RootfsEnv.GraphicsBackend.LIBHYBRIS_GL4ES`)

- `LD_LIBRARY_PATH=/usr/lib/gl4es:/usr/lib/hybris` — gl4es's own
  `libGL.so.1` first (real `glX*`, unlike `LIBHYBRIS`'s GLX-null
  `gl-shims/libGL.so.1`), then the **raw** libhybris dir (not
  `gl-shims/`) so gl4es's `dlopen("libEGL.so")`/`dlopen("libGLESv2.so")`
  resolve through libtool's unversioned symlink chain
  (`libEGL.so → libEGL.so.1 → libEGL.so.1.0.0`). `gl-shims/` is
  deliberately excluded — it exists only to give `LIBHYBRIS` a
  GLX-null-stubbed `libGL.so.1`, which this backend doesn't need
  (gl4es already provides real GLX).
- `HYBRIS_EGLPLATFORM=x11` — see "Do not use gl4es's own `-DHYBRIS`
  option" above; this is the runtime half of that same gotcha.
- `LIBGL_NOTEST=1` — gl4es's own hardware-capability probe against
  `EGL_DEFAULT_DISPLAY` runs before the app's real
  `eglCreateWindowSurface` and can wedge context creation on this
  stack (worked around during the original OnePlus 9 spike, still
  needed).
- No `GDK_GL` override — this backend isn't meant for GTK/Wayland
  clients (those already work over plain `LIBHYBRIS`); it's for X11
  GLX binaries specifically.

## Verification (2026-08-28, Lenovo Tab P11 / Adreno 610 / Vulkan 1.1.128)

`glxgears` under this backend:

```
LIBGL: Initialising gl4es
LIBGL: Using GLES 2.0 backend
LIBGL: loaded: libGLESv2.so
LIBGL: loaded: libEGL.so
...
237 frames in 5.0 seconds = 47.244 FPS
```

Confirmed visually on-device: three-gear render, real color output, GPU
path (not a software fallback) — the same real Adreno GLESv2 driver
`LIBHYBRIS` uses, just reached through gl4es's translation layer
instead of directly.

## Selection

Per-spawn via the broker `GRAPHICS` header:
`tawc-exec --in-rootfs <id> --graphics libhybris-gl4es …`, or picked
persistently in Settings → Graphics backend →
"libhybris+gl4es (legacy GL)". Never the build-time or runtime
*default* — `GraphicsBackend.DEFAULT` always prefers `LIBHYBRIS`
(aarch64) / `GFXSTREAM` (x86_64) regardless of whether this backend is
enabled; a user has to pick it explicitly.

## Risks / limitations (why this isn't the default GL path)

Same ceiling the 2026-07-06 spike already found, unchanged by shipping
it as an edge case:

- **GL 2.1 / GLSL 1.20 ceiling.** No GL 3.x core contexts, textual
  (not SPIR-V) shader translation. Misses kitty and any modern-GL app —
  those need [plans/gl-on-gles-translator.md](gl-on-gles-translator.md)
  or a Vulkan-1.3-capable device for `LIBHYBRIS_ZINK`.
- **X11/GLX only.** No Wayland-native client support — irrelevant for
  this backend's actual target apps (they're GLX by construction), but
  worth remembering it's not a general `LIBHYBRIS` replacement.
- **Single global GL context, not thread-safe.** Fine for `glxgears`-
  shaped single-context apps; would need real work to safely host
  multiple concurrent GL clients.
- **Zink is still the right endgame** on Vulkan 1.3+ hardware once one
  is available to test against — this backend doesn't change that
  priority, it just covers devices that will never get there.
