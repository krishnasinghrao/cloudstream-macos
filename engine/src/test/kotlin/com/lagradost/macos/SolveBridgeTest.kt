package com.lagradost.macos

import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import okhttp3.ResponseBody.Companion.toResponseBody
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class SolveBridgeTest {

    @Test
    fun `pending tasks are listed and completed`() = runBlocking {
        val task = SolveBridge.newTask("https://challenged.example/page")
        assertTrue(SolveBridge.listPending().any { it.taskId == task.taskId })

        val completed = SolveBridge.complete(task.taskId, "https://challenged.example/page", "cf_clearance=abc")
        assertTrue(completed)

        val solution = SolveBridge.awaitSolution(task)
        assertNotNull(solution)
        assertEquals("cf_clearance=abc", solution.cookies)

        assertEquals("cf_clearance=abc", SolveBridge.cookieHeaderFor("https://challenged.example/other"))
    }

    @Test
    fun `a worker's solved cookies go only to that worker, never into the shared cache (L3)`() = runBlocking {
        val answer = async { SolveBridge.solveForWorker("https://worker-only.example/page") }
        val task = kotlinx.coroutines.withTimeout(5_000) {
            var found: SolveBridge.PendingTask? = null
            while (found == null) { found = SolveBridge.listPending().firstOrNull { it.targetUrl == "https://worker-only.example/page" }; kotlinx.coroutines.delay(10) }
            found
        }
        assertFalse(task.shared)
        assertTrue(SolveBridge.complete(task.taskId, null, "cf_clearance=worker"))
        assertEquals("cf_clearance=worker", answer.await(), "the requesting worker receives its cookies")
        kotlin.test.assertNull(SolveBridge.cookieHeaderFor("https://worker-only.example/other"),
            "engine-side and repository requests never reuse a worker's clearance")
    }

    @Test
    fun `unknown taskId is not completable`() {
        assertFalse(SolveBridge.complete("nonexistent", null, "cookies"))
    }

    @Test
    fun `blank cookies are rejected`() = runBlocking {
        val task = SolveBridge.newTask("https://x.example")
        assertFalse(SolveBridge.complete(task.taskId, null, "  "))
        SolveBridge.complete(task.taskId, null, "a=b") // cleanup so later tests are unaffected
        Unit
    }

    @Test
    fun `cookies are host-scoped`() = runBlocking {
        val task = SolveBridge.newTask("https://host-a.example/x")
        SolveBridge.complete(task.taskId, null, "a=1")
        assertNotNull(SolveBridge.cookieHeaderFor("https://host-a.example/y"))
        assertEquals(null, SolveBridge.cookieHeaderFor("https://host-b.example/y"))
    }

    @Test
    fun `manual cookie application is host-scoped`() {
        SolveBridge.applySolvedCookies("https://manual.example/a", "m=1")
        assertEquals("m=1", SolveBridge.cookieHeaderFor("https://manual.example/b"))
    }
    @Test fun `callback cannot retarget cookies or inject headers`() = runBlocking {
        val task = SolveBridge.newTask("https://original.example/path")
        assertFalse(SolveBridge.complete(task.taskId, "https://other.example/path", "a=1"))
        assertFalse(SolveBridge.complete(task.taskId, null, "a=1\r\nInjected: value"))
        assertTrue(SolveBridge.listPending().any { it.taskId == task.taskId })
        assertTrue(SolveBridge.complete(task.taskId, null, "a=1"))
        assertEquals("a=1", SolveBridge.cookieHeaderFor("https://original.example/other"))
        assertEquals(null, SolveBridge.cookieHeaderFor("http://original.example/path"))
        assertEquals(null, SolveBridge.cookieHeaderFor("https://original.example:8443/path"))
    }

    @Test fun `cancelled waits immediately release pending tasks`() = runBlocking {
        val task = SolveBridge.newTask("https://cancel.example/")
        kotlinx.coroutines.withTimeoutOrNull(10) { SolveBridge.awaitSolution(task) }
        assertFalse(SolveBridge.listPending().any { it.taskId == task.taskId })
        assertFalse(SolveBridge.complete(task.taskId, null, "a=1"))
    }

    @Test fun `interceptor reuses cookies using the full URL`() {
        val target = "https://interceptor.example/page"
        SolveBridge.applySolvedCookies(target, "cf_clearance=fixture")
        val client = okhttp3.OkHttpClient.Builder().addInterceptor(SolveInterceptor())
            .addInterceptor { chain ->
                assertEquals("cf_clearance=fixture", chain.request().header("Cookie"))
                okhttp3.Response.Builder().request(chain.request()).protocol(okhttp3.Protocol.HTTP_1_1)
                    .code(200).message("fixture").body("ok".toResponseBody()).build()
            }.build()
        client.newCall(okhttp3.Request.Builder().url(target).build()).execute().use {
            assertEquals(200, it.code)
        }
    }

}
