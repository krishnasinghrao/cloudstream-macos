package fixture;

import com.lagradost.cloudstream3.HomePageList;
import com.lagradost.cloudstream3.HomePageResponse;
import com.lagradost.cloudstream3.MainAPI;
import com.lagradost.cloudstream3.MainPageData;
import com.lagradost.cloudstream3.MainPageRequest;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import kotlin.coroutines.Continuation;

/**
 * Provider registered by the fixture extensions (lives in classes2.dex for the
 * multi-DEX variant). Declares main-page requests like community providers do,
 * so the engine's homepage path runs against Android-compiled bytecode (T6.7).
 */
public class FixtureApi extends MainAPI {
    public FixtureApi() {
        setName("FixtureProvider");
        setMainUrl("https://fixture.invalid");
    }

    @Override
    public boolean getHasMainPage() {
        return true;
    }

    @Override
    public List<MainPageData> getMainPage() {
        return Arrays.asList(new MainPageData("Trending", "trending", false), new MainPageData("Latest", "latest", true));
    }

    /** Echoes the declared request so the host's request plumbing is observable. */
    @Override
    public Object getMainPage(int page, MainPageRequest request, Continuation<? super HomePageResponse> continuation) {
        String shelf = request.getName() + "|" + request.getData() + "|" + page;
        return new HomePageResponse(Collections.singletonList(
            new HomePageList(shelf, Collections.emptyList(), request.getHorizontalImages())), false);
    }
}
