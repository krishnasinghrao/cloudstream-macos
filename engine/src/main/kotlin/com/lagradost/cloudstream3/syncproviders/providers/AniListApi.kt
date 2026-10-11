package com.lagradost.cloudstream3.syncproviders.providers

import com.fasterxml.jackson.annotation.JsonProperty
import com.lagradost.cloudstream3.syncproviders.SyncAPI

/**
 * Android: syncproviders/providers/AniListApi.kt. No AniList sign-in on macOS:
 * never authenticated. Extensions parse AniList's public API into the nested
 * data classes, so their names, types and JSON keys match the app exactly.
 */
class AniListApi : SyncAPI() {
    override val name = "AniList"
    override val idPrefix = "anilist"

    data class CoverImage(
        @JsonProperty("medium") val medium: String?,
        @JsonProperty("large") val large: String?,
        @JsonProperty("extraLarge") val extraLarge: String?,
    )

    data class LikePageInfo(
        @JsonProperty("total") val total: Int?,
        @JsonProperty("currentPage") val currentPage: Int?,
        @JsonProperty("lastPage") val lastPage: Int?,
        @JsonProperty("perPage") val perPage: Int?,
        @JsonProperty("hasNextPage") val hasNextPage: Boolean?,
    )

    data class MediaCoverImage(
        @JsonProperty("extraLarge") val extraLarge: String?,
        @JsonProperty("large") val large: String?,
        @JsonProperty("medium") val medium: String?,
        @JsonProperty("color") val color: String?,
    )

    data class MediaTitle(
        @JsonProperty("romaji") val romaji: String?,
        @JsonProperty("english") val english: String?,
        @JsonProperty("native") val native: String?,
        @JsonProperty("userPreferred") val userPreferred: String?,
    )

    data class Recommendation(
        @JsonProperty("mediaRecommendation") val mediaRecommendation: RecommendedMedia?,
    )

    data class RecommendationConnection(
        @JsonProperty("edges") val edges: List<RecommendationEdge> = emptyList(),
        @JsonProperty("nodes") val nodes: List<Recommendation> = emptyList(),
    )

    data class RecommendationEdge(
        @JsonProperty("node") val node: Recommendation,
    )

    data class RecommendedMedia(
        @JsonProperty("id") val id: Int?,
        @JsonProperty("title") val title: MediaTitle?,
        @JsonProperty("coverImage") val coverImage: MediaCoverImage?,
    )

    data class SeasonNextAiringEpisode(
        @JsonProperty("episode") val episode: Int?,
        @JsonProperty("timeUntilAiring") val timeUntilAiring: Int?,
    )

    data class Title(
        @JsonProperty("english") val english: String?,
        @JsonProperty("romaji") val romaji: String?,
    )
}
