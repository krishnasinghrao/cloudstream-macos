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
        /** Maps arbitrary failures onto a stable code without leaking internals. */
        /**
         * GitHub's raw file host is blocked on some networks; the jsDelivr
         * setting (N2) is the remedy, so name it — never automatically.
         */
        private fun githubHint(message: String?): String =
            if (message?.contains("githubusercontent.com") == true && !com.lagradost.macos.network.GitHubMirror.enabled)
                " If GitHub is blocked on your network, turn on Settings ▸ Network ▸ “Download repositories through jsDelivr”."
            else ""

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

        fun from(failure: Throwable): ExtensionException = when (failure) {
            is ExtensionException -> failure
            is PolicyException -> ExtensionException(Code.POLICY_DENIED, failure.message ?: "Blocked by policy", failure)
            is PluginBridge.UnsupportedExtensionException -> ExtensionException(Code.UNSUPPORTED, failure.message ?: "Unsupported extension", failure)
            is SecurityException -> ExtensionException(Code.UNTRUSTED, failure.message ?: "Security check failed", failure)
            is java.net.UnknownHostException -> ExtensionException(Code.DOWNLOAD_FAILED,
                "Couldn't find the server${failure.message?.substringBefore(':')?.takeIf { it.isNotBlank() && it.length <= 253 }?.let { " “$it”" }.orEmpty()}. Check the address and your internet connection." +
                    githubHint(failure.message), failure)
            is java.net.ConnectException, is java.net.NoRouteToHostException -> ExtensionException(Code.DOWNLOAD_FAILED,
                "Couldn't connect to the server. Check your internet connection." + githubHint(failure.message), failure)
            is java.net.SocketTimeoutException -> ExtensionException(Code.DOWNLOAD_FAILED, "The server took too long to respond.", failure)
            is javax.net.ssl.SSLException -> ExtensionException(Code.DOWNLOAD_FAILED, "A secure connection to the server couldn't be established.", failure)
            // A server that answered is reachable: a blocked-network hint fits only a refusal.
            is RemoteHttpException -> ExtensionException(Code.DOWNLOAD_FAILED,
                remoteMessage(failure) + (if (failure.status == 403) githubHint(failure.url) else ""), failure)
            is java.io.IOException -> ExtensionException(Code.DOWNLOAD_FAILED, failure.message ?: "Network or storage failure", failure)
            is IllegalStateException -> if (DaemonState.recoveryError != null)
                ExtensionException(Code.RECOVERY_REQUIRED, DaemonState.recoveryError.orEmpty(), failure)
            else ExtensionException(Code.CONFLICT, failure.message ?: "Operation conflict", failure)
            is IllegalArgumentException -> ExtensionException(Code.INVALID_REQUEST, failure.message ?: "Invalid request", failure)
            else -> ExtensionException(Code.LOAD_FAILED, failure.message ?: failure.javaClass.simpleName, failure)
        }
    }
}
