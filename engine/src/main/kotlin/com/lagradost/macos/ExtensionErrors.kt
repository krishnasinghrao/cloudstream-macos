package com.lagradost.macos

/** Typed, user-presentable extension failures (IPC error `code`). */
class ExtensionException(val code: Code, message: String, cause: Throwable? = null) : Exception(message, cause) {
    enum class Code(val wire: String, val httpStatus: Int) {
        INVALID_REQUEST("invalid_request", 400),
        UNKNOWN_REPOSITORY("unknown_repository", 404),
        UNKNOWN_EXTENSION("unknown_extension", 404),
        CONSENT_REQUIRED("consent_required", 403),
        POLICY_DENIED("policy_denied", 403),
        UNTRUSTED("untrusted", 403),
        DIGEST_REQUIRED("digest_required", 403),
        UNAVAILABLE("unavailable", 409),
        STALE_CATALOG("stale_catalog", 409),
        DOWNGRADE("downgrade", 409),
        NO_PREVIOUS_VERSION("no_previous_version", 409),
        CONFLICT("operation_conflict", 409),
        SAFE_MODE("safe_mode", 409),
        UNSUPPORTED("unsupported", 422),
        LOAD_FAILED("load_failed", 422),
        RECOVERY_REQUIRED("recovery_required", 503),
        DOWNLOAD_FAILED("download_failed", 502),
    }

