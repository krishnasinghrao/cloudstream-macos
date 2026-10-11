package com.lagradost.cloudstream3.utils

/** Marks tests upstream skips on its web target. The engine is JVM-only, so this is a no-op. */
@Target(AnnotationTarget.CLASS, AnnotationTarget.FUNCTION)
annotation class IgnoreOnWeb
