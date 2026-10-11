package com.lagradost.cloudstream3.extractors

import com.lagradost.cloudstream3.utils.ExtractorApi
import com.lagradost.cloudstream3.utils.ExtractorLink

open class GMPlayer : ExtractorApi() {
    override val name = "GM Player"
    override val mainUrl = "https://gmplayer.xyz"
    override val requiresReferer = true
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Vidstream : ExtractorApi() {
    override val name = "Vidstream"
    override val mainUrl = "https://vidstream.pro"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Pelisplus : ExtractorApi() {
    override val name = "Pelisplus"
    override val mainUrl = "https://pelisplus.so"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class AStreamHub : ExtractorApi() {
    override val name = "AStreamHub"
    override val mainUrl = "https://astreamhub.com"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class BullStream : ExtractorApi() {
    override val name = "BullStream"
    override val mainUrl = "https://bullstream.xyz"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class ByteShare : ExtractorApi() {
    override val name = "ByteShare"
    override val mainUrl = "https://byteshare.com"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class EPlay : ExtractorApi() {
    override val name = "EPlay"
    override val mainUrl = "https://eplay.com"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class GuardareStream : ExtractorApi() {
    override val name = "GuardareStream"
    override val mainUrl = "https://guardarestream.com"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Jawcloud : ExtractorApi() {
    override val name = "Jawcloud"
    override val mainUrl = "https://jawcloud.co"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Okrulink : ExtractorApi() {
    override val name = "Okrulink"
    override val mainUrl = "https://okru.link"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Solidfiles : ExtractorApi() {
    override val name = "Solidfiles"
    override val mainUrl = "https://solidfiles.com"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Tomatomatela : ExtractorApi() {
    override val name = "Tomatomatela"
    override val mainUrl = "https://tomatomatela.com"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class VideoVard : ExtractorApi() {
    override val name = "VideoVard"
    override val mainUrl = "https://videovard.sx"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Vidguard : ExtractorApi() {
    override val name = "Vidguard"
    override val mainUrl = "https://vidguard.to"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class WcoStream : ExtractorApi() {
    override val name = "WcoStream"
    override val mainUrl = "https://wcostream.tv"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Zorofile : ExtractorApi() {
    override val name = "Zorofile"
    override val mainUrl = "https://zorofile.com"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Chillx : ExtractorApi() {
    override val name = "Chillx"
    override val mainUrl = "https://chillx.top"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class VidSrcExtractor : ExtractorApi() {
    override val name = "VidSrc"
    override val mainUrl = "https://vidsrc.me"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class VidSrcTo : ExtractorApi() {
    override val name = "VidSrcTo"
    override val mainUrl = "https://vidsrc.to"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Vidplay : ExtractorApi() {
    override val name = "Vidplay"
    override val mainUrl = "https://vidplay.online"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class AsianLoad : ExtractorApi() {
    override val name = "AsianLoad"
    override val mainUrl = "https://asianload.io"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Mcloud : ExtractorApi() {
    override val name = "Mcloud"
    override val mainUrl = "https://mcloud.to"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class SpeedoStream : ExtractorApi() {
    override val name = "SpeedoStream"
    override val mainUrl = "https://speedostream.com"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class FEmbed : ExtractorApi() {
    override val name = "FEmbed"
    override val mainUrl = "https://fembed.com"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Bigwarp : ExtractorApi() {
    override val name = "Bigwarp"
    override val mainUrl = "https://bigwarp.io"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Minoplres : ExtractorApi() {
    override val name = "Minoplres"
    override val mainUrl = "https://minoplres.xyz"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class MultiQuality : ExtractorApi() {
    override val name = "MultiQuality"
    override val mainUrl = "https://multiquality.xyz"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class VidNest : ExtractorApi() {
    override val name = "VidNest"
    override val mainUrl = "https://vidnest.io"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Shiro : ExtractorApi() {
    override val name = "Shiro"
    override val mainUrl = "https://shiro.is"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class FeHD : ExtractorApi() {
    override val name = "FeHD"
    override val mainUrl = "https://fehd.net"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

open class Fplayer : ExtractorApi() {
    override val name = "Fplayer"
    override val mainUrl = "https://fplayer.info"
    override val requiresReferer = false
    override suspend fun getUrl(url: String, referer: String?): List<ExtractorLink>? = null
}

