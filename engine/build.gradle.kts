import java.security.MessageDigest
import java.util.HexFormat
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    application
}

val ktorVersion = libs.versions.ktor.get()
val okhttpVersion = "5.3.2"

// What is packed into daemon.jar is locked (gradle.lockfile). A dependency
// that resolves to another version fails the build until the lock is updated
// on purpose: ./gradlew :engine:dependencies --write-locks
configurations.matching { it.name == "runtimeClasspath" || it.name == "compileClasspath" }.configureEach {
    resolutionStrategy.activateDependencyLocking()
}

// org.json is part of Android itself, and extensions rely on its behaviour
// (lenient getString, insertion order). The engine ships AOSP's
// implementation (src/main/java/org/json); NiceHttp's JSON-java dependency,
// which behaves differently, must never shadow it.
configurations.configureEach {
    exclude(group = "org.json", module = "json")
}

// The engine runs on the bundled OpenJDK 17 runtime (Rules.md §4.2).
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

dependencies {
    // CloudStream provider engine: MainAPI, extractors, nicehttp network stack
    implementation(project(":library"))
    // `app` (the global nicehttp Requests client) is part of the public API surface
    implementation(libs.nicehttp)
    // NewPipeExtractor is delegated to by the official YouTube provider; the
    // daemon initializes it with its own OkHttp downloader (NewPipeBridge).
    implementation(libs.newpipeextractor)
    // Android DataStore exposes the stable mapper ABI to community extensions.
    implementation(libs.jackson.module.kotlin)
    // One OkHttp line for the daemon. NiceHttp already requires this line, so
    // a lower declaration here was only ever resolved upwards; declaring the
    // version that is actually packed keeps the build file honest.
    implementation("com.squareup.okhttp3:okhttp:$okhttpVersion")
    // DNS-over-HTTPS resolver picker (Android `DohProviders` parity).
    implementation("com.squareup.okhttp3:okhttp-dnsoverhttps:$okhttpVersion")
    // Security patch levels inside the lines already resolved (triage in
    // docs/Dependency-Review.md). Local to the daemon: the Android app's
    // catalog, and the Jackson 2.13 ABI extensions are compiled against, stay.
    implementation(platform("io.netty:netty-bom:4.2.19.Final"))
    constraints {
        implementation("com.fasterxml.jackson.core:jackson-databind:2.13.5")
        implementation("com.fasterxml.jackson.core:jackson-core:2.13.5")
        implementation("com.fasterxml.jackson.core:jackson-annotations:2.13.5")
    }
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)
    // Libraries the Android app ships, which extensions link against without bundling them.
    implementation("com.google.code.gson:gson:2.14.0")
    implementation("me.xdrop:fuzzywuzzy:1.4.0")
    implementation(libs.juniversalchardet)
    implementation(libs.kotlinx.collections.immutable)

    // Headless IPC server (loopback only, SEC-01)
    implementation("io.ktor:ktor-server-core:$ktorVersion")
    implementation("io.ktor:ktor-server-netty:$ktorVersion")
    implementation("io.ktor:ktor-server-content-negotiation:$ktorVersion")
    implementation("io.ktor:ktor-serialization-kotlinx-json:$ktorVersion")

    // .dex -> .jar translation for community .cs3 plugins (SEC-08 pipeline)
    implementation("de.femtopedia.dex2jar:dex-tools:2.4.38")

    testImplementation(libs.kotlin.test)
    testImplementation(libs.kotlinx.coroutines.test)
}

application {
    mainClass.set("com.lagradost.macos.MainKt")
}

// F_FULLFSYNC through JDK 17's foreign-function API (FullFsync.java); the
// engine is launched with the same flags (EngineJvmOptions in the app).
val foreignFunctionModule = "jdk.incubator.foreign"
tasks.withType<JavaCompile>().configureEach {
    options.compilerArgs.addAll(listOf("--add-modules", foreignFunctionModule))
}

