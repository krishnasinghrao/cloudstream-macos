package com.lagradost.macos

import io.ktor.server.netty.NettyApplicationCall
import io.ktor.server.routing.RoutingCall
import io.netty.channel.ChannelFutureListener
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope

/**
 * The daemon uses Netty. Ktor's text writer notices a closed connection on its
 * next write; an idle producer otherwise keeps its provider jobs alive. Bind
 * this stream's structured scope to the actual connection's close future,
 * and detach the listener when the response completes on a reusable socket.
 */
internal suspend fun <T> RoutingCall.withConnectionCancellation(block: suspend CoroutineScope.() -> T): T = coroutineScope {
    val engine = checkNotNull(pipelineCall.engineCall as? NettyApplicationCall) {
        "Streaming connection ownership requires the daemon's Netty engine."
    }
    val operation = checkNotNull(coroutineContext[Job])
    val closed = engine.context.channel().closeFuture()
    val listener = ChannelFutureListener { operation.cancel(CancellationException("Streaming client disconnected.")) }
    closed.addListener(listener)
    try { block() } finally { closed.removeListener(listener) }
}
