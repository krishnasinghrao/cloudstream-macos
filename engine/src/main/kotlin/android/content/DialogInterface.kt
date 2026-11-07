package android.content

/**
 * Android `android.content.DialogInterface` and its listener interfaces.
 * Extensions declare these for their own settings dialogs, often from code
 * that runs at load time (a listener field, a lambda in the plugin class). No
 * Android dialog is ever shown on macOS, so nothing calls them; the types must
 * exist so the extension links. Descriptors follow API 35.
 */
interface DialogInterface {
    fun cancel()
    fun dismiss()

    fun interface OnClickListener {
        fun onClick(dialog: DialogInterface?, which: Int)
    }

    fun interface OnMultiChoiceClickListener {
        fun onClick(dialog: DialogInterface?, which: Int, isChecked: Boolean)
    }

    fun interface OnCancelListener {
        fun onCancel(dialog: DialogInterface?)
    }

    fun interface OnDismissListener {
        fun onDismiss(dialog: DialogInterface?)
    }

    fun interface OnShowListener {
        fun onShow(dialog: DialogInterface?)
    }

    companion object {
        const val BUTTON_POSITIVE: Int = -1
        const val BUTTON_NEGATIVE: Int = -2
        const val BUTTON_NEUTRAL: Int = -3
    }
}
