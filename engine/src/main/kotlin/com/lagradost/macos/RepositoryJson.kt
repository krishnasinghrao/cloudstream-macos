package com.lagradost.macos

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

/** Validate bounded structure before the general decoder allocates a tree.
 * Decoded object keys must be unique, including differently escaped spellings. */
internal object RepositoryJson {
    fun parse(text: String, maxDocumentChars: Int = RepositoryTransport.MAX_LIST_BYTES, maxStringChars: Int = 65_536): JsonElement {
        require(maxDocumentChars in 1..RepositoryTransport.MAX_RESPONSE_BYTES && maxStringChars in 1..maxDocumentChars)
        Validator(text, maxDocumentChars, maxStringChars).validate()
        return Json.parseToJsonElement(text)
    }

    private class Validator(val text: String, val maxDocumentChars: Int, val maxStringChars: Int) {
        var position = 0
        var nodes = 0
        fun validate() {
            require(text.length <= maxDocumentChars) { "JSON document exceeds limit" }
            value(0)
            space()
            require(position == text.length) { "Trailing JSON content" }
        }

        private fun space() { while (position < text.length && text[position] in " \t\n\r") position++ }
        private fun take(c: Char): Boolean {
            space()
            return if (position < text.length && text[position] == c) { position++; true } else false
        }
        private fun expect(c: Char) { require(take(c)) { "Expected JSON delimiter" } }

        private fun value(depth: Int) {
            require(depth <= 32 && ++nodes <= 100_000) { "JSON structure exceeds limit" }
            space()
            require(position < text.length) { "Truncated JSON" }
            when (text[position]) {
                '{' -> {
                    position++
                    val keys = HashSet<String>()
                    if (take('}')) return
                    do {
                        space()
                        val key = string(256)
                        require(keys.size < 256 && keys.add(key)) { "Duplicate JSON key or too many object members" }
                        expect(':'); value(depth + 1)
                    } while (take(','))
                    expect('}')
                }
                '[' -> {
                    position++
                    var count = 0
                    if (take(']')) return
                    do { require(++count <= 10_000) { "JSON array exceeds limit" }; value(depth + 1) } while (take(','))
                    expect(']')
                }
                '"' -> string(maxStringChars)
                't' -> literal("true")
                'f' -> literal("false")
                'n' -> literal("null")
                else -> {
                    val start = position
                    while (position < text.length && text[position] in "-+0123456789.eE") position++
                    require(position - start in 1..64 && NUMBER.matches(text.substring(start, position))) { "Invalid JSON number" }
                }
            }
        }

        private fun literal(value: String) {
            require(text.startsWith(value, position)) { "Invalid JSON literal" }
            position += value.length
        }

        private fun string(limit: Int): String {
            require(position < text.length && text[position] == '"') { "Expected JSON string" }
            val start = position++
            var escaped = false
            var closed = false
            while (position < text.length) {
                val c = text[position++]
                require(position - start <= limit * 6 + 2 && c.code >= 32) { "JSON string exceeds limit or contains a control" }
                if (!escaped && c == '"') { closed = true; break }
                escaped = !escaped && c == '\\'
            }
            require(closed) { "Unterminated JSON string" }
            val value = Json.decodeFromString<String>(text.substring(start, position))
            require(value.length <= limit) { "JSON string exceeds limit" }
            value.forEachIndexed { index, c ->
                if (c.isHighSurrogate()) require(index + 1 < value.length && value[index + 1].isLowSurrogate()) { "Invalid Unicode" }
                if (c.isLowSurrogate()) require(index > 0 && value[index - 1].isHighSurrogate()) { "Invalid Unicode" }
            }
            return value
        }
    }

    private val NUMBER = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")
}
