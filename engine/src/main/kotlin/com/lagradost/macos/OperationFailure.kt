package com.lagradost.macos

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.macos.models.OperationFailureDto
import com.lagradost.macos.worker.WorkerFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import java.util.UUID

internal class OperationException(val failure: OperationFailureDto, cause: Throwable? = null) : RuntimeException(failure.publicMessage, cause)
internal class ProviderNoDataException : RuntimeException()
/** A non-success HTTP answer; [url] is the address that answered, when known. */
internal class RemoteHttpException(val status: Int, val url: String? = null) :
    java.io.IOException("HTTP $status" + (url?.let { " from $it" } ?: ""))
/** Too many extension processes or routed extractions are busy to admit more work. */
internal class WorkerCapacityException : RuntimeException()

internal object OperationFailures {
    fun capture(provider: MainAPI?, operation: String, thrown: Throwable, elapsedMs: Long = 0): OperationException {
        if (thrown is OperationException) return thrown
        if (thrown is WorkerFailure && thrown.failure != null) return OperationException(thrown.failure, thrown)
        if (thrown is CancellationException && thrown !is TimeoutCancellationException) throw thrown
        if (thrown is VirtualMachineError && thrown !is StackOverflowError) throw thrown
        val causes = generateSequence(thrown) { it.cause }.take(12).toList()
        val linkage = causes.filterIsInstance<LinkageError>().firstOrNull(::isHostLinkage)
        val remote = causes.filterIsInstance<RemoteHttpException>().firstOrNull()
        val code = when {
            causes.any { it is RejectedMediaResourceException } -> "rejected_media_resource"
            linkage != null -> linkageCode(linkage)
            causes.any { it is PluginBridge.UnsupportedExtensionException || it is NotImplementedError } -> "unsupported_capability"
            thrown is TimeoutCancellationException || (thrown is WorkerFailure && thrown.kind == WorkerFailure.Kind.TIMEOUT) -> "timeout"
            thrown is WorkerFailure && thrown.kind == WorkerFailure.Kind.CRASHED ->
                if (thrown.code == WorkerFailure.OUT_OF_MEMORY) "worker_out_of_memory" else "worker_terminated"
            thrown is ProviderNoDataException -> "provider_no_data"
            causes.any { it is WorkerCapacityException } -> "capacity"
            remote != null -> "remote_http_failure"
            else -> causes.firstOrNull { it is java.io.IOException }?.let(::networkCode) ?: "provider_failure"
        }
        val stage = when {
            operation.startsWith("getMainPage") -> "home"
            operation in setOf("load", "mapDetails") -> "details"
            operation == "loadLinks" -> "extraction"
            operation == "init" -> "initialization"
            else -> operation
        }
        val message = when (code) {
            "rejected_media_resource" -> "The provider returned an unsupported or invalid media resource."
            "missing_host_class" -> "This extension needs part of Android or the CloudStream app that the Mac version does not provide."
            "missing_host_member" -> "This extension calls a function the Mac version of CloudStream does not provide."
            "translation_rejected" -> "This extension's code could not be converted to run on Mac."
            "host_abi_mismatch" -> "This extension was built against a different version of the CloudStream API."
            "unsupported_capability" -> "This extension requires a capability that is unavailable for this operation."
            "timeout" -> "The extension did not finish this operation in time."
            "worker_terminated" -> "The extension process stopped while handling this operation."
            "worker_out_of_memory" -> "The extension ran out of memory while handling this operation."
            "provider_no_data" -> "The provider returned no data for this operation."
            "capacity" -> "Too many extensions are busy right now. Try again shortly."
            "remote_http_failure" -> "The provider's server returned HTTP ${remote!!.status}."
            "dns_failure" -> "The provider's server address could not be found. The site may be blocked on your network; try another DNS server in Settings ▸ Network, or a VPN."
            "tls_failure" -> "A secure connection to the provider's server could not be established."
            "network_timeout" -> "The provider's server did not respond in time."
            "connection_refused" -> "The provider's server refused the connection. The site may be down."
            "connection_reset" -> "The connection to the provider's server was cut off. The site may be blocking this network; a VPN may help."
            "network_failure" -> "The provider could not connect to its server."
            else -> "The extension failed during $stage."
        }
        // Linkage messages can contain URLs or user data. Extract only the
        // class/member token that identifies a missing ABI, then bound it.
        val symbol = linkage?.message?.let {
            Regex("[A-Za-z_$][A-Za-z0-9_$]*(?:[./][A-Za-z_$][A-Za-z0-9_$-]*)+").find(it)?.value?.take(240)
        }
        val providerId = provider?.let(PluginBridge::providerId)
        return OperationException(OperationFailureDto(code, stage, UUID.randomUUID().toString(), message,
            retryable = code in RETRYABLE || remote?.status?.let { it == 429 || it >= 500 } == true,
            installationId = provider?.sourcePlugin, providerId = providerId,
            redactedCause = symbol ?: thrown.javaClass.simpleName.take(80), remoteStatus = remote?.status, elapsedMs = elapsedMs.coerceAtLeast(0)), thrown)
    }

