package com.lagradost.macos

import com.lagradost.macos.models.ErrorResponseDto
import com.lagradost.macos.models.ExtensionErrorDto
import com.lagradost.macos.models.ExtensionSettingsDto
import com.lagradost.macos.models.ExtensionSettingsUpdateDto
import com.lagradost.macos.models.InstallationRequestDto
import com.lagradost.macos.models.PluginConfigRequestDto
import com.lagradost.macos.models.PluginEnabledRequestDto
import com.lagradost.macos.models.PluginInstallRequestDto
import com.lagradost.macos.models.ProviderEnabledRequestDto
import com.lagradost.macos.models.ProviderInfoDto
import com.lagradost.macos.models.RepoConsentRequestDto
import com.lagradost.macos.models.RepoRemoveRequestDto
import com.lagradost.macos.models.RepoTrustRequestDto
import com.lagradost.macos.models.ReposImportRequestDto
import com.lagradost.macos.models.ReposSyncRequestDto
import com.lagradost.macos.models.UpdateAllRequestDto
import com.lagradost.macos.models.UpdateResultDto
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.RoutingContext
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.coroutines.CancellationException

/**
 * Repository and extension lifecycle routes (IPC v4). Handlers validate,
 * delegate to [RepositoryService] / [InstallationManager] and map failures to
 * typed errors; no lifecycle logic lives here.
 */
