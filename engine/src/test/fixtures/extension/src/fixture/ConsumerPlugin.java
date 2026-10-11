package fixture;

import android.content.Context;
import com.lagradost.cloudstream3.plugins.Plugin;

/** A provider extension that relies on another extension's extractor (RT-12). */
public class ConsumerPlugin extends Plugin {
    @Override
    public void load(Context context) {
        registerMainAPI(new ConsumerApi());
        registerExtractorAPI(new LoopExtractor());
    }
}
