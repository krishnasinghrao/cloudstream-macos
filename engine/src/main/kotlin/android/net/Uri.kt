package android.net

/**
 * SEC-08: Pure-Java stub for `android.net.Uri`.
 *
 * Community plugins contain `INVOKESTATIC android/net/Uri.parse(...)` bytecode,
 * so the factory methods live as `@JvmStatic` companion forwarders on the
 * abstract class, exactly mirroring the Android SDK surface that scrapers use.
 */
abstract class Uri : Comparable<Uri> {
    abstract val impl: Impl

    data class Impl(
        val raw: String,
        val scheme: String?,
        val authority: String?,
        val host: String?,
        val port: Int,
        val path: String?,
        val query: String?,
        val fragment: String?,
        val queryParameters: List<Pair<String, String>>,
    ) {
        companion object {
            fun from(raw: String): Impl {
                var rest = raw
                val scheme = if (rest.contains("://")) rest.substringBefore("://") else null
                if (scheme != null) rest = rest.substringAfter("://")

                val fragment = rest.substringAfter('#', "").ifBlank { null }
                rest = rest.substringBefore('#')

                val query = rest.substringAfter('?', "").ifBlank { null }
                rest = rest.substringBefore('?')

                val authority = rest.substringBefore('/').ifBlank { null }
                val path = when {
                    rest.contains('/') -> "/" + rest.substringAfter('/')
                    authority != null -> ""
                    else -> rest
                }

                val host = authority?.substringBefore(':')
                val port = authority?.substringAfter(':', "")?.toIntOrNull() ?: -1

                val params = query
                    ?.split('&')
                    ?.filter { it.isNotBlank() }
                    ?.map { Pair(it.substringBefore('='), it.substringAfter('=', "")) }
                    ?: emptyList()

                return Impl(raw, scheme, authority, host, port, path, query, fragment, params)
            }
        }
    }

    fun getScheme(): String = impl.scheme ?: ""
    fun getHost(): String = impl.host ?: ""
    fun getPort(): Int = impl.port
    fun getPath(): String = impl.path ?: ""
    fun getQuery(): String? = impl.query
    fun getFragment(): String? = impl.fragment
    fun getAuthority(): String = impl.authority ?: ""
    fun isHierarchical(): Boolean = impl.path != null || impl.query != null
    fun isOpaque(): Boolean = !isHierarchical()
    fun isAbsolute(): Boolean = impl.scheme != null
    fun isRelative(): Boolean = impl.scheme == null

    /** Decoded value; like Android (API 16+), '+' decodes to a space. */
    fun getQueryParameter(key: String): String? =
        impl.queryParameters.firstOrNull { decodeComponent(it.first, true) == key }?.second?.let { decodeComponent(it, true) }

    fun getQueryParameters(key: String): List<String> =
        impl.queryParameters.filter { decodeComponent(it.first, true) == key }.map { decodeComponent(it.second, true) }

    fun getQueryParameterNames(): Set<String> = impl.queryParameters.map { decodeComponent(it.first, true) }.toCollection(LinkedHashSet())

    fun getLastPathSegment(): String? =
        impl.path?.trimEnd('/')?.takeIf { it.isNotEmpty() }?.substringAfterLast('/')

    fun getPathSegments(): List<String> =
        impl.path?.trim('/')?.split('/')?.filter { it.isNotEmpty() } ?: emptyList()

    fun normalizeScheme(): Uri =
        Uri.parse(toString().replaceFirst(getScheme(), getScheme().lowercase()))

    fun getSchemeSpecificPart(): String? = impl.raw.substringAfter("://", "").substringBefore('#').ifBlank { null }

    fun buildUpon(): Builder = Builder()
        .scheme(impl.scheme)
        .authority(impl.authority)
        .path(impl.path)
        .query(impl.query)
        .fragment(impl.fragment)

    override fun toString(): String = impl.raw

    override fun compareTo(other: Uri): Int = toString().compareTo(other.toString())

    override fun equals(other: Any?): Boolean = other is Uri && other.toString() == toString()

    override fun hashCode(): Int = toString().hashCode()

