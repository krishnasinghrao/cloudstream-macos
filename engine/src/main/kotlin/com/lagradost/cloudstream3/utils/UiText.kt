@file:JvmName("TextUtilKt")

package com.lagradost.cloudstream3.utils

import android.content.Context

/**
 * Android: utils/TextUtil.kt `UiText` and its `txt` builders, with the same
 * JVM names. The app's own string resources do not exist on macOS, so a
 * [StringResource] reads as the context's (empty) string for that id.
 */
sealed class UiText {
    data class DynamicString(val value: String) : UiText() {
        override fun toString(): String = value
    }

    class StringResource(val resId: Int, val args: List<Any>) : UiText() {
        override fun toString(): String = "resId = $resId\nargs = $args"
        override fun equals(other: Any?): Boolean = other is StringResource && resId == other.resId && args == other.args
        override fun hashCode(): Int = 31 * resId + args.hashCode()
    }

    fun asStringNull(context: Context?): String? =
        try { asString(context ?: return null) } catch (_: Exception) { null }

    fun asString(context: Context): String = when (this) {
        is DynamicString -> value
        is StringResource -> {
            val text = context.getString(resId)
            if (args.isEmpty()) text
            else text.format(*args.map { if (it is UiText) it.asString(context) else it }.toTypedArray())
        }
    }

    companion object {
        const val TAG = "UiText"
    }
}

fun txt(value: String): UiText = UiText.DynamicString(value)

@JvmName("txtNull")
fun txt(value: String?): UiText? = UiText.DynamicString(value ?: return null)

fun txt(resId: Int, vararg args: Any): UiText = UiText.StringResource(resId, args.toList())

@JvmName("txtNull")
fun txt(resId: Int?, vararg args: Any?): UiText? {
    if (resId == null || args.any { it == null }) return null
    return UiText.StringResource(resId, args.filterNotNull())
}
