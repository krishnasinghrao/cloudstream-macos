package com.lagradost.macos

import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.utils.ExtractorLink
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import kotlin.test.*

class OperationFailureTest {
    @BeforeTest fun before() { ExtensionTestSupport.resetHome(); APIHolder.allProviders.clear() }
    @AfterTest fun after() { APIHolder.allProviders.clear(); ExtensionTestSupport.resetHome() }

    @Test fun `details reports a local ABI error and no sensitive provider URL`() {
        APIHolder.allProviders.add(object : MainAPI() {
            override var name = "BrokenAbi"
            override suspend fun load(url: String): LoadResponse =
                throw NoSuchMethodError("kotlin.Result.constructor_impl secret-cookie $url")
        })
        RouteHarness().use { routes ->
            val response = routes.get("/details?plugin=BrokenAbi&url=https%3A%2F%2Fprivate.invalid%2Ftitle%3Ftoken%3Dsecret")
            assertEquals(422, response.status)
            val failure = response.json.jsonObject.getValue("failure").jsonObject
            assertEquals("missing_host_member", failure.getValue("code").jsonPrimitive.content)
            assertEquals("details", failure.getValue("stage").jsonPrimitive.content)
            assertEquals("kotlin.Result.constructor_impl", failure.getValue("redactedCause").jsonPrimitive.content)
            assertFalse(response.body.contains("private.invalid"))
            assertFalse(response.body.contains("secret-cookie"))
            assertTrue(failure.getValue("requestId").jsonPrimitive.content.isNotBlank())
        }
    }

    @Test fun `stream has one failed terminal result and batch is not empty success`() {
        APIHolder.allProviders.add(object : MainAPI() {
            override var name = "BrokenLinks"
            override suspend fun loadLinks(data: String, isCasting: Boolean, subtitleCallback: (SubtitleFile) -> Unit,
                callback: (ExtractorLink) -> Unit): Boolean = throw NoSuchMethodError("kotlin.Result.box_impl")
        })
        RouteHarness().use { routes ->
            val body = """{"plugin":"BrokenLinks","data":"private-title-data"}"""
            val batch = routes.post("/links", body)
            assertEquals(422, batch.status)
            val stream = routes.post("/links/stream", body)
            val events = stream.body.lineSequence().filter { it.isNotBlank() }.map { Json.parseToJsonElement(it).jsonObject }.toList()
            assertEquals(1, events.size)
            assertEquals("done", events.single().getValue("type").jsonPrimitive.content)
            assertEquals("failure", events.single().getValue("outcome").jsonPrimitive.content)
            assertEquals("missing_host_member", events.single().getValue("failures").jsonArray.single().jsonObject.getValue("code").jsonPrimitive.content)
            assertFalse(stream.body.contains("private-title-data"))
        }
    }

    @Test fun `link emitted before a failure remains a typed partial result`() = runBlocking<Unit> {
        val provider = object : MainAPI() {
            override suspend fun loadLinks(data: String, isCasting: Boolean, subtitleCallback: (SubtitleFile) -> Unit,
                callback: (ExtractorLink) -> Unit): Boolean {
                callback(com.lagradost.cloudstream3.utils.newExtractorLink("fixture", "media", "https://fixture.invalid/video.m3u8"))
                throw NoClassDefFoundError("android/missing/Required")
            }
        }
        val response = ProviderExecutor.loadLinks(provider, "fixture")
        assertEquals("partial", response.outcome)
        assertEquals(1, response.links.size)
        assertEquals("missing_host_class", response.failures.single().code)
    }

    @Test fun `capacity is a typed retryable 503 and incompatibility a terminal 422`() {
        APIHolder.allProviders.add(object : MainAPI() {
            override var name = "Busy"
            override suspend fun loadLinks(data: String, isCasting: Boolean, subtitleCallback: (SubtitleFile) -> Unit,
                callback: (ExtractorLink) -> Unit): Boolean = throw WorkerCapacityException()
        })
        APIHolder.allProviders.add(object : MainAPI() {
            override var name = "Incompatible"
            override suspend fun loadLinks(data: String, isCasting: Boolean, subtitleCallback: (SubtitleFile) -> Unit,
                callback: (ExtractorLink) -> Unit): Boolean = throw NoSuchMethodError("kotlin.Result.box_impl")
        })
        RouteHarness().use { routes ->
            val busy = routes.post("/links", """{"plugin":"Busy","data":"d"}""")
            assertEquals(503, busy.status)
            val failure = busy.json.jsonObject.getValue("failure").jsonObject
            assertEquals("capacity", failure.getValue("code").jsonPrimitive.content)
            assertTrue(failure.getValue("retryable").jsonPrimitive.boolean)
            // The client decodes exactly these keys (see DownloadReliabilityTests).
            assertEquals(setOf("code", "stage", "requestId", "publicMessage", "retryable", "installationId", "providerId",
                "redactedCause", "remoteStatus", "elapsedMs"), failure.keys)
            assertEquals(setOf("error", "detail", "failure"), busy.json.jsonObject.keys)
            val terminal = routes.post("/links", """{"plugin":"Incompatible","data":"d"}""")
            assertEquals(422, terminal.status)
            assertFalse(terminal.json.jsonObject.getValue("failure").jsonObject.getValue("retryable").jsonPrimitive.boolean)
        }
    }

