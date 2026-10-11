pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
        // androidx.annotation only: a plain JVM jar, no Android SDK involved.
        google {
            content { includeGroup("androidx.annotation") }
        }
        // NiceHttp and NewPipeExtractor.
        maven("https://jitpack.io")
    }
}

rootProject.name = "CloudStream-macOS"

// Kotlin/JVM 17 only.
include(":library") // extension API: MainAPI, extractors, network stack
include(":engine")  // headless scraper daemon packed into daemon.jar
