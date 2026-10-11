package fixture;

import com.lagradost.cloudstream3.SubtitleFile;
import com.lagradost.cloudstream3.utils.ExtractorApi;
import com.lagradost.cloudstream3.utils.ExtractorApiKt;
import com.lagradost.cloudstream3.utils.ExtractorLink;
import com.lagradost.cloudstream3.utils.ExtractorLinkType;
import java.util.Collections;
import kotlin.Unit;
import kotlin.coroutines.Continuation;
import kotlin.jvm.functions.Function1;

/**
 * A video-host extractor shipped by an extractor-only extension (RT-12). Resolves
 * {@code https://host.invalid/v/<id>} without network access; {@code /loop} asks
 * loadExtractor for a URL only the other fixture extension claims.
 */
public class HostExtractor extends ExtractorApi {
    @Override public String getName() { return "FixtureHost"; }
    @Override public String getMainUrl() { return "https://host.invalid"; }
    @Override public boolean getRequiresReferer() { return false; }

    @Override
    @SuppressWarnings({"unchecked", "rawtypes", "deprecation"})
    public Object getUrl(String url, String referer, Function1<? super SubtitleFile, Unit> subtitleCallback,
                         Function1<? super ExtractorLink, Unit> callback, Continuation<? super Unit> continuation) {
        if (url.contains("/loop")) {
            // Tail call: loadExtractor ignores getUrl's result, so passing this continuation on is safe.
            return ExtractorApiKt.loadExtractor("http://cyclefixture.test/again", null, subtitleCallback, callback, (Continuation) continuation);
        }
        String id = url.substring(url.lastIndexOf('/') + 1);
        callback.invoke(new ExtractorLink("FixtureHost", "FixtureHost " + id, "https://cdn.invalid/" + id + ".m3u8",
            referer == null ? "" : referer, 720, Collections.singletonMap("X-Fixture", id), "host-data",
            ExtractorLinkType.M3U8, Collections.emptyList()));
        return Unit.INSTANCE;
    }
}
