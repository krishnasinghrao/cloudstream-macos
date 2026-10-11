package fixture;

import android.content.Context;
import android.content.SharedPreferences;
import com.lagradost.cloudstream3.plugins.Plugin;

/**
 * An extension that needs configuration before it works (plan RT-15), like
 * self-hosted providers: it reads its server, a number, a flag and a set from
 * SharedPreferences at load. Its Android settings screen does not exist on
 * macOS; the keys below are what the native editor must discover and edit.
 */
public class ConfigurablePlugin extends Plugin {
    @Override
    public void load(Context context) {
        SharedPreferences prefs = context.getSharedPreferences("configurable", Context.MODE_PRIVATE);
        String server = prefs.getString("server", null);
        int pageSize = prefs.getInt("page_size", 10);
        boolean adult = prefs.getBoolean("show_adult", false);
        java.util.Set<String> mirrors = prefs.getStringSet("mirrors", null);
        registerMainAPI(new ConfigurableApi(server, pageSize + "|" + adult + "|" + (mirrors == null ? 0 : mirrors.size())));
    }
}
