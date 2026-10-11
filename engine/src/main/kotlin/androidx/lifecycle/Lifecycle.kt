package androidx.lifecycle

/** androidx Lifecycle types extensions reference. No Android component has a lifecycle on macOS. */
abstract class Lifecycle {
    abstract fun getCurrentState(): State

    enum class State {
        DESTROYED, INITIALIZED, CREATED, STARTED, RESUMED;

        fun isAtLeast(state: State): Boolean = compareTo(state) >= 0
    }
}
