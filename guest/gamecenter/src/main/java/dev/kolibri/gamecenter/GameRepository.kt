package dev.kolibri.gamecenter

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.edit
import androidx.core.graphics.drawable.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.Collator

data class AppEntry(
    val packageName: String,
    val label: String,
    val icon: ImageBitmap,
    /** Declared a game by the app itself (category or legacy isGame flag). */
    val declaredGame: Boolean,
    /** Shown under "My games": declared and not hidden, or pinned by the user. */
    val inMyGames: Boolean,
    val pinned: Boolean,
)

/**
 * Reads launchable apps from PackageManager and applies the user's overrides.
 * Overrides live in SharedPreferences: "pinned" adds any app, "hidden" removes a declared game.
 * Nothing leaves the device.
 */
class GameRepository(private val context: Context) {
    private val pm = context.packageManager
    private val prefs = context.getSharedPreferences("game_center", Context.MODE_PRIVATE)

    suspend fun loadApps(): List<AppEntry> = withContext(Dispatchers.IO) {
        val pinned = prefs.getStringSet(KEY_PINNED, emptySet())!!
        val hidden = prefs.getStringSet(KEY_HIDDEN, emptySet())!!
        val iconPx = (96 * context.resources.displayMetrics.density).toInt()
        val collator = Collator.getInstance()

        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        pm.queryIntentActivities(launcher, PackageManager.MATCH_ALL)
            .map { it.activityInfo.applicationInfo }
            .distinctBy { it.packageName }
            .filter { it.packageName != context.packageName }
            .map { info ->
                val declared = isDeclaredGame(info)
                val isPinned = info.packageName in pinned
                AppEntry(
                    packageName = info.packageName,
                    label = info.loadLabel(pm).toString(),
                    icon = info.loadIcon(pm).toBitmap(iconPx, iconPx).asImageBitmap(),
                    declaredGame = declared,
                    inMyGames = isPinned || (declared && info.packageName !in hidden),
                    pinned = isPinned,
                )
            }
            .sortedWith { a, b -> collator.compare(a.label, b.label) }
    }

    fun setInMyGames(app: AppEntry, include: Boolean) {
        val pinned = prefs.getStringSet(KEY_PINNED, emptySet())!!.toMutableSet()
        val hidden = prefs.getStringSet(KEY_HIDDEN, emptySet())!!.toMutableSet()
        if (include) {
            hidden -= app.packageName
            if (!app.declaredGame) pinned += app.packageName
        } else {
            pinned -= app.packageName
            if (app.declaredGame) hidden += app.packageName
        }
        prefs.edit {
            putStringSet(KEY_PINNED, pinned)
            putStringSet(KEY_HIDDEN, hidden)
        }
    }

    private fun isDeclaredGame(info: ApplicationInfo): Boolean {
        @Suppress("DEPRECATION")
        val legacyFlag = info.flags and ApplicationInfo.FLAG_IS_GAME != 0
        return info.category == ApplicationInfo.CATEGORY_GAME || legacyFlag
    }

    private companion object {
        const val KEY_PINNED = "pinned"
        const val KEY_HIDDEN = "hidden"
    }
}
