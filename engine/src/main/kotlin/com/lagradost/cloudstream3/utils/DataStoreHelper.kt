package com.lagradost.cloudstream3.utils

import com.fasterxml.jackson.annotation.JsonProperty
import com.lagradost.cloudstream3.Score
import com.lagradost.cloudstream3.SearchQuality
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.TvType

/**
 * The Android app's watch-history types, as extensions reference them. The
 * Mac app keeps its own history natively; it is not exposed to extensions.
 */
object DataStoreHelper {
    data class PosDur(
        @JsonProperty("position") val position: Long,
        @JsonProperty("duration") val duration: Long,
    )

    data class ResumeWatchingResult(
        @JsonProperty("name") override val name: String,
        @JsonProperty("url") override val url: String,
        @JsonProperty("apiName") override val apiName: String,
        @JsonProperty("type") override var type: TvType? = null,
        @JsonProperty("posterUrl") override var posterUrl: String?,
        @JsonProperty("watchPos") val watchPos: PosDur?,
        @JsonProperty("id") override var id: Int?,
        @JsonProperty("parentId") val parentId: Int?,
        @JsonProperty("episode") val episode: Int?,
        @JsonProperty("season") val season: Int?,
        @JsonProperty("isFromDownload") val isFromDownload: Boolean,
        @JsonProperty("quality") override var quality: SearchQuality? = null,
        @JsonProperty("posterHeaders") override var posterHeaders: Map<String, String>? = null,
        @JsonProperty("score") override var score: Score? = null,
    ) : SearchResponse
}
