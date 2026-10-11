package fixture;

import android.content.Context;
import android.content.SharedPreferences;
import com.lagradost.cloudstream3.plugins.Plugin;

/**
 * Compiled with javac and converted by d8 exactly like a community extension.
 * Exercises the Android descriptors the macOS stubs must match:
 * Plugin.load(Context), Context.getSharedPreferences -> SharedPreferences,
 * SharedPreferences.Editor (invokeinterface), android.util.Pair public fields.
 */
public class FixturePlugin extends Plugin {
    public static volatile String lastPreference;

    @Override
    public void load(Context context) {
        SharedPreferences preferences = context.getSharedPreferences("fixture", Context.MODE_PRIVATE);
        preferences.edit().putString("loaded", "yes").apply();
        lastPreference = preferences.getString("loaded", null);
        android.util.Pair<String, String> pair = new android.util.Pair<>("a", "b");
        if (!"a".equals(pair.first) || !"b".equals(pair.second)) throw new IllegalStateException("Pair ABI mismatch");
        registerMainAPI(new FixtureApi());
    }
}
