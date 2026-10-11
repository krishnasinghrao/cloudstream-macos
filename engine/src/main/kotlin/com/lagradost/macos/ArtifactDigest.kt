package com.lagradost.macos

import java.io.File
import java.security.MessageDigest
import java.util.HexFormat

/** SHA-256 identity shared by catalogs, signatures, cached artifacts and proofs. */
internal object ArtifactDigest {
    private val hex = HexFormat.of()

    fun sha256(bytes: ByteArray): String =
        hex.formatHex(MessageDigest.getInstance("SHA-256").digest(bytes))

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(8192)
            var read: Int
            while (stream.read(buffer).also { read = it } != -1) {
                digest.update(buffer, 0, read)
            }
        }
        return hex.formatHex(digest.digest())
    }
}
