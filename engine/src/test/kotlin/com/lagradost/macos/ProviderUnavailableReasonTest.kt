package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.plugins.BasePlugin
import kotlin.test.*

/** E2: "not installed" is said only when nothing provides the title's provider. */
class ProviderUnavailableReasonTest {
    private val id = "a".repeat(64)

    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() { PluginBridge.detach(id); ExtensionTestSupport.resetHome() }

    private fun install(transform: (DaemonState.InstalledExtension) -> DaemonState.InstalledExtension = { it }) {
        val record = DaemonState.InstalledExtension(id, "https://r.invalid/repo.json", "MovieBoxProvider", "c".repeat(64),
            "g", "d".repeat(64), 0, RepositoryService.SitePlugin(name = "MovieBox", internalName = "MovieBoxProvider", version = 3),
            providerNames = listOf("MovieBox"))
        DaemonState.update { it.copy(installations = it.installations + (id to transform(record))) }
    }

    @Test fun `nothing installed says so and how to fix it`() {
        assertEquals("No installed extension provides “MovieBox”. Install it from Settings ▸ Extensions.",
            ProviderExecutor.unavailableReason("MovieBox"))
        assertEquals("No provider was given for this title.", ProviderExecutor.unavailableReason("  "))
    }

    @Test fun `each installation state is named`() {
        install { it.copy(enabled = false) }
        assertTrue("is turned off" in ProviderExecutor.unavailableReason("$id:MovieBox"))
        install { it.copy(quarantinedReason = "It crashed repeatedly.") }
        assertTrue("was stopped: It crashed repeatedly." in ProviderExecutor.unavailableReason("MovieBox"))
        install { it.copy(revokedReason = "The publisher disabled it.") }
        assertTrue("is disabled: The publisher disabled it." in ProviderExecutor.unavailableReason("MovieBox"))
        install { it.copy(providerNames = listOf("MovieBox 2")) }
        assertTrue("no longer provides “MovieBox”" in ProviderExecutor.unavailableReason("$id:MovieBox"))
    }

    @Test fun `a loaded but disabled provider is reported as turned off`() {
        val provider = object : MainAPI() { override var name = "MovieBox" }.apply { sourcePlugin = id }
        PluginBridge.publish(PluginBridge.LoadedPlugin(id, "gen", "0".repeat(64), null, object : BasePlugin() {},
            listOf(provider), emptyList(), emptyList(), emptyList()))
        DaemonState.update { it.copy(disabledProviders = it.disabledProviders + "$id:MovieBox") }
        assertNull(ProviderExecutor.findProvider("$id:MovieBox"))
        assertEquals("The provider “MovieBox” is turned off. Turn it on in Settings ▸ Extensions.",
            ProviderExecutor.unavailableReason("$id:MovieBox"))
    }
}
