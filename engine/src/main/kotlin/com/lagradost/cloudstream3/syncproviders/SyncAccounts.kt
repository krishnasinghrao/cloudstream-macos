package com.lagradost.cloudstream3.syncproviders

import com.lagradost.cloudstream3.utils.UiText

/*
 * Android app account-sync ABI (app/src/main/java/.../syncproviders). Extensions
 * such as CineStream bundle providers that read a signed-in user's sync library
 * (Simkl, AniList, …). The macOS engine has no sync-account sign-in, so these
 * types load with the same names and members and behave as "no account signed
 * in": authUser() is null and library reads return nothing. Only the members
 * extensions use are provided; add more only with a matching Android signature.
 */

/** Android: syncproviders/AuthAPI.kt */
abstract class AuthAPI {
    open val name: String = ""
    open val idPrefix: String = ""
    open val requiresLogin: Boolean = true
}

/** Android: syncproviders/AuthAPI.kt */
data class AuthUser(
    val name: String?,
    val id: Int,
    val profilePicture: String? = null,
    val profilePictureHeaders: Map<String, String>? = null,
)

/** Android: syncproviders/AuthAPI.kt (opaque here: no tokens exist on macOS). */
class AuthData

/** Android: syncproviders/AuthRepo.kt */
abstract class AuthRepo(open val api: AuthAPI) {
    val name get() = api.name
    val idPrefix get() = api.idPrefix
    val requiresLogin get() = api.requiresLogin
    val isAvailable get() = !api.requiresLogin || authUser() != null

    /** No sync accounts can be signed in on macOS. */
    fun authUser(): AuthUser? = null
}

/** Android: syncproviders/SyncAPI.kt */
abstract class SyncAPI : AuthAPI() {
    open suspend fun library(auth: AuthData?): LibraryMetadata? = null

    data class LibraryMetadata(
        val allLibraryLists: List<LibraryList>,
        val supportedListSorting: Set<Any>,
    )

    data class LibraryList(
        val name: UiText,
        val items: List<Any>,
    )
}

/** Android: syncproviders/SyncRepo.kt */
class SyncRepo(override val api: SyncAPI) : AuthRepo(api) {
    suspend fun library(): Result<SyncAPI.LibraryMetadata?> = runCatching { api.library(null) }
}

/** Android: syncproviders/AccountManager.kt (only the accounts extensions reference). */
abstract class AccountManager {
    companion object {
        val aniListApi = com.lagradost.cloudstream3.syncproviders.providers.AniListApi()
        val simklApi = com.lagradost.cloudstream3.syncproviders.providers.SimklApi()
    }
}
