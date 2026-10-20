package dev.kolibri.gamecenter

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.view.Display

data class DisplayModeInfo(val id: Int, val width: Int, val height: Int, val refreshRate: Float)

data class DisplaySnapshot(
    val refreshRate: Float,
    val current: DisplayModeInfo,
    val supported: List<DisplayModeInfo>,
)

object DeviceInfo {
    val model: String get() = Build.MODEL
    val brand: String get() = "${Build.BRAND} / ${Build.MANUFACTURER}"
    val android: String get() = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
    val abis: String get() = Build.SUPPORTED_ABIS.joinToString()
    val cores: Int get() = Runtime.getRuntime().availableProcessors()

    fun totalMemoryGb(context: Context): Double {
        val mi = ActivityManager.MemoryInfo()
        context.getSystemService(ActivityManager::class.java).getMemoryInfo(mi)
        return mi.totalMem / (1024.0 * 1024 * 1024)
    }

    fun snapshot(display: Display): DisplaySnapshot {
        fun Display.Mode.info() = DisplayModeInfo(modeId, physicalWidth, physicalHeight, refreshRate)
        return DisplaySnapshot(
            refreshRate = display.refreshRate,
            current = display.mode.info(),
            supported = display.supportedModes.map { it.info() }.sortedByDescending { it.refreshRate },
        )
    }

    /** Highest refresh mode at the current resolution (falls back to any resolution). */
    fun highestRefreshMode(snapshot: DisplaySnapshot): DisplayModeInfo? {
        val sameSize = snapshot.supported.filter {
            it.width == snapshot.current.width && it.height == snapshot.current.height
        }
        return sameSize.ifEmpty { snapshot.supported }.maxByOrNull { it.refreshRate }
    }
}
