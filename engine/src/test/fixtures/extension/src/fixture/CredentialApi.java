package fixture;

import com.lagradost.cloudstream3.HomePageList;
import com.lagradost.cloudstream3.HomePageResponse;
import com.lagradost.cloudstream3.MainPageRequest;
import java.util.Collections;
import kotlin.coroutines.Continuation;

/**
 * A provider with an account (audit A33): its shelf name shows the address
 * and credential the live instance holds right now, so a test can see what a
 * running worker was actually left with after a set, a clear or a reset.
 */
public class CredentialApi extends FixtureApi {
    public CredentialApi() {
        setName("CredentialProvider");
        setMainUrl("https://account.invalid");
    }

    @Override
    public Object getMainPage(int page, MainPageRequest request, Continuation<? super HomePageResponse> continuation) {
        String credential = getStoredCredentials();
        String shelf = getMainUrl() + "|" + (credential == null ? "none" : credential);
        return new HomePageResponse(Collections.singletonList(new HomePageList(shelf, Collections.emptyList(), false)), false);
    }
}
