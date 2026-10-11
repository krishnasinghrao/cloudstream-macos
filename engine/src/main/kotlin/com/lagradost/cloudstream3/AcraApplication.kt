package com.lagradost.cloudstream3

class AcraApplication {
    companion object {
        val context get() = CloudStreamApp.context

        fun removeKeys(folder: String): Int =
            CloudStreamApp.removeKeys(folder) ?: 0

        fun <T> setKey(path: String, value: T) =
            CloudStreamApp.setKey(path, value)

        fun <T> setKey(folder: String, path: String, value: T) =
            CloudStreamApp.setKey("$folder/$path", value)

        inline fun <reified T : Any> getKey(path: String, defVal: T? = null): T? =
            CloudStreamApp.getKey(path, defVal)

        inline fun <reified T : Any> getKey(folder: String, path: String, defVal: T? = null): T? =
            CloudStreamApp.getKey("$folder/$path", defVal)
    }
}
