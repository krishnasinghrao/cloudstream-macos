package com.lagradost.macos

import android.content.Context
import android.net.Uri
import android.util.Base64
import java.io.File
import kotlin.test.*

/** Android API contracts the stubs must honor (plan T6.4/T6.5, fact-check N06/N07). */
class AndroidStubConformanceTest {
    @BeforeTest fun before() = ExtensionTestSupport.resetHome()

    @Test fun `pair exposes public final fields like Android`() {
        val field = android.util.Pair::class.java.getField("first")
        assertTrue(java.lang.reflect.Modifier.isPublic(field.modifiers) && java.lang.reflect.Modifier.isFinal(field.modifiers))
        assertEquals("a", android.util.Pair("a", "b").first)
    }

    @Test fun `uri query parameters decode and encoding matches Android`() {
        val uri = Uri.parse("https://h.invalid/p?q=a%2Fb&s=x+y&e=")
        assertEquals("a/b", uri.getQueryParameter("q"))
        assertEquals("x y", uri.getQueryParameter("s"))
        assertEquals("", uri.getQueryParameter("e"))
        assertEquals("a%20b%2Fc%26d", Uri.encode("a b/c&d"))
        assertEquals("a/b", Uri.encode("a/b", "/"))
        assertEquals("a+b c", Uri.decode("a+b%20c"))
        val built = Uri.parse("https://h.invalid/p").buildUpon().appendQueryParameter("q", "a&admin=1").build()
        assertEquals("https://h.invalid/p?q=a%26admin%3D1", built.toString())
        assertEquals("a&admin=1", built.getQueryParameter("q"))
        assertEquals(listOf("q"), built.getQueryParameterNames().toList())
    }

    @Test fun `base64 wraps like Android default and decodes wrapped input`() {
        val data = ByteArray(100) { it.toByte() }
        val wrapped = Base64.encodeToString(data, Base64.DEFAULT)
        assertTrue(wrapped.lines().first().length == 76 && wrapped.endsWith("\n"))
        assertFalse(Base64.encodeToString(data, Base64.NO_WRAP).contains("\n"))
        assertTrue(Base64.encodeToString(data, Base64.CRLF).contains("\r\n"))
        assertContentEquals(data, Base64.decode(wrapped, Base64.DEFAULT))
        assertContentEquals(data, Base64.decode(Base64.encodeToString(data, Base64.NO_PADDING or Base64.NO_WRAP), Base64.DEFAULT))
        assertContentEquals(data, Base64.decode(Base64.encodeToString(data, Base64.URL_SAFE or Base64.NO_WRAP), Base64.URL_SAFE))
        assertFailsWith<IllegalArgumentException> { Base64.decode("*not base64*", Base64.DEFAULT) }
        assertEquals("", Base64.encodeToString(ByteArray(0), Base64.DEFAULT))
    }

    @Test fun `context storage follows the configured data root and is namespaced`() {
        val a = Context(File(CloudDirs.extensionDataDir, "a"))
        val b = Context(File(CloudDirs.extensionDataDir, "b"))
        assertTrue(a.getFilesDir().path.startsWith(CloudDirs.home.path))
        assertTrue(Context().getCacheDir().path.startsWith(CloudDirs.home.path), "host context also respects cs.cloudstream.home")
        a.getSharedPreferences("prefs", Context.MODE_PRIVATE).edit().putString("k", "a").commit()
        assertNull(b.getSharedPreferences("prefs", Context.MODE_PRIVATE).getString("k", null))
        assertFailsWith<IllegalArgumentException> { a.getDir("../escape", 0) }
    }

    @Test fun `shared preferences follow Android editor semantics and persist`() {
        val dir = File(CloudDirs.extensionDataDir, "prefs-test")
        val prefs = Context(dir).getSharedPreferences("s", 0)
        var notified = 0
        val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> notified++ }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        assertTrue(prefs.edit().putString("s", "v").putInt("i", 3).putBoolean("b", true).putStringSet("set", mutableSetOf("x")).commit())
        assertEquals("v", prefs.getString("s", null)); assertEquals(3, prefs.getInt("i", 0))
        assertEquals<Set<String>?>(setOf("x"), prefs.getStringSet("set", null))
        prefs.edit().remove("s").apply()
        assertFalse(prefs.contains("s"))
        prefs.edit().clear().putLong("l", 9).commit()
        assertEquals(setOf("l"), prefs.getAll().keys)
        assertTrue(notified > 0)
        val file = File(dir, "shared_prefs/s.json")
        assertTrue(file.isFile)
        assertTrue(file.readText().contains("\"l\""))
    }

    @Test fun `default preferences are the extension's own file under Android's default name`() {
        val context = Context(File(CloudDirs.extensionDataDir, "default-prefs"))
        val prefs = android.preference.PreferenceManager.getDefaultSharedPreferences(context)
        prefs.edit().putString("server", "two").commit()
        assertEquals("two", androidx.preference.PreferenceManager.getDefaultSharedPreferences(context).getString("server", null))
        assertEquals("two", context.getSharedPreferences("com.lagradost.cloudstream3_preferences", Context.MODE_PRIVATE).getString("server", null))
        assertNull(android.preference.PreferenceManager.getDefaultSharedPreferences(Context(File(CloudDirs.extensionDataDir, "other")))
            .getString("server", null), "namespaced per extension")
    }

    @Test fun `intents keep their values and starting an activity is a recorded no-op`() {
        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, Uri.parse("https://site.invalid/title"))
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("n", 3).putExtra("s", "v")
        assertEquals(android.content.Intent.ACTION_VIEW, intent.getAction())
        assertEquals("https://site.invalid/title", intent.getDataString())
        assertEquals(3, intent.getIntExtra("n", 0)); assertEquals("v", intent.getStringExtra("s"))
        assertEquals(android.content.Intent.FLAG_ACTIVITY_NEW_TASK, intent.getFlags())
        val chooser = android.content.Intent.createChooser(intent, "Open with")
        assertEquals(android.content.Intent.ACTION_CHOOSER, chooser.getAction())
        Context(File(CloudDirs.extensionDataDir, "intent")).startActivity(intent) // must not throw
        android.widget.Toast.makeText(null, "Saved", android.widget.Toast.LENGTH_SHORT).show()
    }

    @Test fun `launch options parse strictly and fail closed`() {
        assertEquals(LaunchOptions(), LaunchOptions.parse(null))
        val parsed = LaunchOptions.parse("""{"safeMode":true,"policy":{"allowCommunityTier":false,"managed":true}}""")
        assertTrue(parsed.safeMode)
        assertFalse(parsed.policy.allowCommunityTier)
        val invalid = LaunchOptions.parse("{not json")
        assertTrue(invalid.safeMode && !invalid.policy.allowCommunityTier && invalid.policy.allowedRepositories!!.isEmpty())
        val policy = ExtensionPolicy(allowedRepositories = listOf("https://a.invalid/repo.json"), allowUserRepositories = false)
        assertTrue(policy.repositoryAllowed("https://a.invalid/repo.json"))
        assertFalse(policy.repositoryAllowed("https://b.invalid/repo.json"))
        assertFailsWith<PolicyException> { policy.requireRepository("https://b.invalid/repo.json", userInitiated = true) }
    }
}
