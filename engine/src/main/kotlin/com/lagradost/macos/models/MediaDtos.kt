package com.lagradost.macos.models

import kotlinx.serialization.Serializable

@Serializable
data class SearchResultDto(
    val name: String,
    val url: String,
    val provider: String,
    /** Stable provider identity (`<installationId>:<name>`); use it for follow-up requests. */
    val providerId: String? = null,
    val type: String,
    val posterUrl: String? = null,
    val quality: String? = null,
    val score: Int? = null,
    val language: String? = null,
    val episodes: Int? = null,
    val year: Int? = null,
    val isMovie: Boolean = false,
    /** Referer/cookie headers some hosts require to serve the poster (IPC v3). */
    val posterHeaders: Map<String, String>? = null,
)

@Serializable
data class EpisodeDto(
    val data: String,
    val name: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val posterUrl: String? = null,
    val description: String? = null,
    val score: Int? = null,
    val date: Long? = null,
    val runTimeMinutes: Int? = null,
    /** Anime audio variant: "dub" | "sub" | null. */
    val audio: String? = null,
)

@Serializable
data class ActorDto(
    val name: String,
    val role: String? = null,
    val image: String? = null,
    /** Voice actor for animation (IPC v3). */
    val voiceActor: String? = null,
    val voiceActorImage: String? = null,
)

@Serializable
data class DetailsDto(
    val provider: String,
    /** Stable provider identity (`<installationId>:<name>`); use it for follow-up requests. */
    val providerId: String? = null,
    val url: String,
    val name: String,
    val type: String,
    val posterUrl: String? = null,
    val backgroundPosterUrl: String? = null,
    val logoUrl: String? = null,
    val plot: String? = null,
    val year: Int? = null,
    val durationMinutes: Int? = null,
    val score: Int? = null,
    val tags: List<String> = emptyList(),
    val actors: List<ActorDto> = emptyList(),
    val contentRating: String? = null,
    val comingSoon: Boolean = false,
    val episodes: List<EpisodeDto> = emptyList(),
    /** For movies: the data string to hand to /links. */
    val movieData: String? = null,
    // ---- IPC v3: metadata the provider already returned (Offline-Features-Plan Phase 2)
    val recommendations: List<SearchResultDto>? = null,
    val trailers: List<TrailerDto>? = null,
    /** "Ongoing" | "Completed" */
    val showStatus: String? = null,
    val nextAiring: NextAiringDto? = null,
    val seasonNames: List<SeasonNameDto>? = null,
    /** Cross-site identifiers (e.g. "imdb" -> "tt…"); stored only, never called. */
    val syncIds: Map<String, String>? = null,
    val posterHeaders: Map<String, String>? = null,
    /** Stable identity when a provider rotates result URLs. */
    val uniqueUrl: String? = null,
)

@Serializable
data class TrailerDto(
    val url: String,
    val referer: String? = null,
    /** True when [url] is directly playable; false when it needs an extractor. */
    val raw: Boolean = false,
    val headers: Map<String, String> = emptyMap(),
)

@Serializable
data class NextAiringDto(
    val episode: Int,
    /** Unix seconds. */
    val unixTime: Long,
    val season: Int? = null,
)

@Serializable
data class SeasonNameDto(
    val season: Int,
    val name: String? = null,
    val displaySeason: Int? = null,
)

@Serializable
data class AudioTrackDto(
    val url: String,
    val label: String? = null,
    val language: String? = null,
    val headers: Map<String, String> = emptyMap(),
)

@Serializable
data class StreamLinkDto(
    val url: String,
    val name: String,
    val source: String,
    val quality: Int,
    val type: String,
    val headers: Map<String, String> = emptyMap(),
    val extractorData: String? = null,
    val isPlaylist: Boolean = false,
    val playlist: List<String> = emptyList(),
    val audioTracks: List<AudioTrackDto> = emptyList(),
    /** ClearKey decryption for this stream (L4); null for unencrypted streams. */
    val drm: ClearKeyDto? = null,
)

/**
 * A ClearKey content key, hex-encoded for FFmpeg's `decryption_keys`
 * (`kid=key`). [kid] is null when the provider gave only a default key.
 * Widevine, PlayReady and licence-server DRM are never carried: those links
 * are reported in [LinksResponseDto.skipped] instead.
 */
@Serializable
data class ClearKeyDto(
    val kid: String? = null,
    val key: String,
)

