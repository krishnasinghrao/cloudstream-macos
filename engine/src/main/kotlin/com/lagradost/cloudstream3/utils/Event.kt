package com.lagradost.cloudstream3.utils

/** The Android app's observer list (identical semantics); extensions subscribe to app events through it. */
class Event<T> {
    private val observers = mutableSetOf<(T) -> Unit>()

    val size: Int get() = synchronized(observers) { observers.size }

    operator fun plusAssign(observer: (T) -> Unit) {
        synchronized(observers) { observers.add(observer) }
    }

    operator fun minusAssign(observer: (T) -> Unit) {
        synchronized(observers) { observers.remove(observer) }
    }

    operator fun invoke(value: T) {
        // Snapshot: an observer may unsubscribe itself while being notified.
        val current = synchronized(observers) { observers.toList() }
        for (observer in current) observer(value)
    }
}