    /**
     * The provider answered, but only with links the Mac app cannot play
     * (torrent or protected by DRM it cannot decrypt). Not a provider bug and
     * not retryable: say what was offered instead of "no data".
     */
    fun unsupportedSources(provider: MainAPI?, skipped: List<com.lagradost.macos.models.SkippedLinkDto>): OperationFailureDto {
        val reasons = skipped.map { it.reason }.toSet()
        if (reasons == setOf("invalid")) {
            // Only malformed links: the provider's bug, reported as before.
            return capture(provider, "loadLinks", RejectedMediaResourceException("url")).failure
        }
        val what = when {
            reasons == setOf("torrent") -> "torrent sources, which aren't supported on Mac"
            reasons == setOf("drm") -> "DRM-protected sources, which can't be played on Mac"
            reasons.all { it == "torrent" || it == "drm" } -> "torrent or DRM-protected sources, which aren't supported on Mac"
            else -> "sources the Mac app can't play"
        }
        return OperationFailureDto("unsupported_sources", "extraction", UUID.randomUUID().toString(),
            "This provider only offered $what.", retryable = false,
            installationId = provider?.sourcePlugin, providerId = provider?.let(PluginBridge::providerId),
            redactedCause = reasons.sorted().joinToString(","), remoteStatus = null, elapsedMs = 0)
    }

    fun status(failure: OperationFailureDto): Int = when (failure.code) {
        in INCOMPATIBLE, "unsupported_capability", "rejected_media_resource", "unsupported_sources" -> 422
        "timeout" -> 504
        "worker_terminated", "worker_out_of_memory", "capacity" -> 503
        "provider_no_data" -> 404
        else -> 502
    }

    /** Codes that mean the extension's code does not fit this host (formerly one `runtime_incompatibility`). */
    val INCOMPATIBLE = setOf("missing_host_class", "missing_host_member", "translation_rejected", "host_abi_mismatch")
    private val RETRYABLE = setOf("timeout", "worker_terminated", "worker_out_of_memory", "capacity", "network_failure",
        "dns_failure", "network_timeout", "connection_refused", "connection_reset")

    /**
     * Linkage errors that describe this host's API surface. An extension's own
     * static initializer failing ([ExceptionInInitializerError], or the later
     * "Could not initialize class" [NoClassDefFoundError]) is the extension's
     * bug, not a missing host type, so it is classified by its cause instead.
     */
    private fun isHostLinkage(error: LinkageError): Boolean =
        error !is ExceptionInInitializerError &&
            !(error is NoClassDefFoundError && error.message?.startsWith("Could not initialize class") == true)

    internal fun linkageCode(error: LinkageError): String = when (error) {
        is NoClassDefFoundError -> "missing_host_class"
        is NoSuchMethodError, is NoSuchFieldError, is AbstractMethodError -> "missing_host_member"
        // dex2jar output the verifier refuses, or a malformed/too-new class file.
        is VerifyError, is ClassFormatError -> "translation_rejected"
        else -> "host_abi_mismatch"
    }

    private fun networkCode(error: Throwable): String = when (error) {
        is java.net.UnknownHostException -> "dns_failure"
        is javax.net.ssl.SSLException -> "tls_failure"
        is java.net.SocketTimeoutException -> "network_timeout"
        is java.net.ConnectException -> if (error.message?.contains("timed out", ignoreCase = true) == true) "network_timeout" else "connection_refused"
        is java.net.SocketException -> if (error.message?.contains("reset", ignoreCase = true) == true) "connection_reset" else "network_failure"
        is java.io.InterruptedIOException -> if (error.message == "timeout") "network_timeout" else "network_failure"
        else -> "network_failure"
    }
}

internal object OperationBudget {
    const val DEFAULT_MS = 120_000L
    const val WORKER_MARGIN_MS = 2_000L
    fun forHint(hint: Long?): Long = (hint ?: DEFAULT_MS).coerceIn(5_000L, 480_000L)
}
