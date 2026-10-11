package android.text

/** Android's TextUtils: the string helpers scrapers use (plan RT-14). */
object TextUtils {
    @JvmStatic fun isEmpty(str: CharSequence?): Boolean = str == null || str.isEmpty()
    @JvmStatic fun isDigitsOnly(str: CharSequence): Boolean = str.all { Character.isDigit(it) }
    @JvmStatic fun equals(a: CharSequence?, b: CharSequence?): Boolean = a?.toString() == b?.toString()
    @JvmStatic fun join(delimiter: CharSequence, tokens: Array<Any?>): String = tokens.joinToString(delimiter)
    @JvmStatic fun join(delimiter: CharSequence, tokens: Iterable<*>): String = tokens.joinToString(delimiter)
    /** Android splits on a regular expression and, unlike String.split, keeps trailing empty strings. */
    @JvmStatic fun split(text: String, expression: String): Array<String> =
        if (text.isEmpty()) emptyArray() else text.split(Regex(expression)).toTypedArray()
    @JvmStatic fun split(text: String, pattern: java.util.regex.Pattern): Array<String> =
        if (text.isEmpty()) emptyArray() else text.split(pattern.toRegex()).toTypedArray()
    @JvmStatic fun htmlEncode(s: String): String = buildString(s.length) {
        for (c in s) append(when (c) { '<' -> "&lt;"; '>' -> "&gt;"; '&' -> "&amp;"; '\'' -> "&#39;"; '"' -> "&quot;"; else -> c })
    }
    @JvmStatic fun getTrimmedLength(s: CharSequence): Int = s.trim { it <= ' ' }.length
    @JvmStatic fun concat(vararg text: CharSequence?): CharSequence = text.joinToString("") { it ?: "" }
}
