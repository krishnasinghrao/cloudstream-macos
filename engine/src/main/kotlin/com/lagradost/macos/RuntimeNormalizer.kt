package com.lagradost.macos

/**
 * Single source of truth for converting provider-reported runtimes to minutes.
 *
 * Providers are third-party plugins and disagree on units: `LoadResponse.duration`
 * is documented as minutes, `Episode.runTime` as seconds, yet the Android app
 * renders `runTime` as minutes and many plugins follow that. Clients receive only
 * normalized minutes (or null) and must not re-interpret the value.
 */
internal object RuntimeNormalizer {
    /** Longest runtime accepted as a single title/episode (6h). */
    const val MAX_MINUTES = 6 * 60

    /**
     * Returns the runtime in whole minutes, or null when it is missing or cannot
     * be a real runtime in either unit. Values above [MAX_MINUTES] are read as
     * seconds. Values at or below it are taken as minutes: a seconds value that
     * small (a clip under 6 minutes) is indistinguishable, which is why playback
     * UI uses the engine-reported duration rather than this metadata.
     */
    fun minutes(raw: Int?): Int? {
        if (raw == null || raw <= 0) return null
        if (raw <= MAX_MINUTES) return raw
        val fromSeconds = (raw + 30) / 60
        return fromSeconds.takeIf { it in 1..MAX_MINUTES }
    }
}
