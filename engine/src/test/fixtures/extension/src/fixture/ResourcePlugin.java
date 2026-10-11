package fixture;

import android.content.Context;
import android.content.res.Resources;
import com.lagradost.cloudstream3.plugins.Plugin;
import java.io.InputStream;
import java.util.Arrays;

/**
 * A requiresResources=true extension built with aapt2 (plan RT-13). Reads its
 * compiled resources and assets during load(), as Android extensions do, and
 * fails loudly if any value differs from Android's behaviour.
 */
public class ResourcePlugin extends Plugin {
    @Override
    public void load(Context context) {
        Resources res = getResources();
        if (res == null) throw new IllegalStateException("resources not bound before load");
        int nameId = res.getIdentifier("provider_name", "string", "com.example.resfixture");
        String name = res.getString(nameId);
        check("default locale", "ResourceProvider", name);
        check("qualified name", nameId, res.getIdentifier("com.example.resfixture:string/provider_name", null, null));
        check("entry name", "provider_name", res.getResourceEntryName(nameId));
        check("format", "Hello Mac, page 2", res.getString(res.getIdentifier("greeting", "string", null), "Mac", 2));
        check("reference", "ResourceProvider", res.getString(res.getIdentifier("alias", "string", null)));
        check("array", "[alpha, ResourceProvider]", Arrays.toString(res.getStringArray(res.getIdentifier("mirrors", "array", null))));
        check("int array", "[12, 24]", Arrays.toString(res.getIntArray(res.getIdentifier("sizes", "array", null))));
        check("integer", 24, res.getInteger(res.getIdentifier("page_size", "integer", null)));
        check("bool", true, res.getBoolean(res.getIdentifier("enabled", "bool", null)));
        check("color", 0xFF112233, res.getColor(res.getIdentifier("accent", "color", null)));
        check("missing", 0, res.getIdentifier("absent", "string", null));
        try { res.getString(0x7f0fffff); throw new IllegalStateException("missing ID did not throw"); }
        catch (Resources.NotFoundException expected) { }
        String mainUrl;
        try (InputStream in = res.getAssets().open("config/main-url.txt")) { mainUrl = new String(in.readAllBytes()); }
        catch (java.io.IOException e) { throw new IllegalStateException(e); }
        check("asset list", "[main-url.txt]", Arrays.toString(res.getAssets().list("config")));
        registerMainAPI(new ResourceApi(name, mainUrl));
    }

    private static void check(String what, Object expected, Object actual) {
        if (!expected.equals(actual)) throw new IllegalStateException(what + ": expected " + expected + " but was " + actual);
    }
}
