import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The CloudStream extension API (MainAPI, extractors, nicehttp network stack),
// built as a plain Kotlin/JVM library for the engine. Upstream ships it as a
// multiplatform module; here only the JVM sources exist, so extensions see the
// same class names (e.g. Coroutines_jvmKt) and the ABI in api/library.api.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

version = "1.0.1"

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        // The module name upstream's JVM build used; internal declarations are
        // name-mangled with it, so it stays fixed for binary compatibility.
        moduleName.set("CloudStream_library")
        optIn.addAll("com.lagradost.cloudstream3.InternalAPI", "com.lagradost.cloudstream3.Prerelease")
    }

    @OptIn(org.jetbrains.kotlin.gradle.dsl.abi.ExperimentalAbiValidation::class)
    // https://kotlinlang.org/docs/gradle-binary-compatibility-validation.html
    abiValidation {
        filters {
            exclude {
                annotatedWith.add("com.lagradost.cloudstream3.Prerelease")
                annotatedWith.add("com.lagradost.cloudstream3.InternalAPI")
            }
        }
    }
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

dependencies {
    implementation(libs.annotation) // @MainThread/@WorkerThread markers (plain JVM jar)
    implementation(libs.jackson.module.kotlin) // JSON Parser
    implementation(libs.jsoup) // HTML Parser
    implementation(libs.kotlinx.atomicfu)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.datetime)
    implementation(libs.kotlinx.io.core)
    implementation(libs.kotlinx.serialization.json) // JSON Parser
    implementation(libs.ksoup) // HTML Parser
    implementation(libs.ktor.http)
    implementation(libs.nicehttp) // HTTP Library
    implementation(libs.rhino) // Run JavaScript
    implementation(libs.bundles.cryptography) // Cryptography
    implementation(libs.kotlin.reflect)
    implementation(libs.newpipeextractor)

    testImplementation(libs.kotlin.test)
    testImplementation(libs.kotlinx.coroutines.test)
}

// Keeps the artifact name the engine's SBOM and test fixtures expect.
tasks.jar {
    archiveBaseName.set("library-jvm")
}

/**
 * com.lagradost.api.BuildConfig: optional metadata-provider keys from the
 * environment or local.properties (mdl.key, trakt.id). Missing keys become
 * the string "null", as upstream's generated config does.
 */
val generateBuildConfig = tasks.register("generateBuildConfig") {
    val localProperties = Properties().apply {
        rootProject.file("local.properties").takeIf { it.isFile }?.inputStream()?.use(::load)
    }
    val mdlKey = providers.environmentVariable("MDL_API_KEY").orElse(localProperties.getProperty("mdl.key") ?: "null")
    val traktId = providers.environmentVariable("TRAKT_CLIENT_ID").orElse(localProperties.getProperty("trakt.id") ?: "null")
    val output = layout.buildDirectory.dir("generated/buildConfig/kotlin")
    inputs.property("mdlKey", mdlKey)
    inputs.property("traktId", traktId)
    outputs.dir(output)
    doLast {
        fun literal(value: String) = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$") + "\""
        val file = output.get().file("com/lagradost/api/BuildConfig.kt").asFile
        file.parentFile.mkdirs()
        file.writeText(
            """
            |package com.lagradost.api
            |
            |object BuildConfig {
            |    val MDL_API_KEY: String = ${literal(mdlKey.get())}
            |    val TRAKT_CLIENT_ID: String = ${literal(traktId.get())}
            |}
            |""".trimMargin()
        )
    }
}

kotlin.sourceSets.named("main") {
    kotlin.srcDir(generateBuildConfig)
}