    companion object {
        const val NULL: String = ""

        @JvmStatic
        fun parse(uriString: String): Uri {
            require(uriString.isNotEmpty()) { "uriString cannot be empty" }
            return object : Uri() {
                override val impl: Impl = Impl.from(uriString)
            }
        }

        @JvmStatic
        fun fromFile(file: java.io.File): Uri = parse("file://${file.absolutePath}")

        private const val UNRESERVED = "_-!.~'()*"

        /** Android Uri.encode: percent-encodes everything except letters, digits and `_-!.~'()*`. */
        @JvmStatic
        fun encode(s: String?): String? = encode(s, null)

        @JvmStatic
        fun encode(s: String?, allow: String?): String? = s?.let { value ->
            buildString {
                for (byte in value.toByteArray(Charsets.UTF_8)) {
                    val c = (byte.toInt() and 0xff).toChar()
                    if (c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c in UNRESERVED || (allow != null && c in allow)) append(c)
                    else append('%').append("0123456789ABCDEF"[(byte.toInt() shr 4) and 0xf]).append("0123456789ABCDEF"[byte.toInt() and 0xf])
                }
            }
        }

        /** Android Uri.decode: percent-decoding only ('+' is kept). */
        @JvmStatic
        fun decode(s: String?): String? = s?.let { decodeComponent(it, false) }

        internal fun decodeComponent(value: String, plusAsSpace: Boolean): String {
            val out = java.io.ByteArrayOutputStream(value.length)
            var i = 0
            while (i < value.length) {
                val c = value[i]
                if (c == '%' && i + 2 < value.length &&
                    value[i + 1].digitToIntOrNull(16) != null && value[i + 2].digitToIntOrNull(16) != null) {
                    out.write(value.substring(i + 1, i + 3).toInt(16)); i += 3; continue
                }
                if (c == '+' && plusAsSpace) out.write(' '.code) else out.write(c.toString().toByteArray(Charsets.UTF_8))
                i++
            }
            return out.toString(Charsets.UTF_8)
        }
    }

    class Builder {
        private var scheme: String? = null
        private var authority: String? = null
        private var path: String? = null
        private var query: String? = null
        private var fragment: String? = null
        private val appendedParams = mutableListOf<Pair<String, String>>()

        fun scheme(scheme: String?): Builder = apply { this.scheme = scheme }
        fun authority(authority: String?): Builder = apply { this.authority = authority }
        fun encodedAuthority(authority: String?): Builder = apply { this.authority = authority }
        fun path(path: String?): Builder = apply { this.path = encode(path, "/") }
        fun encodedPath(path: String?): Builder = apply { this.path = path }

        fun appendPath(segment: String): Builder = apply {
            this.path = ((this.path?.trimEnd('/') ?: "") + "/" + encode(segment))
        }

        fun query(query: String?): Builder = apply { this.query = query }
        fun encodedQuery(query: String?): Builder = apply { this.query = query }
        /** Key and value are encoded, so a value can never alter query structure. */
        fun appendQueryParameter(key: String?, value: String?): Builder = apply {
            appendedParams.add(Pair(encode(key).orEmpty(), encode(value).orEmpty()))
        }

        fun fragment(fragment: String?): Builder = apply { this.fragment = encode(fragment) }
        fun encodedFragment(fragment: String?): Builder = apply { this.fragment = fragment }

        fun clearQuery(): Builder = apply { query = null; appendedParams.clear() }

        fun build(): Uri {
            val out = buildString {
                if (scheme != null) append(scheme).append("://")
                if (authority != null) append(authority)
                if (path != null) append(path)
                val existing = query?.split('&')?.filter { it.isNotBlank() } ?: emptyList()
                val allParams =
                    existing.map { Pair(it.substringBefore('='), it.substringAfter('=', "")) } + appendedParams
                if (allParams.isNotEmpty()) {
                    append('?').append(allParams.joinToString("&") { (k, v) -> "$k=$v" })
                }
                if (fragment != null) append('#').append(fragment)
            }
            return Uri.parse(out)
        }
    }
}
