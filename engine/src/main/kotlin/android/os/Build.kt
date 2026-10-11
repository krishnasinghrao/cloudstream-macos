package android.os

/**
 * Android's Build identity, describing this Mac truthfully rather than
 * inventing an Android device (plan RT-14). No SDK level is claimed.
 */
object Build {
    @JvmField val BRAND: String = "Apple"
    @JvmField val MANUFACTURER: String = "Apple"
    @JvmField val MODEL: String = "Mac"
    @JvmField val DEVICE: String = "mac"
    @JvmField val PRODUCT: String = "macOS"
}
