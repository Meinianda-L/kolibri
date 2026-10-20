package dev.kolibri.gamecenter

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Streams a user-picked APK into a PackageInstaller session and commits it.
 * The system answers through a broadcast to [ACTION_INSTALL_STATUS] (registered by
 * MainActivity), first with STATUS_PENDING_USER_ACTION carrying the confirmation UI.
 * Single-APK only; split bundles (.apks/.xapk) are out of scope.
 */
object ApkInstaller {
    const val ACTION_INSTALL_STATUS = "dev.kolibri.gamecenter.action.INSTALL_STATUS"

    fun canInstall(context: Context): Boolean = context.packageManager.canRequestPackageInstalls()

    suspend fun install(context: Context, apk: Uri) = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val size = resolver.query(apk, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else -1L
        } ?: -1L

        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        if (size > 0) params.setSize(size)
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                val input = resolver.openInputStream(apk) ?: error("cannot open $apk")
                input.use {
                    session.openWrite("base.apk", 0, size).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }
                val callback = Intent(ACTION_INSTALL_STATUS).setPackage(context.packageName)
                val pending = PendingIntent.getBroadcast(
                    context, sessionId, callback,
                    // Mutable: the system fills in EXTRA_STATUS / EXTRA_INTENT.
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                session.commit(pending.intentSender)
            }
        } catch (t: Throwable) {
            installer.abandonSession(sessionId)
            throw t
        }
    }
}
