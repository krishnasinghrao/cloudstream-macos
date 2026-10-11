package com.lagradost.macos.worker

import com.lagradost.macos.DaemonState
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException

/**
 * Control plane ⇄ worker protocol (ADR-0016): length-prefixed JSON frames on
 * the worker's stdin/stdout, multiplexed by request ID. Control-plane request
 * IDs are positive; worker-initiated requests (`solve`, nested `extract`) use
 * negative IDs.
 */
@Serializable
internal data class Frame(
    val id: Long,
    val type: String,
    val payload: JsonElement = JsonNull,
    /** Set on `error` frames. */
    val error: String? = null,
    /** Machine-readable error kind on `error` frames (e.g. `unsupported`). */
    val code: String? = null,
    val failure: com.lagradost.macos.models.OperationFailureDto? = null,
    val protocolVersion: Int = 2,
)

internal object FrameCodec {
    const val MAX_FRAME_BYTES = 16 * 1024 * 1024
    val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

    fun encode(frame: Frame): ByteArray {
        val bytes = json.encodeToString(Frame.serializer(), frame).toByteArray(Charsets.UTF_8)
        require(bytes.size <= MAX_FRAME_BYTES) { "Frame exceeds ${MAX_FRAME_BYTES} bytes" }
        return bytes
    }

    /** Callers serialize writes on [out]. */
    fun write(out: DataOutputStream, frame: Frame) = write(out, encode(frame))

    fun write(out: DataOutputStream, bytes: ByteArray) {
        out.writeInt(bytes.size)
        out.write(bytes)
        out.flush()
    }

    /** Returns null at end of stream; throws on a malformed or oversized frame. */
    fun read(input: DataInputStream): Frame? {
        val size = try { input.readInt() } catch (_: EOFException) { return null }
        require(size in 0..MAX_FRAME_BYTES) { "Invalid frame length $size" }
        val bytes = ByteArray(size)
        input.readFully(bytes)
        return json.decodeFromString(Frame.serializer(), bytes.toString(Charsets.UTF_8)).also {
            require(it.protocolVersion == 2) { "Incompatible worker protocol" }
        }
    }
}

/** Frame types. */
internal object Op {
    const val INIT = "init"
    const val SEARCH = "search"
    const val HOME = "home"
    const val DETAILS = "details"
    const val LINKS = "links"
    const val EXTRACT = "extract"
    const val VERIFY = "verify"
    const val CONFIGURE = "configure"
    /** Read / edit the extension's own preferences (RT-15). */
    const val PREFS_GET = "prefs_get"
    const val PREFS_SET = "prefs_set"
    const val NETWORK = "network"
    const val CANCEL = "cancel"
    const val SHUTDOWN = "shutdown"
    const val SOLVE = "solve"
    /** Worker-initiated WebViewResolver page load (RT-11). */
    const val MEDIA = "resolve_media"
    /** Worker-initiated operation on an extension-created WebView (RT-14). */
    const val WEBVIEW = "webview"
    const val RESULT = "result"
    const val EVENT = "event"
    const val ERROR = "error"
}

/** Metadata the control plane needs to present and route a provider without running it. */
@Serializable
data class ProviderDescriptor(
    val name: String,
    val mainUrl: String,
    val lang: String = "en",
    val supportedTypes: List<String> = emptyList(),
    val hasMainPage: Boolean = false,
    val hasQuickSearch: Boolean = false,
    val vpnStatus: String = "None",
    val canBeOverridden: Boolean = true,
    val searchTimeoutMs: Long? = null,
    val loadTimeoutMs: Long? = null,
    val loadLinksTimeoutMs: Long? = null,
    val mainPageTimeoutMs: Long? = null,
)

/** An extractor an extension registered; lets the control plane route hosts to it without running it (RT-12). */
@Serializable
data class ExtractorDescriptor(
    val name: String,
    val mainUrl: String,
    val requiresReferer: Boolean = false,
)

@Serializable
internal data class ProviderConfig(val url: String? = null, val credentials: String? = null)

@Serializable
internal data class InitRequest(
    val record: DaemonState.InstalledExtension,
    val artifactPath: String,
    /** Reuse a cached translation only when it matches these digests. */
    val reuseTranslation: Boolean,
    val network: DaemonState.NetworkSettings,
    /** Provider name → clone-site URL / credentials to apply after load. */
    val providerConfig: Map<String, ProviderConfig> = emptyMap(),
    /** The engine's egress proxy: the worker's only route to the network. */
    val egress: EgressSettings? = null,
)

@Serializable
internal data class InitResult(
    val providers: List<ProviderDescriptor>,
    val extractorCount: Int,
    val jarHashes: List<String>,
    val unsupportedFeatures: List<String> = emptyList(),
    val compatibility: com.lagradost.macos.CapabilityReport? = null,
    val extractors: List<ExtractorDescriptor> = emptyList(),
)

@Serializable internal data class SearchRequest(val provider: String, val query: String)
@Serializable internal data class HomeRequest(val provider: String, val page: Int)
@Serializable internal data class DetailsRequest(val provider: String, val url: String)
@Serializable internal data class LinksRequest(val provider: String, val data: String)
/**
 * Runs extractors on one URL. For routed extraction (RT-12) [visited] holds the
 * installations already on the route, [hops] its depth and [budgetMs] the time
 * left; the control plane re-checks all three.
 */
@Serializable
internal data class ExtractRequest(
    val url: String,
    val referer: String? = null,
    val visited: List<String> = emptyList(),
    val hops: Int = 0,
    val budgetMs: Long? = null,
)
@Serializable internal data class VerifyRequest(val provider: String, val data: String)
@Serializable internal data class ConfigureRequest(val provider: String, val url: String? = null, val credentials: String? = null,
    /** Removes the live credential; a null [credentials] alone means unchanged. */
    val clearCredentials: Boolean = false)
@Serializable internal data class CancelRequest(val target: Long)
@Serializable internal data class SolveRequest(val targetUrl: String, val userAgent: String? = null)
@Serializable internal data class SolveResult(val cookies: String? = null)

/** One streamed link or subtitle for a `links` request. */
@Serializable
internal data class LinkEvent(
    val link: com.lagradost.macos.models.StreamLinkDto? = null,
    val subtitle: com.lagradost.macos.models.SubtitleDto? = null,
)

@Serializable
internal data class SearchResponsePayload(val results: List<com.lagradost.macos.models.SearchResultDto>? = null, val error: String? = null,
    val failure: com.lagradost.macos.models.OperationFailureDto? = null)

@Serializable
internal data class DetailsResponsePayload(val details: com.lagradost.macos.models.DetailsDto? = null)
