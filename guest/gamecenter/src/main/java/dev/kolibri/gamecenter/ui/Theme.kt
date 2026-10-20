package dev.kolibri.gamecenter.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

object GcColors {
    val Background = Color(0xFF0E1018)
    val Surface = Color(0xFF171A26)
    val SurfaceHigh = Color(0xFF212536)
    val Accent = Color(0xFF7C5CFF)
    val AccentAlt = Color(0xFF00E5A8)
    val TextPrimary = Color(0xFFF2F3F8)
    val TextSecondary = Color(0xFF9AA0B8)

    val BackgroundBrush = Brush.linearGradient(listOf(Color(0xFF151129), Background, Color(0xFF0B1A1C)))
    val AccentBrush = Brush.horizontalGradient(listOf(Accent, Color(0xFF4C8DFF)))
}

private val scheme = darkColorScheme(
    primary = GcColors.Accent,
    onPrimary = Color.White,
    secondary = GcColors.AccentAlt,
    onSecondary = Color.Black,
    background = GcColors.Background,
    onBackground = GcColors.TextPrimary,
    surface = GcColors.Surface,
    onSurface = GcColors.TextPrimary,
    surfaceVariant = GcColors.SurfaceHigh,
    onSurfaceVariant = GcColors.TextSecondary,
    surfaceContainer = GcColors.SurfaceHigh,
)

@Composable
fun GameCenterTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, content = content)
}
