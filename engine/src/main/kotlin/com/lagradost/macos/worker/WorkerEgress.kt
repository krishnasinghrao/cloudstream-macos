package com.lagradost.macos.worker

import java.io.IOException
import java.net.Authenticator
import java.net.InetSocketAddress
import java.net.PasswordAuthentication
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI

/**
 * Worker side of [WorkerEgressProxy]: every connection the extension makes
 * through the JDK (OkHttp, URLConnection, plain sockets) is sent to the
 * engine's egress proxy, with that proxy's per-engine credentials. The sandbox
 * allows no other destination, so anything that bypasses this (NIO channels,
 * an extension's own Authenticator) fails closed instead of reaching the
 * network directly.
 */
internal object WorkerEgress {
    @Volatile var installed: EgressSettings? = null
        private set

    fun install(settings: EgressSettings) {
        val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress(settings.host, settings.port))
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI?): List<Proxy> = listOf(proxy)
            override fun connectFailed(uri: URI?, address: SocketAddress?, failure: IOException?) {}
        })
        Authenticator.setDefault(object : Authenticator() {
            override fun getPasswordAuthentication(): PasswordAuthentication? =
                if (requestingProtocol == "SOCKS5" && requestingPort == settings.port && requestingHost == settings.host)
                    PasswordAuthentication(settings.username, settings.password.toCharArray()) else null
        })
        installed = settings
    }
}
