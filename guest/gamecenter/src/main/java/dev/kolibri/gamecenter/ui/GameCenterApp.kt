package dev.kolibri.gamecenter.ui

import android.hardware.display.DisplayManager
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import dev.kolibri.gamecenter.AppEntry
import dev.kolibri.gamecenter.DeviceInfo
import dev.kolibri.gamecenter.R
import java.util.Locale

private enum class Tab(val title: Int, val icon: ImageVector) {
    MyGames(R.string.tab_my_games, Icons.Filled.Home),
    AllApps(R.string.tab_all_apps, Icons.Filled.List),
    Performance(R.string.tab_performance, Icons.Filled.Settings),
}

@Composable
fun GameCenterApp(
    apps: List<AppEntry>?,
    snackbar: SnackbarHostState,
    requestedModeId: Int,
    onResume: () -> Unit,
    onLaunch: (AppEntry) -> Unit,
    onAppInfo: (AppEntry) -> Unit,
    onUninstall: (AppEntry) -> Unit,
    onToggleMyGames: (AppEntry, Boolean) -> Unit,
    onInstallApk: () -> Unit,
    onRequestMode: (Int) -> Unit,
) {
    // Installs/uninstalls happen in other activities; rescan whenever we come back.
    LifecycleResumeEffect(Unit) {
        onResume()
        onPauseOrDispose { }
    }
    var tab by rememberSaveable { mutableStateOf(Tab.MyGames) }

    Scaffold(
        containerColor = Color.Transparent,
        snackbarHost = { SnackbarHost(snackbar) },
        contentWindowInsets = WindowInsets(0),
        modifier = Modifier.background(GcColors.BackgroundBrush),
    ) { inner ->
        Row(
            Modifier
                .fillMaxSize()
                .padding(inner)
                .windowInsetsPadding(WindowInsets.safeDrawing),
        ) {
            SideBar(tab, onSelect = { tab = it }, onInstallApk = onInstallApk)
            Box(Modifier.fillMaxSize().padding(start = 8.dp, end = 24.dp, top = 20.dp)) {
                when {
                    tab == Tab.Performance -> PerformancePanel(requestedModeId, onRequestMode)
                    apps == null -> Loading()
                    tab == Tab.MyGames -> {
                        val games = apps.filter { it.inMyGames }
                        if (games.isEmpty()) EmptyState(onInstallApk)
                        else AppGrid(
                            header = stringResource(R.string.games_count, games.size),
                            apps = games, big = true,
                            onLaunch = onLaunch, onAppInfo = onAppInfo, onUninstall = onUninstall,
                            onToggleMyGames = onToggleMyGames,
                        )
                    }
                    else -> AppGrid(
                        header = stringResource(R.string.apps_count, apps.size),
                        apps = apps, big = false,
                        onLaunch = onLaunch, onAppInfo = onAppInfo, onUninstall = onUninstall,
                        onToggleMyGames = onToggleMyGames,
                    )
                }
            }
        }
    }
}

@Composable
private fun SideBar(selected: Tab, onSelect: (Tab) -> Unit, onInstallApk: () -> Unit) {
    Column(
        Modifier.fillMaxHeight().width(200.dp).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            stringResource(R.string.app_name),
            fontSize = 24.sp, fontWeight = FontWeight.Black, color = GcColors.TextPrimary,
            modifier = Modifier.padding(start = 8.dp, top = 4.dp, bottom = 18.dp),
        )
        Tab.entries.forEach { tab ->
            val active = tab == selected
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(if (active) GcColors.SurfaceHigh else Color.Transparent)
                    .combinedClickable(onClick = { onSelect(tab) })
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(tab.icon, null, tint = if (active) GcColors.AccentAlt else GcColors.TextSecondary)
                Spacer(Modifier.width(12.dp))
                Text(
                    stringResource(tab.title),
                    color = if (active) GcColors.TextPrimary else GcColors.TextSecondary,
                    fontWeight = if (active) FontWeight.Bold else FontWeight.Medium,
                )
            }
        }
        Spacer(Modifier.weight(1f))
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(GcColors.AccentBrush)
                .combinedClickable(onClick = onInstallApk)
                .padding(vertical = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Add, null, tint = Color.White)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.install_apk), color = Color.White, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
private fun Loading() {
    Column(Modifier.fillMaxSize(), Arrangement.Center, Alignment.CenterHorizontally) {
        CircularProgressIndicator(color = GcColors.AccentAlt)
        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.loading), color = GcColors.TextSecondary)
    }
}

@Composable
private fun EmptyState(onInstallApk: () -> Unit) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(88.dp).clip(CircleShape).background(GcColors.SurfaceHigh),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Star, null, tint = GcColors.AccentAlt, modifier = Modifier.size(44.dp))
        }
        Spacer(Modifier.height(16.dp))
        Text(stringResource(R.string.empty_title), fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))
        Text(
            stringResource(R.string.empty_body),
            color = GcColors.TextSecondary, lineHeight = 24.sp,
            modifier = Modifier.widthIn(max = 520.dp),
        )
        Spacer(Modifier.height(20.dp))
        Button(onClick = onInstallApk) {
            Icon(Icons.Filled.Add, null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.empty_action))
        }
    }
}

