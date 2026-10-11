package com.lagradost.cloudstream3.actions

abstract class VideoClickAction {
    open val name: Any? = null
    var sourcePlugin: String? = null
}
