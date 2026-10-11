package fixture;

import com.lagradost.cloudstream3.HomePageList;
import com.lagradost.cloudstream3.HomePageResponse;
import com.lagradost.cloudstream3.MainPageRequest;
import java.util.Collections;
import kotlin.coroutines.Continuation;

/** Works only once a server is configured; its shelf name shows the settings it loaded with. */
public class ConfigurableApi extends FixtureApi {
    private final String server;
    private final String settings;

    public ConfigurableApi(String server, String settings) {
        this.server = server;
        this.settings = settings;
        setName("ConfigurableProvider");
        setMainUrl(server == null ? "https://unconfigured.invalid" : server);
    }

    @Override
    public Object getMainPage(int page, MainPageRequest request, Continuation<? super HomePageResponse> continuation) {
        if (server == null) throw new IllegalStateException("Server is not configured");
        return new HomePageResponse(Collections.singletonList(new HomePageList(settings, Collections.emptyList(), false)), false);
    }
}
