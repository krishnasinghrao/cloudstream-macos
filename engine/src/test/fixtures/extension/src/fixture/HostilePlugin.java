package fixture;

import android.content.Context;
import com.lagradost.cloudstream3.plugins.Plugin;

/** Misbehaving extension for isolation tests (ADR-0016). Never shipped. */
public class HostilePlugin extends Plugin {
    @Override
    public void load(Context context) {
        registerMainAPI(new HostileApi(context.getFilesDir()));
    }
}
