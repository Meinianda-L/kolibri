package dev.kolibri.gamecenter

import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import dev.kolibri.gamecenter.ui.GameCenterApp
import dev.kolibri.gamecenter.ui.GameCenterTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val repository by lazy { GameRepository(applicationContext) }
    private val snackbar = SnackbarHostState()

    private var apps by mutableStateOf<List<AppEntry>?>(null)
    /** preferredDisplayModeId this window asked for; 0 = system default. */
    private var requestedModeId by mutableStateOf(0)

    private val pickApk = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) installApk(uri)
    }

    private val installStatus = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java)
                        ?.let { startActivity(it) }
                }
                PackageInstaller.STATUS_SUCCESS -> {
                    notify(getString(R.string.install_success))
                    reload()
                }
                PackageInstaller.STATUS_FAILURE_ABORTED -> notify(getString(R.string.install_aborted))
                else -> {
                    val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "status $status"
                    notify(getString(R.string.install_failed, msg))
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        ContextCompat.registerReceiver(
            this, installStatus, IntentFilter(ApkInstaller.ACTION_INSTALL_STATUS),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        setContent {
            GameCenterTheme {
                GameCenterApp(
                    apps = apps,
                    snackbar = snackbar,
                    requestedModeId = requestedModeId,
                    onResume = ::reload,
                    onLaunch = ::launch,
                    onAppInfo = ::openAppInfo,
                    onUninstall = ::uninstall,
                    onToggleMyGames = { app, include ->
                        repository.setInMyGames(app, include)
                        reload()
                    },
                    onInstallApk = ::pickApkFile,
                    onRequestMode = ::requestDisplayMode,
                )
            }
        }
    }

    override fun onDestroy() {
        unregisterReceiver(installStatus)
        super.onDestroy()
    }

    private fun reload() {
        lifecycleScope.launch { apps = repository.loadApps() }
    }

    private fun notify(message: String) {
        lifecycleScope.launch { snackbar.showSnackbar(message) }
    }

    private fun launch(app: AppEntry) {
        val intent = packageManager.getLaunchIntentForPackage(app.packageName)
        if (intent == null) {
            notify(getString(R.string.cannot_launch, app.label))
            return
        }
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun openAppInfo(app: AppEntry) {
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", app.packageName, null))
        )
    }

    private fun uninstall(app: AppEntry) {
        // Result arrives implicitly: onResume reloads the list.
        startActivity(Intent(Intent.ACTION_DELETE, Uri.fromParts("package", app.packageName, null)))
    }

    private fun pickApkFile() {
        if (!ApkInstaller.canInstall(this)) {
            Toast.makeText(this, R.string.install_need_permission, Toast.LENGTH_LONG).show()
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.fromParts("package", packageName, null))
            )
            return
        }
        try {
            pickApk.launch(arrayOf(APK_MIME))
        } catch (_: ActivityNotFoundException) {
            notify(getString(R.string.no_picker))
        }
    }

    private fun installApk(uri: Uri) {
        lifecycleScope.launch {
            notify(getString(R.string.install_copying))
            runCatching { ApkInstaller.install(applicationContext, uri) }
                .onFailure { notify(getString(R.string.install_failed, it.message ?: it.javaClass.simpleName)) }
        }
    }

    private fun requestDisplayMode(modeId: Int) {
        window.attributes = window.attributes.apply { preferredDisplayModeId = modeId }
        requestedModeId = modeId
    }

    private companion object {
        const val APK_MIME = "application/vnd.android.package-archive"
    }
}
