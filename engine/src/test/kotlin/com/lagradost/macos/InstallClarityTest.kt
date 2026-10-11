package com.lagradost.macos

import kotlin.test.*

/** X2/X3: what can never work is said at install; shared provider names are visible. */
class InstallClarityTest {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()
    @AfterTest fun after() = ExtensionTestSupport.resetHome()

    private fun report(vararg missing: Pair<String, String>) =
        CapabilityReport(missing = missing.map { (type, role) -> MissingHostType(type, role, listOf("x/Y")) })

    @Test fun `extensions that load APKs or manage repositories are refused before their code runs`() {
        assertTrue("Android app packages" in CompatibilityAssessment.impossibleReason(report("dalvik/system/BaseDexClassLoader" to "provider"))!!)
        assertTrue("repositories" in CompatibilityAssessment.impossibleReason(
            report("com/lagradost/cloudstream3/plugins/RepositoryManager" to "startup"))!!)
        // Only reachable code counts: a settings screen that mentions it is not a reason to refuse.
        assertNull(CompatibilityAssessment.impossibleReason(report("dalvik/system/DexClassLoader" to "other")))
        assertNull(CompatibilityAssessment.impossibleReason(report("android/widget/TextView" to "provider")))
    }

    @Test fun `missing members read as Class dot member`() {
        assertEquals("Context.bindService()", RepositoryService.readableHostSymbol("android/content/Context.bindService(Landroid/content/Intent;)Z"))
        assertEquals("Context.NO_SUCH", RepositoryService.readableHostSymbol("android/content/Context.NO_SUCH:I"))
        assertEquals("Builder.build()", RepositoryService.readableHostSymbol("android/net/Uri\$Builder.build()Landroid/net/Uri;"))
        assertEquals("android.webkit.WebView", RepositoryService.readableHostSymbol("android/webkit/WebView"))
    }

    @Test fun `installed extensions list provider names another installed extension also registers`() {
        fun record(id: Char, name: String, providers: List<String>, enabled: Boolean = true) = DaemonState.InstalledExtension(
            id.toString().repeat(64), "https://r$id.invalid/repo.json", name, "c".repeat(64), "g", "d".repeat(64), 0,
            RepositoryService.SitePlugin(name = name, internalName = name), providerNames = providers, enabled = enabled)
        val a = record('a', "MovieBox A", listOf("MovieBox", "Other"))
        val b = record('b', "MovieBox B", listOf("MovieBox"))
        val c = record('c', "Off", listOf("Other"), enabled = false)
        DaemonState.update { it.copy(installations = mapOf(a.id to a, b.id to b, c.id to c)) }
        val shared = RepositoryService.installedPlugin(a.id)!!.sharedProviderNames
        assertEquals(listOf(com.lagradost.macos.models.SharedProviderNameDto("MovieBox", listOf("MovieBox B"))), shared,
            "disabled extensions are not counted")
    }
}
