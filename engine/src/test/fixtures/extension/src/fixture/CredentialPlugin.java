package fixture;

import android.content.Context;
import com.lagradost.cloudstream3.plugins.Plugin;

/** Registers [CredentialApi]. */
public class CredentialPlugin extends Plugin {
    @Override
    public void load(Context context) {
        registerMainAPI(new CredentialApi());
    }
}
