package android.net

import android.os.Handler
import android.os.Looper

/** Android's network objects, as far as extensions use them (RT-14). */
open class Network internal constructor()

open class NetworkRequest internal constructor(private val capabilities: Set<Int>) {
    open class Builder {
        private val capabilities = LinkedHashSet<Int>()
        open fun addCapability(capability: Int): Builder = apply { capabilities += capability }
        open fun removeCapability(capability: Int): Builder = apply { capabilities -= capability }
        open fun addTransportType(transportType: Int): Builder = this
        open fun build(): NetworkRequest = NetworkRequest(capabilities.toSet())
    }
}

/**
 * Android's ConnectivityManager. The engine runs while the Mac is online
 * enough to serve the app, so a registered callback hears [NetworkCallback.onAvailable]
 * once, asynchronously on the main looper, as Android reports a currently
 * satisfying network. Later Mac network changes are not reported.
 */
open class ConnectivityManager internal constructor() {
    open class NetworkCallback {
        open fun onAvailable(network: Network) {}
        open fun onLost(network: Network) {}
        open fun onUnavailable() {}
    }

    private val callbacks = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<NetworkCallback, Boolean>())

    open fun registerNetworkCallback(request: NetworkRequest, networkCallback: NetworkCallback) {
        require(callbacks.size < 64) { "Too many network callbacks" }
        callbacks += networkCallback
        Handler(Looper.getMainLooper()).post { if (networkCallback in callbacks) networkCallback.onAvailable(Network()) }
    }

    open fun registerDefaultNetworkCallback(networkCallback: NetworkCallback) = registerNetworkCallback(NetworkRequest.Builder().build(), networkCallback)

    open fun unregisterNetworkCallback(networkCallback: NetworkCallback) {
        callbacks -= networkCallback
    }
}
