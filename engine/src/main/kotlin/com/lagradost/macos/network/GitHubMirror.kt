package com.lagradost.macos.network

import com.lagradost.macos.NetworkSetup

/**
 * Optional jsDelivr mirror for GitHub-hosted repositories (N2), like Android's
 * `convertRawGitUrl` setting: some networks block `raw.githubusercontent.com`
 * while jsDelivr stays reachable. The mirror is a transport detail only. The
 * repository transport keeps the original address as the document's
 * identity, and every signature and SHA-256 check runs on the bytes exactly
 * as before, so a mirror cannot change what is installed.
 *
 * jsDelivr caches branch files for up to 12 hours, so a repository can show
 * an update later through the mirror than directly.
 */
object GitHubMirror {
    private const val HOST = "cdn.jsdelivr.net"
    private val segment = Regex("[A-Za-z0-9_.-]{1,100}")

    val enabled: Boolean get() = NetworkSetup.current.githubMirror

    /** The jsDelivr address for a GitHub raw file, or null when [url] is not one. */
    fun mirrorOf(url: String): String? {
        val parsed = runCatching { java.net.URI(url) }.getOrNull() ?: return null
        if (parsed.scheme != "https" || parsed.rawQuery != null || parsed.rawFragment != null) return null
        val parts = parsed.rawPath.orEmpty().trimStart('/').split('/')
        val (user, repo, rest) = when (parsed.host?.lowercase()) {
            // raw.githubusercontent.com/<user>/<repo>/<ref>/<path…>
            "raw.githubusercontent.com" -> Triple(parts.getOrNull(0), parts.getOrNull(1), parts.drop(2))
            // github.com/<user>/<repo>/raw/<ref>/<path…>
            "github.com" -> if (parts.getOrNull(2) == "raw") Triple(parts[0], parts[1], parts.drop(3)) else return null
            else -> return null
        }
        if (user == null || repo == null || !segment.matches(user) || !segment.matches(repo)) return null
        // "refs/heads/<branch>/…" and "refs/tags/<tag>/…" name the same ref jsDelivr takes as "@<ref>".
        val path = if (rest.firstOrNull() == "refs" && rest.getOrNull(1) in setOf("heads", "tags")) rest.drop(2) else rest
        val ref = path.firstOrNull()?.takeIf { segment.matches(it) } ?: return null
        val file = path.drop(1)
        if (file.isEmpty() || file.any { it.isEmpty() || it == "." || it == ".." }) return null
        return "https://$HOST/gh/$user/$repo@$ref/${file.joinToString("/")}"
    }
}
