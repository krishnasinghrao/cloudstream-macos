package fixture;

import com.lagradost.cloudstream3.MainAPI;
import com.lagradost.cloudstream3.SubtitleFile;
import com.lagradost.cloudstream3.utils.ExtractorApiKt;
import com.lagradost.cloudstream3.utils.ExtractorLink;
import kotlin.Unit;
import kotlin.coroutines.Continuation;
import kotlin.jvm.functions.Function1;

/** A provider whose links are video-host URLs another extension extracts (RT-12). The data string is the host URL. */
public class ConsumerApi extends MainAPI {
    public ConsumerApi() {
        setName("ConsumerProvider");
        setMainUrl("https://consumer.invalid");
    }

    @Override
    public Object loadLinks(String data, boolean isCasting, Function1<? super SubtitleFile, Unit> subtitleCallback,
                            Function1<? super ExtractorLink, Unit> callback, Continuation<? super Boolean> continuation) {
        return ExtractorApiKt.loadExtractor(data, "https://consumer.invalid/", subtitleCallback, callback, continuation);
    }
}