tasks.withType<Test> {
    jvmArgs("--add-modules=$foreignFunctionModule", "--enable-native-access=ALL-UNNAMED")
    // Isolated filesystem root for tests (CloudDirs); never touches real ~/.cloudstream-macos.
    systemProperty("cs.cloudstream.home", layout.buildDirectory.dir("tmp/test-home").get().asFile.absolutePath)
    // RT-17 provisioning (scripts/run_full_client_tests.sh): where LocalMediaLinksTest writes its links.
    listOf("cs.exportLinks", "cs.exportOrigin").forEach { key -> System.getProperty(key)?.let { systemProperty(key, it) } }
    testLogging {
        events("passed", "failed", "skipped")
        showExceptions = true
        showStackTraces = true
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

/** Rebuild-only, never part of `build` or `test`: the committed .cs3 fixtures
 * stand in for extensions built by Android tooling, so regenerating them with
 * src/test/fixtures/kotlin/build.sh needs android.jar (API 35) and d8. */
val runtimeFixture = sourceSets.create("runtimeFixture") {
    val androidApi = providers.provider {
        val properties = Properties()
        rootProject.file("local.properties").takeIf { it.isFile }?.inputStream()?.use(properties::load)
        val sdk = System.getenv("ANDROID_SDK_ROOT") ?: System.getenv("ANDROID_HOME") ?: properties.getProperty("sdk.dir")
            ?: error("Set ANDROID_SDK_ROOT to rebuild Android fixtures")
        File(sdk, "platforms/android-35/android.jar").also { require(it.isFile) { "Android API 35 is required for fixture conformance" } }
    }
    // Put the SDK before host stubs so Context/SharedPreferences/Pair descriptors
    // are genuinely those extension authors compile against.
    compileClasspath = files(androidApi, sourceSets.main.get().output, configurations.runtimeClasspath)
}
kotlin.sourceSets.named("runtimeFixture") {
    kotlin.setSrcDirs(listOf("src/test/fixtures/kotlin/src"))
}
tasks.named<KotlinCompile>("compileRuntimeFixtureKotlin") {
    compilerOptions.jvmTarget.set(JvmTarget.JVM_11)
}
tasks.named<JavaCompile>("compileRuntimeFixtureJava") {
    options.release.set(11)
}
val writeRuntimeFixtureClasspath = tasks.register("writeRuntimeFixtureClasspath") {
    val classpathFiles = runtimeFixture.compileClasspath
    val paths = classpathFiles.elements.map { files -> files.map { it.asFile.absolutePath } }
    val output = layout.buildDirectory.file("fixtures/kotlin/classpath.txt")
    inputs.files(classpathFiles)
    outputs.file(output)
    doLast { output.get().asFile.apply { parentFile.mkdirs(); writeText(paths.get().joinToString("\n") + "\n") } }
}

/** Self-contained daemon.jar consumed by the macOS client's bundled runtime. */
tasks.jar {
    manifest {
        attributes["Main-Class"] = "com.lagradost.macos.MainKt"
        attributes["Multi-Release"] = "true"
    }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from(configurations.runtimeClasspath.get().map { if (it.isDirectory) it else zipTree(it) }) {
        exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA")
        exclude("module-info.class", "META-INF/versions/**/module-info.class")
    }
    archiveFileName.set("daemon.jar")
}

/**
 * Software bill of materials for daemon.jar (plan T8.4): CycloneDX 1.5 JSON
 * listing every resolved runtime dependency packed into the jar, with package
 * URL and SHA-256 of the exact artifact. `./gradlew :engine:sbom`.
 */
val sbom = tasks.register("sbom") {
    group = "verification"
    description = "Writes build/sbom/daemon.cdx.json (CycloneDX) for the daemon's runtime dependencies."
    // Configuration-cache safe: capture a provider of resolved artifacts, not the configuration.
    val resolved = configurations.runtimeClasspath.flatMap { it.incoming.artifacts.resolvedArtifacts }
    val output = layout.buildDirectory.file("sbom/daemon.cdx.json")
    // Single source of truth: HealthDto.DAEMON_VERSION.
    val componentVersion = Regex("""DAEMON_VERSION: String = "([^"]+)"""")
        .find(file("src/main/kotlin/com/lagradost/macos/models/EngineDtos.kt").readText())?.groupValues?.get(1)
        ?: error("HealthDto.DAEMON_VERSION is missing")
    inputs.files(configurations.runtimeClasspath)
    inputs.property("componentVersion", componentVersion)
    outputs.file(output)
    doLast {
        fun sha256(file: File): String = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(file.readBytes()))
        fun esc(value: String) = value.replace("\\", "\\\\").replace("\"", "\\\"")
        data class Entry(val group: String, val name: String, val version: String, val purl: String, val sha: String)
        val entries = resolved.get().map { artifact ->
            when (val id = artifact.id.componentIdentifier) {
                is org.gradle.api.artifacts.component.ModuleComponentIdentifier ->
                    Entry(id.group, id.module, id.version, "pkg:maven/${id.group}/${id.module}@${id.version}", sha256(artifact.file))
                else -> {
                    // In-repo project jar, e.g. library-jvm-1.0.1.jar.
                    val base = artifact.file.nameWithoutExtension
                    val match = Regex("""(.+)-(\d[\w.]*)""").matchEntire(base)
                    val name = match?.groupValues?.get(1) ?: base
                    val version = match?.groupValues?.get(2) ?: componentVersion
                    Entry("cloudstream", name, version, "pkg:generic/cloudstream/$name@$version", sha256(artifact.file))
                }
            }
        }.distinctBy { it.purl }.sortedBy { it.purl }
        val components = entries.joinToString(",\n") { e ->
            """    {"type":"library","group":"${esc(e.group)}","name":"${esc(e.name)}","version":"${esc(e.version)}",""" +
                """"purl":"${esc(e.purl)}","bom-ref":"${esc(e.purl)}","hashes":[{"alg":"SHA-256","content":"${e.sha}"}]}"""
        }
        val file = output.get().asFile
        file.parentFile.mkdirs()
        file.writeText("""{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "metadata": {"component": {"type": "application", "name": "cloudstream-macos-daemon", "version": "${esc(componentVersion)}"}},
  "components": [
$components
  ]
}
""")
        logger.lifecycle("SBOM: ${entries.size} components -> $file")
    }
}