internal fun Route.extensionRoutes() {
    val manager = RepositoryService.installations

    get("/repos") {
        Metrics.recordRequest("repos")
        call.respond(RepositoryService.listRepositories())
    }

    post("/repos/import") {
        if (!limited("write")) return@post
        val request = call.receive<ReposImportRequestDto>()
        guarded { RepositoryService.importLegacyRepositories(request.urls); call.respond(mapOf("status" to "ok")) }
    }

    post("/repos/register") {
        Metrics.recordRequest("repos/register")
        if (!limited("write")) return@post
        val request = call.receive<ReposImportRequestDto>()
        guarded { call.respond(RepositoryService.registerRepositories(request.urls)) }
    }

    post("/repos/sync") {
        Metrics.recordRequest("repos/sync")
        if (!limited("sync")) return@post
        val request = call.receive<ReposSyncRequestDto>()
        guarded {
            val outcome = RepositoryService.sync(request.repoUrl)
            var failures = 0
            val settings = effectiveSettings()
            if (request.installAll || settings.autoUpdate) {
                val results = if (request.installAll) outcome.plugins.map { plugin ->
                    runCatching { manager.install(plugin.repositoryUrl ?: outcome.repository.url, plugin.internalName) }.exceptionOrNull()
                } else manager.updateAll(outcome.repository.url, actor = InstallationManager.AUTO_UPDATE_ACTOR).map { it.error }
                failures = results.count { it != null }
            }
            val refreshed = RepositoryService.listRepositories().firstOrNull { it.url == outcome.repository.url } ?: outcome.repository
            call.respond(refreshed.copy(error = refreshed.error ?: if (failures > 0) "$failures extension(s) could not be installed or updated" else null))
        }
    }

    post("/repos/consent") {
        if (!limited("write")) return@post
        val request = call.receive<RepoConsentRequestDto>()
        guarded { call.respond(RepositoryService.setConsent(request.repoUrl, request.allow)) }
    }

    get("/repos/plugins") {
        Metrics.recordRequest("repos/plugins")
        val repoUrl = call.request.queryParameters["repoUrl"]
        if (repoUrl.isNullOrBlank()) {
            call.respond(HttpStatusCode.BadRequest, ErrorResponseDto(error = "missing repoUrl parameter"))
            return@get
        }
        call.respond(RepositoryService.getRepoPlugins(repoUrl))
    }

    post("/repos/remove") {
        Metrics.recordRequest("repos/remove")
        if (!limited("write")) return@post
        val request = call.receive<RepoRemoveRequestDto>()
        guarded {
            if (manager.removeRepository(request.repoUrl, request.deleteDownloadedPlugins)) call.respond(mapOf("status" to "ok"))
            else throw ExtensionException(ExtensionException.Code.UNKNOWN_REPOSITORY, "This repository is not added.")
        }
    }

    post("/repos/trust") {
        Metrics.recordRequest("repos/trust")
        if (!limited("sync")) return@post
        val request = call.receive<RepoTrustRequestDto>()
        guarded { call.respond(RepositoryService.reTrust(request.repoUrl)) }
    }

    get("/plugins") {
        Metrics.recordRequest("plugins")
        call.respond(RepositoryService.installedPlugins())
    }

    post("/plugins/install") {
        Metrics.recordRequest("plugins/install")
        if (!limited("write")) return@post
        val request = call.receive<PluginInstallRequestDto>()
        guarded {
            val record = manager.install(request.repoUrl, request.internalName, request.pluginUrl, request.fileHash, request.allowDowngrade)
            call.respond(requireNotNull(RepositoryService.installedPlugin(record.id)))
        }
    }

    post("/plugins/update") {
        if (!limited("write")) return@post
        val request = call.receive<InstallationRequestDto>()
        guarded {
            val record = manager.update(request.installationId)
            call.respond(requireNotNull(RepositoryService.installedPlugin(record.id)))
        }
    }

    post("/plugins/updateAll") {
        if (!limited("write")) return@post
        val request = runCatching { call.receive<UpdateAllRequestDto>() }.getOrDefault(UpdateAllRequestDto())
        guarded { call.respond(manager.updateAll(request.repoUrl).map { UpdateResultDto(it.installationId, it.name, it.error) }) }
    }

    post("/plugins/rollback") {
        if (!limited("write")) return@post
        val request = call.receive<InstallationRequestDto>()
        guarded {
            val record = manager.rollback(request.installationId)
            call.respond(requireNotNull(RepositoryService.installedPlugin(record.id)))
        }
    }

    // ---- Extension settings (plan RT-15): the extension's own preference keys, typed, edited natively.

    get("/plugins/preferences") {
        Metrics.recordRequest("plugins/preferences")
        val id = call.request.queryParameters["installationId"].orEmpty()
        guarded { call.respond(ExtensionPreferences.describe(id)) }
    }

    post("/plugins/preferences") {
        Metrics.recordRequest("plugins/preferences")
        if (!limited("write")) return@post
        val request = call.receive<com.lagradost.macos.models.ExtensionPreferencesUpdateRequestDto>()
        guarded { call.respond(ExtensionPreferences.update(request.installationId, request.updates)) }
    }

    post("/plugins/retry") {
        if (!limited("write")) return@post
        val request = call.receive<InstallationRequestDto>()
        guarded {
            manager.retry(request.installationId)
            call.respond(requireNotNull(RepositoryService.installedPlugin(request.installationId)))
        }
    }

    post("/plugins/setEnabled") {
        Metrics.recordRequest("plugins/setEnabled")
        if (!limited("write")) return@post
        val request = call.receive<PluginEnabledRequestDto>()
        guarded {
            manager.setEnabled(request.installationId, request.enabled)
            call.respond(requireNotNull(RepositoryService.installedPlugin(request.installationId)))
        }
    }

    post("/plugins/uninstall") {
        Metrics.recordRequest("plugins/uninstall")
        if (!limited("write")) return@post
        val request = call.receive<InstallationRequestDto>()
        guarded {
            if (manager.uninstall(request.installationId)) call.respond(mapOf("status" to "ok"))
            else throw ExtensionException(ExtensionException.Code.UNKNOWN_EXTENSION, "Extension is not installed.")
        }
    }

    post("/plugins/config") {
        Metrics.recordRequest("plugins/config")
        if (!limited("write")) return@post
        val request = call.receive<PluginConfigRequestDto>()
        guarded {
            val provider = PluginBridge.findProvider(request.providerId)
            if (provider == null) {
                // Not loaded yet (background restore): credentials wait for the load; URLs need the live provider.
                val pending = if (request.url == null && !request.clearUrl) ProviderOverrides.configurePending(
                    request.providerId, request.credentials, request.reset, request.clearCredentials) else null
                call.respond(pending ?: throw ExtensionException(ExtensionException.Code.UNKNOWN_EXTENSION, "Unknown provider."))
                return@guarded
            }
            call.respond(ProviderOverrides.configure(provider, request.url, request.credentials, request.reset,
                request.clearUrl, request.clearCredentials))
        }
    }

    get("/providers/all") {
        call.respond(PluginBridge.allProviders().map { provider ->
            val id = PluginBridge.providerId(provider)
            ProviderInfoDto(
                name = provider.name, providerId = id, enabled = DaemonState.isProviderEnabled(id),
                plugin = provider.sourcePlugin, mainUrl = provider.mainUrl, language = provider.lang,
                tvTypes = provider.supportedTypes.map { it.name }.sorted(),
                hasMainPage = provider.hasMainPage, hasQuickSearch = provider.hasQuickSearch,
                vpnStatus = provider.vpnStatus.name,
            )
        }.sortedBy { it.name.lowercase() })
    }

    post("/providers/setEnabled") {
        if (!limited("write")) return@post
        val request = call.receive<ProviderEnabledRequestDto>()
        guarded {
            val provider = PluginBridge.allProviders().firstOrNull { PluginBridge.providerId(it) == request.providerId }
                ?: throw ExtensionException(ExtensionException.Code.UNKNOWN_EXTENSION, "Unknown provider.")
            DaemonState.setProviderEnabled(PluginBridge.providerId(provider), request.enabled)
            ProviderExecutor.invalidateProvider(PluginBridge.providerId(provider))
            AuditLog.record(if (request.enabled) "provider.enable" else "provider.disable", mapOf("provider" to request.providerId))
            call.respond(mapOf("status" to "ok"))
        }
    }

    get("/extensions/settings") { call.respond(effectiveSettings()) }

    post("/extensions/settings") {
        if (!limited("write")) return@post
        val request = call.receive<ExtensionSettingsUpdateDto>()
        guarded {
            request.autoUpdate?.let { autoUpdate ->
                if (DaemonRuntime.policy.autoUpdate != null) throw PolicyException("Automatic updates are managed by your organization.")
                DaemonState.update { it.copy(extensionSettings = it.extensionSettings.copy(autoUpdate = autoUpdate)) }
                AuditLog.record("settings.auto_update", mapOf("enabled" to autoUpdate))
            }
            request.developerMode?.let { enabled ->
                if (enabled) DaemonRuntime.policy.requireTier(DaemonState.TrustTier.DEVELOPER)
                DaemonState.update { it.copy(extensionSettings = it.extensionSettings.copy(developerMode = enabled)) }
                AuditLog.record("settings.developer_mode", mapOf("enabled" to enabled))
                manager.applyDeveloperMode()
            }
            call.respond(effectiveSettings())
        }
    }

    /** Developer mode (plan D5): import a local `.cs3` the user picked; never enabled automatically. */
    post("/extensions/developer/install") {
        if (!limited("write")) return@post
        val request = call.receive<com.lagradost.macos.models.DeveloperInstallRequestDto>()
        guarded {
            // SEC-07: Verify developer mode policy authorization before touching or probing host filesystem paths
            if (!DaemonState.snapshot().extensionSettings.developerMode) {
                throw ExtensionException(ExtensionException.Code.POLICY_DENIED, "Turn on developer mode to install extensions from files.")
            }
            DaemonRuntime.policy.requireRepository(DaemonState.DEVELOPER_SOURCE, userInitiated = false)
            DaemonRuntime.policy.requireTier(DaemonState.TrustTier.DEVELOPER)
            val path = java.nio.file.Path.of(request.path)
            require(path.isAbsolute && path.fileName?.toString()?.endsWith(".cs3") == true) { "Choose a .cs3 extension file." }
            require(java.nio.file.Files.isRegularFile(path, java.nio.file.LinkOption.NOFOLLOW_LINKS)) { "The file does not exist or is not a regular file." }
            require(java.nio.file.Files.size(path) <= RepositoryTransport.MAX_ARTIFACT_BYTES) { "The file is larger than 32 MiB." }
            val record = manager.installDeveloper(java.nio.file.Files.readAllBytes(path), path.fileName.toString())
            call.respond(requireNotNull(RepositoryService.installedPlugin(record.id)))
        }
    }

    post("/extensions/legacy/dismiss") {
        if (!limited("write")) return@post
        guarded { manager.dismissLegacyArtifacts(); call.respond(effectiveSettings()) }
    }

    get("/extensions/audit") {
        val limit = call.request.queryParameters["limit"]?.toIntOrNull() ?: 200
        call.respond(mapOf("verified" to AuditLog.verify().toString(), "entries" to AuditLog.recent(limit).joinToString("\n")))
    }
}

