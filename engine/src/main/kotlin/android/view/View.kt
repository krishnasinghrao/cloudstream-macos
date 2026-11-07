package android.view

import android.content.Context

/**
 * Inert Android `android.view.View` with its common listener interfaces.
 * Extensions reference these from settings screens and click handlers, some
 * of them reachable at load time; macOS never presents Android UI, so a view
 * here only keeps what it is given. The types must exist so the extension
 * links. Descriptors follow API 35.
 */
open class View(private val context: Context?) {
    private var visibility = VISIBLE
    private var enabled = true
    private var clickListener: OnClickListener? = null
    private var longClickListener: OnLongClickListener? = null
    private var focusListener: OnFocusChangeListener? = null

    open fun getContext(): Context? = context
    open fun getVisibility(): Int = visibility
    open fun setVisibility(visibility: Int) { this.visibility = visibility }
    open fun isEnabled(): Boolean = enabled
    open fun setEnabled(enabled: Boolean) { this.enabled = enabled }
    open fun setOnClickListener(l: OnClickListener?) { clickListener = l }
    open fun setOnLongClickListener(l: OnLongClickListener?) { longClickListener = l }
    open fun setOnFocusChangeListener(l: OnFocusChangeListener?) { focusListener = l }
    open fun hasOnClickListeners(): Boolean = clickListener != null
    /** Calls the click listener, as Android does; false when there is none. */
    open fun performClick(): Boolean = clickListener?.let { it.onClick(this); true } ?: false
    open fun performLongClick(): Boolean = longClickListener?.onLongClick(this) ?: false

    fun interface OnClickListener {
        fun onClick(v: View?)
    }

    fun interface OnLongClickListener {
        fun onLongClick(v: View?): Boolean
    }

    fun interface OnFocusChangeListener {
        fun onFocusChange(v: View?, hasFocus: Boolean)
    }

    companion object {
        const val VISIBLE: Int = 0
        const val INVISIBLE: Int = 4
        const val GONE: Int = 8
    }
}
