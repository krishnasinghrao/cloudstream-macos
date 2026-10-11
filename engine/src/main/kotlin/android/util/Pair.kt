package android.util

/**
 * SEC-08: Pure-Java stub for `android.util.Pair`, frequently referenced by
 * community extractors.
 */
/** Android exposes `first`/`second` as public final fields; bytecode uses GETFIELD. */
class Pair<F, S>(@JvmField val first: F?, @JvmField val second: S?) {
    override fun hashCode(): Int = (first?.hashCode() ?: 0) * 31 + (second?.hashCode() ?: 0)

    override fun equals(other: Any?): Boolean =
        other is Pair<*, *> && other.first == first && other.second == second

    override fun toString(): String = "Pair($first, $second)"

    companion object {
        @JvmStatic
        fun <F, S> create(first: F?, second: S?): Pair<F, S> = Pair(first, second)
    }
}
