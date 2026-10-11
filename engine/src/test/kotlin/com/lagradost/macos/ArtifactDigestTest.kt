package com.lagradost.macos

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals

class ArtifactDigestTest {
    @Test
    fun `standard vectors use lowercase fixed-width hexadecimal`() {
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ArtifactDigest.sha256(byteArrayOf()))
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ArtifactDigest.sha256("abc".toByteArray()))
    }

    @Test
    fun `file and byte identities agree across streaming buffer boundaries`() {
        val file = Files.createTempFile("artifact-digest", ".bin").toFile()
        try {
            val bytes = ByteArray(32_769) { it.toByte() }
            file.writeBytes(bytes)
            assertEquals(ArtifactDigest.sha256(bytes), ArtifactDigest.sha256(file))
        } finally {
            file.delete()
        }
    }
}