internal fun effectiveSettings(): ExtensionSettingsDto {
    val state = DaemonState.snapshot()
    val policy = DaemonRuntime.policy
    return ExtensionSettingsDto(
        autoUpdate = policy.autoUpdate ?: state.extensionSettings.autoUpdate,
        autoUpdateManaged = policy.autoUpdate != null,
        allowCommunityTier = policy.allowCommunityTier,
        allowLocalObservation = policy.allowLocalObservation,
        allowUserRepositories = policy.allowUserRepositories,
        policyManaged = policy.managed,
        safeMode = DaemonRuntime.safeMode,
        legacyArtifactsPending = state.unmatchedLegacyArtifacts.size,
        developerMode = state.extensionSettings.developerMode && policy.allowDeveloperExtensions,
        developerModeAllowed = policy.allowDeveloperExtensions,
        lastBackgroundRefresh = BackgroundRefresh.last?.let {
            com.lagradost.macos.models.BackgroundRefreshDto(it.at, it.repositories, it.syncFailures, it.updated, it.updateFailures)
        },
    )
}

private suspend fun RoutingContext.limited(group: String): Boolean {
    if (RateLimiter.check(group)) return true
    call.respond(HttpStatusCode.TooManyRequests, ExtensionErrorDto(error = "Too many requests; slow down.", code = "rate_limited"))
    return false
}

/** Maps every failure to a typed error; cancellation propagates. */
private suspend fun RoutingContext.guarded(block: suspend () -> Unit) {
    try {
        block()
    } catch (failure: Throwable) {
        if (failure is CancellationException && failure !is kotlinx.coroutines.TimeoutCancellationException) throw failure
        if (failure is VirtualMachineError && failure !is StackOverflowError) throw failure
        val mapped = if (failure is kotlinx.coroutines.TimeoutCancellationException)
            ExtensionException(ExtensionException.Code.DOWNLOAD_FAILED, "The repository did not respond in time.", failure)
        else ExtensionException.from(failure)
        if (mapped.code.httpStatus >= 500 || mapped.code == ExtensionException.Code.LOAD_FAILED) {
            DaemonLog.warn("extension.route_failed", mapOf("code" to mapped.code.wire, "error" to failure.javaClass.simpleName))
        }
        call.respond(HttpStatusCode.fromValue(mapped.code.httpStatus),
            ExtensionErrorDto(error = mapped.message ?: "Operation failed", code = mapped.code.wire, detail = null))
    }
}
