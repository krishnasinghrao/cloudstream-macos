## CloudStream extension library

This is the API surface CloudStream extensions compile against (MainAPI,
extractors, the nicehttp network stack). The engine bundles it into
`daemon.jar`.

Upstream builds this module as Kotlin Multiplatform. Here it is a plain
Kotlin/JVM library holding the common and JVM sources only, with the same
class names, so extensions built for upstream link unchanged.

Binary compatibility is checked against `api/library.api`:

``./gradlew :library:checkKotlinAbi``

If a change must alter the ABI on purpose, update the dump with:

``./gradlew :library:updateKotlinAbi``
