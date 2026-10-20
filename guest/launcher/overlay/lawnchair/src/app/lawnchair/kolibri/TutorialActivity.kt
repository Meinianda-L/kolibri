/*
 * Part of Kolibri Launcher, a modified version of Lawnchair.
 * Copyright (C) 2026 Kolibri contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

package app.lawnchair.kolibri

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import com.android.launcher3.R

/**
 * The "Tutorial" icon on the default home screen: opens the Kolibri tutorial page in the
 * default browser. It is a launcher activity so the stock app-icon pipeline can place it on
 * the workspace, and it is listed in `filtered_components` so it stays out of the app drawer.
 */
class TutorialActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uri = Uri.parse(getString(R.string.kolibri_tutorial_url))
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW, uri)
                    .addCategory(Intent.CATEGORY_BROWSABLE)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "No activity to open $uri", e)
        }
        finish()
    }

    companion object {
        private const val TAG = "TutorialActivity"
    }
}