@Composable
private fun AppGrid(
    header: String,
    apps: List<AppEntry>,
    big: Boolean,
    onLaunch: (AppEntry) -> Unit,
    onAppInfo: (AppEntry) -> Unit,
    onUninstall: (AppEntry) -> Unit,
    onToggleMyGames: (AppEntry, Boolean) -> Unit,
) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(if (big) 148.dp else 112.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Text(header, color = GcColors.TextSecondary, modifier = Modifier.padding(bottom = 2.dp))
        }
        items(apps, key = { it.packageName }) { app ->
            AppTile(app, big, onLaunch, onAppInfo, onUninstall, onToggleMyGames)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun AppTile(
    app: AppEntry,
    big: Boolean,
    onLaunch: (AppEntry) -> Unit,
    onAppInfo: (AppEntry) -> Unit,
    onUninstall: (AppEntry) -> Unit,
    onToggleMyGames: (AppEntry, Boolean) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(GcColors.Surface)
                .border(1.dp, GcColors.SurfaceHigh, RoundedCornerShape(20.dp))
                .combinedClickable(onClick = { onLaunch(app) }, onLongClick = { menu = true })
                .padding(vertical = if (big) 18.dp else 12.dp, horizontal = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Image(
                app.icon, contentDescription = null,
                modifier = Modifier.size(if (big) 84.dp else 56.dp).clip(RoundedCornerShape(if (big) 20.dp else 14.dp)),
            )
            Spacer(Modifier.height(10.dp))
            Text(
                app.label,
                fontSize = if (big) 15.sp else 13.sp,
                fontWeight = if (big) FontWeight.SemiBold else FontWeight.Normal,
                maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
            )
        }
        if (app.inMyGames && !big) {
            Icon(
                Icons.Filled.Star, null, tint = GcColors.AccentAlt,
                modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).size(16.dp),
            )
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.menu_launch)) }, onClick = { menu = false; onLaunch(app) })
            DropdownMenuItem(
                text = {
                    Text(stringResource(if (app.inMyGames) R.string.menu_remove_from_games else R.string.menu_add_to_games))
                },
                onClick = { menu = false; onToggleMyGames(app, !app.inMyGames) },
            )
            DropdownMenuItem(text = { Text(stringResource(R.string.menu_app_info)) }, onClick = { menu = false; onAppInfo(app) })
            DropdownMenuItem(text = { Text(stringResource(R.string.menu_uninstall)) }, onClick = { menu = false; onUninstall(app) })
        }
    }
}

@Composable
private fun PerformancePanel(requestedModeId: Int, onRequestMode: (Int) -> Unit) {
    val context = LocalContext.current
    val display = LocalView.current.display ?: return
    var snapshot by remember { mutableStateOf(DeviceInfo.snapshot(display)) }

    // Refresh-rate changes arrive asynchronously after a mode request.
    DisposableEffect(display) {
        val dm = context.getSystemService(DisplayManager::class.java)
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayChanged(id: Int) {
                if (id == display.displayId) snapshot = DeviceInfo.snapshot(display)
            }
            override fun onDisplayAdded(id: Int) {}
            override fun onDisplayRemoved(id: Int) {}
        }
        dm.registerDisplayListener(listener, null)
        onDispose { dm.unregisterDisplayListener(listener) }
    }

    fun hz(v: Float) = String.format(Locale.ROOT, "%.0f Hz", v)
    val requested = snapshot.supported.firstOrNull { it.id == requestedModeId }

    Row(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 20.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Panel(stringResource(R.string.perf_device), Modifier.weight(1f)) {
            InfoRow(stringResource(R.string.perf_model), DeviceInfo.model)
            InfoRow(stringResource(R.string.perf_brand), DeviceInfo.brand)
            InfoRow(stringResource(R.string.perf_android), DeviceInfo.android)
            InfoRow(stringResource(R.string.perf_abi), DeviceInfo.abis)
            InfoRow(stringResource(R.string.perf_cores), DeviceInfo.cores.toString())
            InfoRow(
                stringResource(R.string.perf_memory),
                String.format(Locale.ROOT, "%.1f GB", DeviceInfo.totalMemoryGb(context)),
            )
        }
        Panel(stringResource(R.string.perf_display), Modifier.weight(1f)) {
            Text(hz(snapshot.refreshRate), fontSize = 44.sp, fontWeight = FontWeight.Black, color = GcColors.AccentAlt)
            Text(stringResource(R.string.perf_refresh), color = GcColors.TextSecondary)
            Spacer(Modifier.height(12.dp))
            InfoRow(stringResource(R.string.perf_resolution), "${snapshot.current.width} × ${snapshot.current.height}")
            InfoRow(
                stringResource(R.string.perf_modes),
                snapshot.supported.joinToString("\n") { "#${it.id}  ${it.width}×${it.height} @ ${hz(it.refreshRate)}" },
            )
            InfoRow(
                stringResource(R.string.perf_requested),
                requested?.let { "#${it.id} @ ${hz(it.refreshRate)}" } ?: stringResource(R.string.perf_requested_none),
            )
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(
                    onClick = { DeviceInfo.highestRefreshMode(snapshot)?.let { onRequestMode(it.id) } },
                    colors = ButtonDefaults.buttonColors(containerColor = GcColors.Accent),
                ) { Text(stringResource(R.string.perf_max_refresh)) }
                OutlinedButton(onClick = { onRequestMode(0) }) { Text(stringResource(R.string.perf_reset)) }
            }
            Spacer(Modifier.height(10.dp))
            Text(stringResource(R.string.perf_note), color = GcColors.TextSecondary, fontSize = 12.sp, lineHeight = 17.sp)
        }
    }
}

@Composable
private fun Panel(title: String, modifier: Modifier, content: @Composable () -> Unit) {
    Column(
        modifier
            .clip(RoundedCornerShape(22.dp))
            .background(GcColors.Surface)
            .padding(20.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(14.dp))
        content()
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 5.dp)) {
        Text(label, color = GcColors.TextSecondary, modifier = Modifier.width(150.dp))
        Text(value, color = GcColors.TextPrimary)
    }
}
