package com.lagradost.macos

import kotlinx.coroutines.runBlocking
import kotlin.test.*

/** Organization policy matching (audit M5) and the fail-closed sandbox default (L6). */
class ExtensionPolicyTest {
    @AfterTest fun after() = DaemonRuntime.resetForTest()

    @Test fun `a blocked repository cannot be reached by another spelling of its address (M5)`() {
        val policy = ExtensionPolicy(blockedRepositories = listOf("https://evil.example/repo.json"))
        for (spelling in listOf(
            "https://evil.example/repo.json",
            "https://EVIL.example/repo.json",
            "https://evil.example:443/repo.json",
            "https://evil.example/repo.json?x",
            "https://evil.example/repo.json#fragment",
            "https://evil.example/./repo.json",
            "https://evil.example/a/../repo.json",
            "http://evil.example/repo.json",
            "https://evil.example./repo.json",
            " https://evil.example/repo.json ",
        )) {
            assertFalse(policy.repositoryAllowed(spelling), "'$spelling' must be blocked")
            assertTrue(policy.addressBlocked(spelling), "'$spelling' must be blocked on any hop")
        }
        assertTrue(policy.repositoryAllowed("https://evil.example/other.json"), "a path entry blocks only that path")
        assertTrue(policy.repositoryAllowed("https://good.example/repo.json"))
    }

    @Test fun `a host entry blocks the host, its subdomains and every path`() {
        val policy = ExtensionPolicy(blockedRepositories = listOf("evil.example"))
        assertFalse(policy.repositoryAllowed("https://evil.example/any/repo.json"))
        assertFalse(policy.repositoryAllowed("https://cdn.evil.example/repo.json"))
        assertFalse(policy.repositoryAllowed("https://evil.example:8443/repo.json"))
        assertTrue(policy.repositoryAllowed("https://notevil.example/repo.json"), "only real subdomains match")
        val prefix = ExtensionPolicy(blockedRepositories = listOf("https://host.example/team/"))
        assertFalse(prefix.repositoryAllowed("https://host.example/team/repo.json"))
        assertFalse(prefix.repositoryAllowed("https://host.example/team"))
        assertTrue(prefix.repositoryAllowed("https://host.example/teammate/repo.json"), "prefixes match whole segments")
    }

    @Test fun `allow lists and pinned keys use the same canonical form, and unreadable addresses fail closed`() {
        val policy = ExtensionPolicy(allowedRepositories = listOf("https://Good.Example:443/repo.json"),
            pinnedRepositoryKeys = mapOf("https://good.example/repo.json" to "key"), allowUserRepositories = false)
        assertTrue(policy.repositoryAllowed("https://good.example/repo.json?cache=1"))
        assertEquals("key", policy.pinnedKeyFor("https://GOOD.example/repo.json"))
        policy.requireRepository("https://good.example/repo.json", userInitiated = true)
        assertFailsWith<PolicyException> { policy.requireRepository("https://other.example/repo.json", userInitiated = true) }
        assertFalse(policy.repositoryAllowed("not a url at all"))
        assertTrue(ExtensionPolicy(blockedRepositories = listOf("x.example")).addressBlocked("::not-a-url::"))
    }

    @Test fun `the developer source keeps its literal policy`() {
        assertTrue(ExtensionPolicy().repositoryAllowed(DaemonState.DEVELOPER_SOURCE))
        assertTrue(ExtensionPolicy(blockedRepositories = listOf("evil.example")).repositoryAllowed(DaemonState.DEVELOPER_SOURCE))
        assertFalse(ExtensionPolicy(blockedRepositories = listOf(DaemonState.DEVELOPER_SOURCE)).repositoryAllowed(DaemonState.DEVELOPER_SOURCE))
        assertFalse(ExtensionPolicy(allowedRepositories = emptyList()).repositoryAllowed(DaemonState.DEVELOPER_SOURCE))
    }

    @Test fun `a redirect to a blocked host is refused at that hop (M5)`() = runBlocking<Unit> {
        DaemonRuntime.resetForTest(LaunchOptions(ExtensionPolicy(blockedRepositories = listOf("evil.example"))))
        val transport = RepositoryTransport(addressAllowed = { true })
        try {
            val failure = runCatching { transport.fetch("https://evil.example/repo.json", 1024) }.exceptionOrNull()
            assertIs<PolicyException>(failure, "refused before any request is made")
        } finally { transport.close() }
    }

    @Test fun `extensions require the sandbox unless an organization turns that off (L6)`() {
        assertTrue(ExtensionPolicy().requireSandbox)
        assertTrue(LaunchOptions.parse("""{"policy":{},"safeMode":false}""").policy.requireSandbox)
        assertFalse(LaunchOptions.parse("""{"policy":{"requireSandbox":false}}""").policy.requireSandbox)
        assertTrue(LaunchOptions.FAIL_CLOSED.policy.requireSandbox)
    }
}