    @Test fun `linkage errors are split by what is actually wrong`() {
        fun code(error: Throwable) = OperationFailures.capture(null, "load", error).failure.code
        assertEquals("missing_host_class", code(NoClassDefFoundError("android/content/Intent")))
        assertEquals("missing_host_member", code(NoSuchMethodError("com.lagradost.cloudstream3.Foo.bar()V")))
        assertEquals("missing_host_member", code(NoSuchFieldError("TV")))
        assertEquals("missing_host_member", code(AbstractMethodError("x")))
        assertEquals("translation_rejected", code(VerifyError("Bad type on operand stack")))
        assertEquals("translation_rejected", code(ClassFormatError("Truncated class file")))
        assertEquals("host_abi_mismatch", code(IncompatibleClassChangeError("Expected static method")))
        // The extension's own static initializer failing is its bug, not a missing host API.
        assertEquals("provider_failure", code(ExceptionInInitializerError(IllegalStateException("boom"))))
        assertEquals("provider_failure", code(NoClassDefFoundError("Could not initialize class com.example.Api")))
        assertEquals("missing_host_class", code(RuntimeException("wrapped", NoClassDefFoundError("androidx/preference/PreferenceManager"))))
        for (incompatible in OperationFailures.INCOMPATIBLE) {
            assertEquals(422, OperationFailures.status(OperationFailures.capture(null, "load", when (incompatible) {
                "missing_host_class" -> NoClassDefFoundError("a/B"); "missing_host_member" -> NoSuchMethodError("a.B.c()V")
                "translation_rejected" -> VerifyError("v"); else -> IncompatibleClassChangeError("i")
            }).failure))
        }
    }

    @Test fun `network failures name their cause and stay retryable`() {
        fun failure(error: Throwable) = OperationFailures.capture(null, "search", error).failure
        assertEquals("dns_failure", failure(java.net.UnknownHostException("site.invalid")).code)
        assertEquals("tls_failure", failure(javax.net.ssl.SSLHandshakeException("handshake")).code)
        assertEquals("network_timeout", failure(java.net.SocketTimeoutException("timeout")).code)
        assertEquals("network_timeout", failure(java.io.InterruptedIOException("timeout")).code)
        assertEquals("connection_refused", failure(java.net.ConnectException("Connection refused")).code)
        assertEquals("connection_reset", failure(java.net.SocketException("Connection reset")).code)
        assertEquals("network_failure", failure(java.io.IOException("Canceled")).code)
        assertEquals("dns_failure", failure(IllegalStateException("wrapped", java.net.UnknownHostException("x"))).code)
        assertTrue(failure(java.net.UnknownHostException("x")).retryable)
        assertFalse(failure(javax.net.ssl.SSLHandshakeException("x")).retryable)
        assertFalse(failure(java.net.UnknownHostException("secret.invalid")).publicMessage.contains("secret"))
        val oom = com.lagradost.macos.worker.WorkerFailure(com.lagradost.macos.worker.WorkerFailure.Kind.CRASHED,
            "The extension ran out of memory.", com.lagradost.macos.worker.WorkerFailure.OUT_OF_MEMORY)
        assertEquals("worker_out_of_memory", failure(oom).code)
        assertTrue(failure(oom).retryable)
    }

    @Test fun `cancellation is not serialized as a provider failure`() {
        assertFailsWith<CancellationException> { OperationFailures.capture(null, "search", CancellationException()) }
        assertEquals(120_000, OperationBudget.forHint(null))
        assertEquals(5_000, OperationBudget.forHint(150))
        assertEquals(480_000, OperationBudget.forHint(Long.MAX_VALUE))
    }
}
