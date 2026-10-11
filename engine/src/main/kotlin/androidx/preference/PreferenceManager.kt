package androidx.preference

import android.content.Context
import android.content.SharedPreferences

/**
 * AndroidX `androidx.preference.PreferenceManager` (A2): the same default
 * preferences file as [android.preference.PreferenceManager].
 */
open class PreferenceManager private constructor() {
    companion object {
        @JvmStatic fun getDefaultSharedPreferencesName(context: Context): String =
            android.preference.PreferenceManager.getDefaultSharedPreferencesName(context)

        @JvmStatic fun getDefaultSharedPreferences(context: Context): SharedPreferences =
            android.preference.PreferenceManager.getDefaultSharedPreferences(context)
    }
}
