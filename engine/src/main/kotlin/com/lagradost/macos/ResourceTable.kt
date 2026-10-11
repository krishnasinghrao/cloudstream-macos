package com.lagradost.macos

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Reader for a compiled Android resource table (`resources.arsc`, plan RT-13).
 * Bounded and defensive: every offset is checked against its chunk, counts and
 * sizes are capped, and a malformed table fails as a whole instead of yielding
 * partial values. It resolves what extensions read outside Android UI —
 * identifiers and names, strings, string/int arrays, integers, booleans and
 * colors — choosing the default configuration (no language) first, then
 * English, then the first available.
 */
internal class ResourceTable private constructor(
    private val packages: Map<Int, Package>,
) {
    sealed interface Value {
        data class Text(val value: String) : Value
        /** Integer-like data (int, hex, boolean, color) with its Android value type. */
        data class Data(val type: Int, val data: Int) : Value
        data class Reference(val id: Int) : Value
        data class Bag(val items: List<Value>) : Value
        data object Other : Value
    }

    private class Entry(val key: String, val value: Value, val language: String)
    private class Type(val name: String, val entries: MutableMap<Int, MutableList<Entry>> = HashMap())
    private class Package(val id: Int, val name: String, val types: MutableMap<Int, Type> = HashMap())

    fun packageNames(): Set<String> = packages.values.mapTo(HashSet()) { it.name }

    /** Android's getIdentifier: `name`, `type/name` or `package:type/name`; 0 when absent. */
    fun identifier(name: String, defType: String?, defPackage: String?): Int {
        var rest = name.removePrefix("@")
        val packageName = rest.substringBefore(':', defPackage ?: "").ifEmpty { null }
        rest = rest.substringAfter(':')
        val type = if ('/' in rest) rest.substringBefore('/') else defType ?: return 0
        val entry = rest.substringAfter('/')
        for (pkg in packages.values) {
            if (packageName != null && pkg.name != packageName) continue
            val (typeId, t) = pkg.types.entries.firstOrNull { it.value.name == type }?.toPair() ?: continue
            val index = t.entries.entries.firstOrNull { (_, list) -> list.any { it.key == entry } }?.key ?: continue
            return (pkg.id shl 24) or (typeId shl 16) or index
        }
        return 0
    }

    private fun lookup(id: Int): Pair<Package, Pair<Type, Entry>>? {
        val pkg = packages[id ushr 24 and 0xff] ?: return null
        val type = pkg.types[id ushr 16 and 0xff] ?: return null
        val candidates = type.entries[id and 0xffff] ?: return null
        val chosen = candidates.firstOrNull { it.language.isEmpty() } ?: candidates.firstOrNull { it.language == "en" } ?: candidates.first()
        return pkg to (type to chosen)
    }

    /** The value of [id], following references (bounded). Null when absent. */
    fun value(id: Int): Value? {
        var current = id
        repeat(MAX_REFERENCE_DEPTH) {
            val value = lookup(current)?.second?.second?.value ?: return null
            if (value !is Value.Reference) return value
            current = value.id
        }
        return null
    }

    /** `package:type/entry`, or null when absent. */
    fun name(id: Int): Triple<String, String, String>? = lookup(id)?.let { (pkg, entry) -> Triple(pkg.name, entry.first.name, entry.second.key) }

    companion object {
        const val MAX_TABLE_BYTES = 16 * 1024 * 1024
        private const val MAX_STRINGS = 200_000
        private const val MAX_STRING_CHARS = 64 * 1024
        private const val MAX_ENTRIES_PER_TYPE = 65_536
        private const val MAX_BAG_ITEMS = 10_000
        private const val MAX_REFERENCE_DEPTH = 16

        private const val RES_STRING_POOL = 0x0001
        private const val RES_TABLE = 0x0002
        private const val RES_TABLE_PACKAGE = 0x0200
        private const val RES_TABLE_TYPE = 0x0201
        private const val RES_TABLE_TYPE_SPEC = 0x0202
        private const val RES_TABLE_LIBRARY = 0x0203

        const val TYPE_REFERENCE = 0x01
        const val TYPE_STRING = 0x03
        const val TYPE_INT_BOOLEAN = 0x12

        /** Parses [bytes]; throws [IllegalArgumentException] on any malformed or oversized structure. */
        fun parse(bytes: ByteArray): ResourceTable = try {
            parseChecked(bytes)
        } catch (outside: IndexOutOfBoundsException) {
            // Backstop: a read the explicit checks missed still fails as a malformed table.
            throw IllegalArgumentException("Malformed resource table", outside)
        } catch (outside: java.nio.BufferUnderflowException) {
            throw IllegalArgumentException("Malformed resource table", outside)
        }

        private fun parseChecked(bytes: ByteArray): ResourceTable {
            require(bytes.size in 12..MAX_TABLE_BYTES) { "Resource table size is invalid" }
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val (type, headerSize, size) = header(buffer, 0, bytes.size)
            require(type == RES_TABLE && size == bytes.size) { "Not a resource table" }
            var globalStrings: List<String> = emptyList()
            val packages = HashMap<Int, Package>()
            var offset = headerSize
            while (offset < size) {
                val (chunkType, _, chunkSize) = header(buffer, offset, size)
                when (chunkType) {
                    RES_STRING_POOL -> globalStrings = strings(buffer, offset, chunkSize)
                    RES_TABLE_PACKAGE -> packageChunk(buffer, offset, chunkSize, globalStrings).let {
                        require(packages.put(it.id, it) == null) { "Duplicate resource package" }
                    }
                }
                offset += chunkSize
            }
            return ResourceTable(packages)
        }

        /** Validated chunk header at [offset] within [limit]: type, header size, total size. */
        private fun header(buffer: ByteBuffer, offset: Int, limit: Int): Triple<Int, Int, Int> {
            require(offset >= 0 && offset + 8 <= limit) { "Truncated resource chunk" }
            val type = buffer.getShort(offset).toInt() and 0xffff
            val headerSize = buffer.getShort(offset + 2).toInt() and 0xffff
            val size = buffer.getInt(offset + 4)
            require(headerSize >= 8 && size >= headerSize && offset.toLong() + size <= limit) { "Malformed resource chunk" }
            return Triple(type, headerSize, size)
        }

        private fun strings(buffer: ByteBuffer, start: Int, size: Int): List<String> {
            // ResStringPool_header is 28 bytes: count, style count, flags, strings and styles offsets.
            val headerSize = buffer.getShort(start + 2).toInt() and 0xffff
            require(size >= 28 && headerSize >= 28 && headerSize <= size) { "Malformed string pool" }
            val count = buffer.getInt(start + 8)
            val flags = buffer.getInt(start + 16)
            val stringsStart = buffer.getInt(start + 20)
            require(count in 0..MAX_STRINGS && stringsStart in 0..size) { "Malformed string pool" }
            val utf8 = flags and 0x100 != 0
            require(headerSize.toLong() + count * 4L <= size) { "Malformed string pool" }
            return List(count) { index ->
                val at = start + stringsStart + buffer.getInt(start + headerSize + index * 4)
                require(at in start until start + size) { "String outside its pool" }
                if (utf8) utf8String(buffer, at, start + size) else utf16String(buffer, at, start + size)
            }
        }

        private fun utf8String(buffer: ByteBuffer, at: Int, end: Int): String {
            var position = at
            fun length(): Int {
                require(position < end) { "Truncated string" }
                val first = buffer.get(position++).toInt() and 0xff
                if (first and 0x80 == 0) return first
                require(position < end) { "Truncated string" }
                return (first and 0x7f shl 8) or (buffer.get(position++).toInt() and 0xff)
            }
            length() // UTF-16 length, unused
            val bytes = length()
            require(bytes <= MAX_STRING_CHARS * 4 && position + bytes <= end) { "String exceeds its pool" }
            return String(ByteArray(bytes) { buffer.get(position + it) }, Charsets.UTF_8)
        }

        private fun utf16String(buffer: ByteBuffer, at: Int, end: Int): String {
            var position = at
            require(position + 2 <= end) { "Truncated string" }
            var chars = buffer.getShort(position).toInt() and 0xffff
            position += 2
            if (chars and 0x8000 != 0) {
                require(position + 2 <= end) { "Truncated string" }
                chars = (chars and 0x7fff shl 16) or (buffer.getShort(position).toInt() and 0xffff)
                position += 2
            }
            require(chars <= MAX_STRING_CHARS && position + chars * 2L <= end) { "String exceeds its pool" }
            return String(CharArray(chars) { buffer.getChar(position + it * 2) })
        }

        private fun packageChunk(buffer: ByteBuffer, start: Int, size: Int, globals: List<String>): Package {
            val headerSize = buffer.getShort(start + 2).toInt() and 0xffff
            require(headerSize >= 8 + 4 + 256 + 16 && headerSize <= size) { "Malformed resource package" }
            val id = buffer.getInt(start + 8)
            require(id in 1..0xff) { "Invalid resource package id" }
            val name = String(CharArray(128) { buffer.getChar(start + 12 + it * 2) }).substringBefore('\u0000')
            val typeStringsOffset = buffer.getInt(start + 12 + 256)
            val keyStringsOffset = buffer.getInt(start + 12 + 256 + 8)
            val typeNames = strings(buffer, start + typeStringsOffset, header(buffer, start + typeStringsOffset, start + size).third)
            val keys = strings(buffer, start + keyStringsOffset, header(buffer, start + keyStringsOffset, start + size).third)
            val pkg = Package(id, name)
            var offset = start + headerSize
            while (offset < start + size) {
                val (type, _, chunkSize) = header(buffer, offset, start + size)
                if (type == RES_TABLE_TYPE) typeChunk(buffer, offset, chunkSize, pkg, typeNames, keys, globals)
                else require(type in setOf(RES_STRING_POOL, RES_TABLE_TYPE_SPEC, RES_TABLE_LIBRARY) || type >= 0x0204) { "Unexpected chunk in resource package" }
                offset += chunkSize
            }
            return pkg
        }

        private fun typeChunk(buffer: ByteBuffer, start: Int, size: Int, pkg: Package,
            typeNames: List<String>, keys: List<String>, globals: List<String>) {
            val headerSize = buffer.getShort(start + 2).toInt() and 0xffff
            // ResTable_type: id, flags, reserved, entry count (+12) and entries start (+16) precede the config.
            require(headerSize >= 20 && headerSize <= size) { "Malformed resource type" }
            val typeId = buffer.get(start + 8).toInt() and 0xff
            val flags = buffer.get(start + 9).toInt() and 0xff
            val entryCount = buffer.getInt(start + 12)
            val entriesStart = buffer.getInt(start + 16)
            require(typeId in 1..typeNames.size && entryCount in 0..MAX_ENTRIES_PER_TYPE && entriesStart in headerSize..size) { "Malformed resource type" }
            // ResTable_config begins at +20: size(4) mcc(2) mnc(2) language[2] country[2].
            val language = if (headerSize >= 20 + 12) {
                val a = buffer.get(start + 28).toInt() and 0xff
                val b = buffer.get(start + 29).toInt() and 0xff
                if (a == 0) "" else if (a and 0x80 == 0) "${a.toChar()}${b.toChar()}" else "packed"
            } else ""
            val type = pkg.types.getOrPut(typeId) { Type(typeNames[typeId - 1]) }
            val sparse = flags and 0x01 != 0
            val offset16 = flags and 0x02 != 0
            val indexBytes = if (sparse || !offset16) 4 else 2
            require(headerSize.toLong() + entryCount.toLong() * indexBytes <= size) { "Malformed resource type index" }
            for (slot in 0 until entryCount) {
                val at = start + headerSize + slot * indexBytes
                val (index, relative) = when {
                    sparse -> (buffer.getShort(at).toInt() and 0xffff) to (buffer.getShort(at + 2).toInt() and 0xffff) * 4
                    offset16 -> slot to (buffer.getShort(at).toInt() and 0xffff).let { if (it == 0xffff) -1 else it * 4 }
                    else -> slot to buffer.getInt(at)
                }
                if (relative == -1) continue
                val entryAt = start + entriesStart + relative
                require(entryAt >= start && entryAt + 8 <= start + size) { "Resource entry outside its type" }
                type.entries.getOrPut(index) { mutableListOf() } += entry(buffer, entryAt, start + size, keys, globals).let { (key, value) ->
                    Entry(key, value, language)
                }
            }
        }

        private fun entry(buffer: ByteBuffer, at: Int, end: Int, keys: List<String>, globals: List<String>): Pair<String, Value> {
            val entrySize = buffer.getShort(at).toInt() and 0xffff
            val flags = buffer.getShort(at + 2).toInt() and 0xffff
            if (flags and 0x08 != 0) { // FLAG_COMPACT: key in the size field, type in the high flag byte, data inline
                val key = keys.getOrNull(entrySize) ?: throw IllegalArgumentException("Invalid resource key")
                return key to simple(flags ushr 8, buffer.getInt(at + 4), globals)
            }
            val key = keys.getOrNull(buffer.getInt(at + 4)) ?: throw IllegalArgumentException("Invalid resource key")
            if (flags and 0x01 == 0) {
                require(at + entrySize + 8 <= end) { "Truncated resource value" }
                val valueAt = at + entrySize
                return key to simple(buffer.get(valueAt + 3).toInt() and 0xff, buffer.getInt(valueAt + 4), globals)
            }
            require(entrySize >= 16 && at + 16 <= end) { "Truncated resource bag" }
            val count = buffer.getInt(at + 12)
            require(count in 0..MAX_BAG_ITEMS && at + entrySize + count * 12L <= end) { "Malformed resource bag" }
            return key to Value.Bag(List(count) { item ->
                val valueAt = at + entrySize + item * 12 + 4
                simple(buffer.get(valueAt + 3).toInt() and 0xff, buffer.getInt(valueAt + 4), globals)
            })
        }

        private fun simple(type: Int, data: Int, globals: List<String>): Value = when (type) {
            TYPE_STRING -> Value.Text(globals.getOrNull(data) ?: throw IllegalArgumentException("Invalid resource string"))
            TYPE_REFERENCE -> if (data == 0) Value.Other else Value.Reference(data)
            in 0x10..0x1f -> Value.Data(type, data)
            else -> Value.Other
        }
    }
}
