package android.app

import android.content.ContextWrapper

/**
 * Inert Android UI type. Extensions reference Activity in code paths that show
 * their own settings screens; macOS never presents Android UI, so those paths
 * are unreachable here. The type must exist so the extension's load() links.
 */
open class Activity : ContextWrapper(null)
