package fixture;

/** FixtureApi's homepage under a name and URL taken from compiled resources and assets. */
public class ResourceApi extends FixtureApi {
    public ResourceApi(String name, String mainUrl) {
        setName(name);
        setMainUrl(mainUrl);
    }
}
