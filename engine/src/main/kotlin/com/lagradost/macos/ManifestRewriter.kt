package com.lagradost.macos

import java.io.StringReader
import java.io.StringWriter
import java.net.URI
import java.util.Locale
import javax.xml.XMLConstants
import javax.xml.parsers.DocumentBuilderFactory
import javax.xml.transform.OutputKeys
import javax.xml.transform.TransformerFactory
import javax.xml.transform.dom.DOMSource
import javax.xml.transform.stream.StreamResult
import org.w3c.dom.Element
import org.xml.sax.InputSource

/**
 * Rewrites an HLS playlist or a DASH manifest fetched by [MediaRelay] so that
 * every URL it names is read through the relay too: a manifest passed
 * through unchanged would send the player straight to the provider without
 * the headers it needs. [map] turns an absolute http(s) URL into a relay
 * path; anything that cannot be expressed that way refuses the manifest
 * (an unknown scheme, or a template identifier inside a host name).
 */
internal object ManifestRewriter {
    class Unsupported(reason: String) : Exception(reason)

    enum class Kind { HLS, DASH }

    fun kind(url: String, contentType: String?): Kind? {
        val type = contentType.orEmpty().lowercase(Locale.ROOT)
        val path = runCatching { URI(url).path.orEmpty().lowercase(Locale.ROOT) }.getOrDefault("")
        return when {
            "mpegurl" in type || path.endsWith(".m3u8") || path.endsWith(".m3u") -> Kind.HLS
            "dash+xml" in type || path.endsWith(".mpd") -> Kind.DASH
            else -> null
        }
    }

    fun rewrite(kind: Kind, text: String, manifestUrl: String, map: (String) -> String): String = when (kind) {
        Kind.HLS -> hls(text, URI(manifestUrl), map)
        Kind.DASH -> dash(text, URI(manifestUrl), map)
    }

    private val uriAttribute = Regex("""URI="([^"]*)"""")

    private fun absolute(base: URI, reference: String): String {
        val resolved = runCatching { base.resolve(reference.trim()) }.getOrNull() ?: throw Unsupported("reference")
        if (resolved.scheme?.lowercase(Locale.ROOT) !in setOf("http", "https") || resolved.host == null) throw Unsupported("scheme")
        return resolved.toString()
    }

    private fun hls(text: String, base: URI, map: (String) -> String): String {
        if (!text.trimStart().startsWith("#EXTM3U")) throw Unsupported("not a playlist")
        return text.lineSequence().joinToString("\n") { line ->
            val trimmed = line.trim()
            when {
                trimmed.isEmpty() -> line
                trimmed.startsWith("#") -> uriAttribute.replace(line) { "URI=\"" + map(absolute(base, it.groupValues[1])) + "\"" }
                else -> map(absolute(base, trimmed))
            }
        }
    }

    /** Attributes that may hold a segment URL (or a SegmentTemplate pattern). */
    private val segmentAttributes = listOf("media", "initialization", "sourceURL", "href", "index")

    /**
     * An absolute segment URL or template as a relay path. A template's
     * identifiers (`$Number$`, `$RepresentationID$`, `$Number%05d$`…) are not
     * part of a URL: the directory before the first one becomes a relay
     * directory resource and everything after it is kept verbatim, so the
     * player still expands the template, and the relay serves only paths
     * below that directory (credentials only on the manifest's own origin).
     */
    private fun absoluteSegment(value: String, base: URI, map: (String) -> String): String {
        val firstIdentifier = value.indexOf('$')
        if (firstIdentifier < 0) return map(absolute(base, value))
        val schemeEnd = value.indexOf("://") + 3
        val directoryEnd = value.lastIndexOf('/', firstIdentifier)
        if (directoryEnd < schemeEnd || value.indexOf('/', schemeEnd) > directoryEnd || value.indexOf('/', schemeEnd) < 0) {
            throw Unsupported("templated host") // An identifier inside the authority cannot be relayed.
        }
        val mapped = map(absolute(base, value.substring(0, directoryEnd + 1) + TEMPLATE_PLACEHOLDER))
        check(mapped.endsWith(TEMPLATE_PLACEHOLDER)) { "relay path" }
        return mapped.removeSuffix(TEMPLATE_PLACEHOLDER) + value.substring(directoryEnd + 1)
    }

    private const val TEMPLATE_PLACEHOLDER = "cs-template-segment"

    private fun dash(text: String, base: URI, map: (String) -> String): String {
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            isExpandEntityReferences = false
            isXIncludeAware = false
            setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true)
            setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
        }
        val document = runCatching { factory.newDocumentBuilder().parse(InputSource(StringReader(text))) }.getOrNull()
            ?: throw Unsupported("xml")
        val mpd = document.documentElement
        if (mpd.localName != "MPD") throw Unsupported("not an MPD")
        val all = mpd.getElementsByTagNameNS("*", "*")
        val elements = (0 until all.length).map { all.item(it) as Element } + mpd
        // Absolute segment URLs and templates (common on CDNs) become relay
        // paths too; relative ones resolve against the rewritten BaseURL below.
        for (element in elements) {
            for (attribute in segmentAttributes) {
                val value = element.getAttribute(attribute)
                if (value.startsWith("http://", true) || value.startsWith("https://", true)) {
                    element.setAttribute(attribute, absoluteSegment(value, base, map))
                }
            }
        }
        // Base URLs: absolute ones and the top level's (relative to the
        // manifest) become relay paths; nested relative ones then resolve
        // against those. Without one at the top, the manifest's own
        // directory is added, since relative references would otherwise
        // resolve against the relay path of the manifest itself.
        var topLevel = false
        for (element in elements.filter { it.localName == "BaseURL" || it.localName == "Location" }) {
            val value = element.textContent.trim()
            val absoluteValue = value.startsWith("http://", true) || value.startsWith("https://", true)
            val atTop = element.parentNode === mpd
            if (atTop && element.localName == "BaseURL") topLevel = true
            if (absoluteValue || atTop) element.textContent = map(absolute(base, value))
        }
        if (!topLevel) {
            val baseUrl = document.createElementNS(mpd.namespaceURI, mpd.prefix?.let { "$it:BaseURL" } ?: "BaseURL")
            baseUrl.textContent = map(absolute(base, "./"))
            mpd.insertBefore(baseUrl, mpd.firstChild)
        }
        val transformer = TransformerFactory.newInstance().apply {
            setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true)
        }.newTransformer()
        transformer.setOutputProperty(OutputKeys.ENCODING, "UTF-8")
        return StringWriter().also { transformer.transform(DOMSource(document), StreamResult(it)) }.toString()
    }
}
