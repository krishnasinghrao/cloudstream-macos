package android.preference

import android.content.Context
import android.content.SharedPreferences

/**
 * Android `android.preference.PreferenceManager` (A2): the default
 * preferences are the extension's own `<package>_preferences` file, so the
 * Extension Settings sheet and the preference scanner see them like any
 * other SharedPreferences the extension keeps.
 */
open class PreferenceManager private constructor() {
    companion object {
        @JvmStatic fun getDefaultSharedPreferencesName(context: Context): String = context.getPackageName() + "_preferences"

        @JvmStatic fun getDefaultSharedPreferences(context: Context): SharedPreferences =
            context.getSharedPreferences(getDefaultSharedPreferencesName(context), Context.MODE_PRIVATE)
    }
}
