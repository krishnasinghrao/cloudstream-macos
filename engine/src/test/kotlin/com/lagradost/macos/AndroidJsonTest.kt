package com.lagradost.macos

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import kotlin.test.*

/**
 * A1: extensions compiled for Android call Android's org.json. JSON-java
 * (what NiceHttp pulls in) throws where Android coerces, so the engine ships
 * AOSP's implementation instead. These are Android's documented behaviours.
 */
class AndroidJsonTest {
    private val json = JSONObject("""{"z":1,"id":123,"flag":true,"n":null,"a":2,"price":"4.5","list":[1,"2",null]}""")

    @Test fun `the engine's org json is Android's, not JSON-java`() {
        // JSON-java ships org.json.XML and friends; Android's has six classes.
        assertNull(runCatching { Class.forName("org.json.XML") }.getOrNull())
        assertNotNull(Class.forName("org.json.JSONStringer"))
    }

    @Test fun `getString coerces numbers and booleans like Android`() {
        assertEquals("123", json.getString("id"))
        assertEquals("true", json.getString("flag"))
        assertFailsWith<JSONException> { json.getString("missing") }
    }

    @Test fun `numbers coerce from strings and null handling matches Android`() {
        assertEquals(4.5, json.getDouble("price"))
        assertEquals(4, json.getInt("price"))
        assertEquals("null", json.optString("n"))
        assertEquals("", json.optString("missing"))
        assertTrue(json.isNull("n"))
        assertEquals(JSONObject.NULL, json.get("n"))
    }

    @Test fun `keys keep insertion order`() {
        assertEquals(listOf("z", "id", "flag", "n", "a", "price", "list"), json.keys().asSequence().toList())
        assertEquals("""{"b":1,"a":2}""", JSONObject().put("b", 1).put("a", 2).toString())
    }

    @Test fun `arrays maps and non-finite numbers behave like Android`() {
        val list: JSONArray = json.getJSONArray("list")
        assertEquals("2", list.getString(1))
        assertEquals(2, list.getInt(1))
        assertTrue(list.isNull(2))
        val nested = JSONObject(mapOf("inner" to mapOf("k" to listOf(1, 2)), "s" to "v"))
        assertEquals("""{"inner":{"k":[1,2]},"s":"v"}""", nested.toString())
        assertFailsWith<JSONException> { JSONObject().put("x", Double.NaN) }
        assertEquals("[1,\"a\"]", JSONArray(listOf(1, "a")).toString())
    }
}