/** A link the provider returned that the Mac app does not offer (L3/L4), without its URL. */
@Serializable
data class SkippedLinkDto(
    val source: String,
    val name: String,
    /** `torrent`, `drm` (protected by a DRM system the Mac app cannot use) or `invalid`. */
    val reason: String,
)

@Serializable
data class SubtitleDto(
    val url: String,
    val language: String,
    val label: String? = null,
    val mimeType: String? = null,
)

@Serializable
data class LinksResponseDto(
    val provider: String,
    /** Stable provider identity (`<installationId>:<name>`); use it for follow-up requests. */
    val providerId: String? = null,
    val links: List<StreamLinkDto> = emptyList(),
    val subtitles: List<SubtitleDto> = emptyList(),
    val failures: List<OperationFailureDto> = emptyList(),
    val outcome: String = "success",
    /** Links left out because the Mac app cannot play them (at most [MAX_SKIPPED]). */
    val skipped: List<SkippedLinkDto> = emptyList(),
) {
    companion object { const val MAX_SKIPPED = 64 }
}

/**
 * One NDJSON line of POST /links/stream (Player-Remediation-Plan A2).
 * `link` / `subtitle` events arrive as each extractor produces them; `done`
 * closes the stream; `error` reports an invalid request before any work.
 */
@Serializable
data class LinksStreamEventDto(
    val type: String, // "link" | "subtitle" | "done" | "error"
    val link: StreamLinkDto? = null,
    val subtitle: SubtitleDto? = null,
    val error: String? = null,
    val failures: List<OperationFailureDto> = emptyList(),
    val outcome: String? = null,
    val skipped: List<SkippedLinkDto> = emptyList(),
)

/** POST /links body (replaces GET query params — episode data can be multi-KB). */
@Serializable
data class LinksRequestDto(
    val plugin: String,
    val data: String,
)

/** POST /extract — run the bundled extractors on one URL (trailers; IPC v3). */
@Serializable
data class ExtractRequestDto(
    val url: String,
    val referer: String? = null,
)

/** POST /links/verify/start — run a provider's extractorVerifierJob. */
@Serializable
data class VerifierStartRequestDto(
    val source: String,
    val extractorData: String,
)

@Serializable
data class VerifierStartResponseDto(
    /** Null when no provider/verifier applies (the common case). */
    val jobId: String? = null,
)

@Serializable
data class VerifierStopRequestDto(
    val jobId: String,
)

/** One resource of a relayed split stream: its URL and the headers only it receives. */
@Serializable
data class MediaRelayResourceDto(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
)

/** POST /media/relay — register the resources of one playback session (MediaRelay). */
@Serializable
data class MediaRelayRequestDto(
    val resources: List<MediaRelayResourceDto>,
)

@Serializable
data class MediaRelayResponseDto(
    val sessionId: String,
    /** Listener paths in request order; each is readable without the bearer token. */
    val paths: List<String>,
)

@Serializable
data class MediaRelayRevokeRequestDto(
    val sessionId: String,
)

/** GET /home response: dynamic provider shelves from MainAPI.getMainPage(). */
@Serializable
data class HomePageDto(
    val provider: String,
    /** Stable provider identity (`<installationId>:<name>`); use it for follow-up requests. */
    val providerId: String? = null,
    val page: Int,
    val hasNext: Boolean = false,
    val lists: List<HomePageListDto> = emptyList(),
    val failures: List<OperationFailureDto> = emptyList(),
    val outcome: String = "success",
    /** Links left out because the Mac app cannot play them (at most [MAX_SKIPPED]). */
    val skipped: List<SkippedLinkDto> = emptyList(),
) {
    companion object { const val MAX_SKIPPED = 64 }
}

@Serializable
data class HomePageListDto(
    val name: String,
    val isHorizontal: Boolean,
    val items: List<SearchResultDto> = emptyList(),
)

/**
 * One newline-delimited JSON event of the `/search/stream` NDJSON response.
 * Results stream in per provider: `provider_result` events arrive as each
 * provider completes (5 s cap each), `provider_error` reports failures, and
 * `done` closes the stream.
 */
@Serializable
data class SearchStreamEventDto(
    val type: String, // "provider_result" | "provider_error" | "done"
    val provider: String? = null,
    val providerId: String? = null,
    val results: List<SearchResultDto> = emptyList(),
    val error: String? = null,
    val failure: OperationFailureDto? = null,
)
