package fixture;

import android.content.Context;
import com.lagradost.cloudstream3.plugins.Plugin;

/** An extractor-only extension: registers no provider (RT-12). */
public class ExtractorHostPlugin extends Plugin {
    @Override
    public void load(Context context) {
        registerExtractorAPI(new HostExtractor());
    }
}