    companion object {
        /**
         * GitHub's raw file host is blocked on some networks; the jsDelivr
         * setting (N2) is the remedy, so name it — never automatically.
         */
        private fun githubHint(where: String?): String =
            if (where != null && isGitHubAddress(where) && !com.lagradost.macos.network.GitHubMirror.enabled)
                " If GitHub is blocked on your network, turn on Settings ▸ Network ▸ “Download repositories through jsDelivr”."
            else ""

        private fun isGitHubAddress(where: String): Boolean =
            Regex("""(^|[/.@\s“"])(raw\.)?github(usercontent)?\.com\b""", RegexOption.IGNORE_CASE).containsMatchIn(where)

        private const val DNS_HINT = " Your network may be blocking or redirecting it; try another DNS resolver in Settings ▸ Network, or a VPN."

        /**
         * What a failed TLS handshake most likely means, in the user's terms.
         * JSSE exposes the reason only through exception types and messages.
         */
        internal fun tlsMessage(failure: javax.net.ssl.SSLException, host: String?): String {
            val server = host?.let { "“$it”" } ?: "the server"
            val chain = generateSequence<Throwable>(failure) { it.cause }.take(8).toList()
            val text = chain.joinToString(" ") { it.message.orEmpty() }
            return when {
                // The port answered in plain HTTP: the host has no HTTPS at that address.
                text.contains("Unsupported or unrecognized SSL message", true) || text.contains("plaintext connection", true) ->
                    "$server doesn't accept secure (HTTPS) connections, and extensions are only downloaded over HTTPS. The repository's publisher needs to serve it over HTTPS."
                // A certificate for another name: almost always DNS or a network filter redirecting the address.
                failure is javax.net.ssl.SSLPeerUnverifiedException || text.contains("not verified", true) ->
                    "$server answered with a certificate for a different site." + DNS_HINT
                chain.any { it is java.security.cert.CertificateException || it is java.security.cert.CertPathValidatorException } ||
                    text.contains("PKIX path", true) || text.contains("certificate", true) ->
                    "The certificate of $server isn't trusted: it may be expired or self-signed, or a network filter (antivirus, company proxy) may be replacing it."
                else -> "A secure connection to $server couldn't be established." + DNS_HINT
            }
        }

        /** What the server's answer means for the user; the address names which file. */
        private fun remoteMessage(failure: RemoteHttpException): String {
            val where = failure.url?.take(300)?.let { " ($it)" }.orEmpty()
            return when (failure.status) {
                404, 410 -> "The repository's file no longer exists on its server$where. The publisher may have moved or removed it."
                401, 403 -> "The server refused access to the repository's file$where."
                429 -> "The repository's server is limiting requests. Try again in a few minutes."
                in 500..599 -> "The repository's server had an error (HTTP ${failure.status}). Try again later."
                else -> "The repository's server answered with HTTP ${failure.status}$where."
            }
        }

        /** Maps arbitrary failures onto a stable code without leaking internals. */
        fun from(failure: Throwable): ExtensionException = when (failure) {
            is ExtensionException -> failure
            // A transport failure tagged with its address: classify the transport's own exception, then name the host.
            is RepositoryNetworkException -> network(failure.cause, failure.url) ?: from(failure.cause)
            // A deadline is not an operation conflict (TimeoutCancellationException is an IllegalStateException).
            is kotlinx.coroutines.TimeoutCancellationException ->
                ExtensionException(Code.DOWNLOAD_FAILED, "The repository did not respond in time.", failure)
            is PolicyException -> ExtensionException(Code.POLICY_DENIED, failure.message ?: "Blocked by policy", failure)
            is PluginBridge.UnsupportedExtensionException -> ExtensionException(Code.UNSUPPORTED, failure.message ?: "Unsupported extension", failure)
            is SecurityException -> ExtensionException(Code.UNTRUSTED, failure.message ?: "Security check failed", failure)
            // Local files (an artifact, a worker home) are not the network, though both are IOExceptions.
            is java.io.IOException -> if (OperationFailures.isLocalStorageFailure(failure))
                ExtensionException(Code.LOAD_FAILED, "The extension's files on this Mac were missing or could not be read. Try again.", failure)
            else network(failure, null) ?: remoteOrIo(failure)
            is IllegalStateException -> if (DaemonState.recoveryError != null)
                ExtensionException(Code.RECOVERY_REQUIRED, DaemonState.recoveryError.orEmpty(), failure)
            // The transport's own redirect limits (RepositoryTransport), not a state conflict.
            else if (failure.message == "Too many repository redirects" || failure.message == "Repository redirect cycle")
                ExtensionException(Code.DOWNLOAD_FAILED, "The repository's server redirected too many times or in a loop.", failure)
            else ExtensionException(Code.CONFLICT, failure.message ?: "Operation conflict", failure)
            is IllegalArgumentException -> ExtensionException(Code.INVALID_REQUEST, failure.message ?: "Invalid request", failure)
            else -> ExtensionException(Code.LOAD_FAILED, failure.message ?: failure.javaClass.simpleName, failure)
        }

        /** Below-HTTP failures; [url] is the address the request was for, when known. */
        private fun network(failure: java.io.IOException, url: String?): ExtensionException? {
            val host = url?.let { runCatching { java.net.URI(it).host }.getOrNull() }?.takeIf { it.isNotBlank() && it.length <= 253 }
            val hint = githubHint(url ?: failure.message)
            return when (failure) {
                is java.net.UnknownHostException -> ExtensionException(Code.DOWNLOAD_FAILED,
                    "Couldn't find the server${(host ?: failure.message?.substringBefore(':')?.takeIf { it.isNotBlank() && it.length <= 253 })?.let { " “$it”" }.orEmpty()}. Check the address and your internet connection." +
                        hint, failure)
                is java.net.ConnectException, is java.net.NoRouteToHostException -> ExtensionException(Code.DOWNLOAD_FAILED,
                    "Couldn't connect to ${host?.let { "“$it”" } ?: "the server"}. Check your internet connection." + hint, failure)
                is java.net.SocketTimeoutException -> ExtensionException(Code.DOWNLOAD_FAILED,
                    "${host?.let { "“$it”" } ?: "The server"} took too long to respond." + hint, failure)
                is javax.net.ssl.SSLException -> ExtensionException(Code.DOWNLOAD_FAILED, tlsMessage(failure, host) + hint, failure)
                is java.net.SocketException -> if (failure.message?.contains("reset", true) == true)
                    ExtensionException(Code.DOWNLOAD_FAILED, "The connection to ${host?.let { "“$it”" } ?: "the server"} was cut off." + DNS_HINT + hint, failure)
                    else null
                else -> null
            }
        }

        private fun remoteOrIo(failure: java.io.IOException): ExtensionException = when (failure) {
            // A server that answered is reachable: a blocked-network hint fits only a refusal.
            is RemoteHttpException -> ExtensionException(Code.DOWNLOAD_FAILED,
                remoteMessage(failure) + (if (failure.status == 403) githubHint(failure.url) else ""), failure)
            else -> ExtensionException(Code.DOWNLOAD_FAILED, failure.message ?: "Network or storage failure", failure)
        }
    }
}
