package fixture;

import android.content.Context;
import com.lagradost.cloudstream3.plugins.Plugin;

/** Registers a provider and then fails, like a partially initialized extension. */
public class FailingPlugin extends Plugin {
    @Override
    public void load(Context context) {
        registerMainAPI(new FixtureApi());
        throw new IllegalStateException("fixture load failure");
    }
}
