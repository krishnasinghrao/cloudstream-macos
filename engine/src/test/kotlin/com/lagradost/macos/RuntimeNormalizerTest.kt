package com.lagradost.macos

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RuntimeNormalizerTest {

    @Test
    fun `missing or non-positive runtimes are unknown`() {
        assertNull(RuntimeNormalizer.minutes(null))
        assertNull(RuntimeNormalizer.minutes(0))
        assertNull(RuntimeNormalizer.minutes(-5))
    }

    @Test
    fun `minute values pass through`() {
        assertEquals(24, RuntimeNormalizer.minutes(24))
        assertEquals(96, RuntimeNormalizer.minutes(96))
        assertEquals(360, RuntimeNormalizer.minutes(360))
    }

    @Test
    fun `second values are converted to minutes`() {
        assertEquals(13, RuntimeNormalizer.minutes(780)) // 13m clip
        assertEquals(10, RuntimeNormalizer.minutes(597)) // 9:57 video, rounded
        assertEquals(97, RuntimeNormalizer.minutes(5796)) // 1h 36m 36s film
    }

    @Test
    fun `values implausible in either unit are unknown`() {
        assertNull(RuntimeNormalizer.minutes(6 * 3600 + 60)) // > 6h in seconds
        assertNull(RuntimeNormalizer.minutes(Int.MAX_VALUE))
    }
}
