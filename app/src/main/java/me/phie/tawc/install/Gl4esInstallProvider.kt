package me.phie.tawc.install

import android.content.Context
import me.phie.tawc.compositor.CompositorService
import java.io.File

/**
 * Lays the APK-bundled [gl4es](https://github.com/ptitSeb/gl4es)
 * `libGL.so.1` into a rootfs at [GUEST_LIB_DIR] = `/usr/lib/gl4es/`.
 * Consumed only by the [me.phie.tawc.GraphicsBackend.LIBHYBRIS_GL4ES]
 * edge-case backend — see
 * [notes/libhybris-gl4es.md](../../../../../../../notes/libhybris-gl4es.md).
 *
 * Same shape as [MesaZinkInstallProvider]: shipped unconditionally
 * alongside libhybris (a single stripped `.so`, negligible size), only
 * loaded when `RootfsEnv` puts this dir on `LD_LIBRARY_PATH`, which
 * only happens for `LIBHYBRIS_GL4ES`.
 *
 * Returns an empty list on devices where no gl4es asset is shipped for
 * the host ABI, or when this backend is disabled at build time;
 * [TawcInstaller] still records the empty manifest + stamp so
 * subsequent app starts hit the no-op path.
 */
internal object Gl4esInstallProvider : TawcInstallProvider {
    override val name: String = "gl4es"

    /** Guest-side install root. `RootfsEnv` adds this dir to
     *  `LD_LIBRARY_PATH` ahead of [LibhybrisInstallProvider.GUEST_LIB_DIR]
     *  under the `LIBHYBRIS_GL4ES` backend so gl4es's `libGL.so.1` wins
     *  over libhybris's `gl-shims/libGL.so.1`. */
    const val GUEST_LIB_DIR = "/usr/lib/gl4es"

    override fun entries(context: Context, methodKey: String): List<TawcInstall> {
        // Build-time disabled (`-PtawcGraphics=...` without
        // libhybris-gl4es): no APK asset shipped, nothing to install.
        if (!EnabledGraphicsBackends.libhybrisGl4es) return emptyList()
        // tawcroot binds the whole dir RO instead ([TawcrootMethod.assetBinds]);
        // this provider's entire output is that dir, so there's nothing
        // left to copy.
        if (methodKey == TawcrootMethod.KEY) return emptyList()
        if (!CompositorService.ensureGl4esExtracted(context)) return emptyList()
        val srcDir = File(context.filesDir, "gl4es").canonicalFile
        if (!srcDir.isDirectory) return emptyList()
        val entries = mutableListOf<TawcInstall>()
        walk(srcDir, srcDir, GUEST_LIB_DIR, entries)
        return entries
    }

    /** Recursively walk [dir] and append a [TawcInstall] per file or
     *  symlink, stripping [root] off the source path. Mirrors
     *  [MesaZinkInstallProvider.walk]. Skips the `.version` stamp
     *  written by [CompositorService.ensureGl4esExtracted]. */
    private fun walk(
        root: File,
        dir: File,
        destBase: String,
        out: MutableList<TawcInstall>,
    ) {
        val children = dir.listFiles()?.sortedBy { it.name } ?: return
        for (child in children) {
            if (child.parentFile == root && child.name == ".version") continue
            val rel = child.relativeTo(root).path
            val dest = "$destBase/$rel"
            val path = child.toPath()
            if (java.nio.file.Files.isSymbolicLink(path)) {
                val target = java.nio.file.Files.readSymbolicLink(path).toString()
                out += TawcInstall(
                    src = target,
                    dest = dest,
                    type = TawcInstall.Type.LINK,
                )
            } else if (child.isDirectory) {
                walk(root, child, destBase, out)
            } else if (child.isFile) {
                out += TawcInstall(
                    src = child.absolutePath,
                    dest = dest,
                    type = TawcInstall.Type.COPY,
                )
            }
        }
    }
}
