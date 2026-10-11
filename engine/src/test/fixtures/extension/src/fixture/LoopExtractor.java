package fixture;

import com.lagradost.cloudstream3.SubtitleFile;
import com.lagradost.cloudstream3.utils.ExtractorApi;
import com.lagradost.cloudstream3.utils.ExtractorApiKt;
import com.lagradost.cloudstream3.utils.ExtractorLink;
import kotlin.Unit;
import kotlin.coroutines.Continuation;
import kotlin.jvm.functions.Function1;

/**
 * Sends every URL back to the host extension, which sends it back here: a route
 * cycle (RT-12). Its domain must stay dissimilar from host.invalid, or the
 * library's mirror-domain match (Levenshtein &gt; 80) claims host URLs locally.
 */
public class LoopExtractor extends ExtractorApi {
    @Override public String getName() { return "FixtureLoop"; }
    @Override public String getMainUrl() { return "http://cyclefixture.test"; }
    @Override public boolean getRequiresReferer() { return false; }

    @Override
    @SuppressWarnings({"unchecked", "rawtypes"})
    public Object getUrl(String url, String referer, Function1<? super SubtitleFile, Unit> subtitleCallback,
                         Function1<? super ExtractorLink, Unit> callback, Continuation<? super Unit> continuation) {
        return ExtractorApiKt.loadExtractor("https://host.invalid/loop", null, subtitleCallback, callback, (Continuation) continuation);
    }
}
