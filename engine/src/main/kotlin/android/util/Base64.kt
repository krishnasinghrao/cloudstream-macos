package android.util

/**
 * SEC-08: Pure-Java stub for `android.util.Base64`.
 *
 * All entry points are `@JvmStatic` because community plugins contain
 * `INVOKESTATIC` bytecode compiled against the Android SDK signatures.
 */
object Base64 {
    const val DEFAULT: Int = 0
    const val NO_PADDING: Int = 1
    const val NO_WRAP: Int = 2
    const val CRLF: Int = 4
    const val URL_SAFE: Int = 8
    const val NO_CLOSE: Int = 16

    @JvmStatic
    fun encodeToString(input: ByteArray, flags: Int): String =
        encodeToString(input, 0, input.size, flags)

    @JvmStatic
    fun encodeToString(input: ByteArray, offset: Int, len: Int, flags: Int): String {
        val slice = input.copyOfRange(offset, offset + len)
        var encoded = encoderFor(flags).encodeToString(slice)
        if (flags and NO_PADDING != 0) encoded = encoded.trimEnd('=')
        if (flags and NO_WRAP != 0 || encoded.isEmpty()) return encoded
        // Android wraps at 76 characters and terminates every line, including the last.
        val terminator = if (flags and CRLF != 0) "\r\n" else "\n"
        return encoded.chunked(76).joinToString("") { it + terminator }
    }

    @JvmStatic
    fun encode(input: ByteArray, flags: Int): ByteArray =
        encodeToString(input, flags).toByteArray(Charsets.US_ASCII)

    @JvmStatic
    fun encode(input: ByteArray, offset: Int, len: Int, flags: Int): ByteArray =
        encodeToString(input, offset, len, flags).toByteArray(Charsets.US_ASCII)

    @JvmStatic
    fun decode(str: String, flags: Int): ByteArray {
        // Android ignores whitespace (wrapped input) and accepts missing padding.
        var cleaned = str.filterNot { it == '\n' || it == '\r' || it == ' ' || it == '\t' }
        if (flags and URL_SAFE != 0) {
            cleaned = cleaned.replace('-', '+').replace('_', '/')
        }
        val padded = cleaned.trimEnd('=').let { it.padEnd((it.length + 3) / 4 * 4, '=') }
        return try {
            java.util.Base64.getDecoder().decode(padded)
        } catch (failure: IllegalArgumentException) {
            throw IllegalArgumentException("bad base-64", failure)
        }
    }

    @JvmStatic
    fun decode(input: ByteArray, offset: Int, len: Int, flags: Int): ByteArray =
        decode(String(input, offset, len, Charsets.US_ASCII), flags)

    @JvmStatic
    fun decode(str: ByteArray, flags: Int): ByteArray = decode(String(str, Charsets.US_ASCII), flags)

    private fun encoderFor(flags: Int): java.util.Base64.Encoder =
        if (flags and URL_SAFE != 0) java.util.Base64.getUrlEncoder() else java.util.Base64.getEncoder()
}
