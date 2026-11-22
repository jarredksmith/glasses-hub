package com.jarredsmith.glasseshub

import com.jarredsmith.glasseshub.core.Json
import com.jarredsmith.glasseshub.core.SubtitleFile
import com.jarredsmith.glasseshub.core.at
import com.jarredsmith.glasseshub.core.bool
import com.jarredsmith.glasseshub.core.int
import com.jarredsmith.glasseshub.core.list
import com.jarredsmith.glasseshub.core.str
import com.jarredsmith.glasseshub.core.urlEncode
import java.util.Locale

/** Finds and downloads subtitle files from OpenSubtitles.com. */
object SubtitleSearch {
    class Title(val id: Int, val title: String, val year: String, val isSeries: Boolean)
    class Version(/** The file to download. */ val id: Int, val release: String, val downloads: Int, val hearingImpaired: Boolean)
    class Language(val code: String, val name: String, val speech: String)

    val languages = listOf(
        Language("en", "English", "en-US"), Language("es", "Spanish", "es-ES"), Language("fr", "French", "fr-FR"),
        Language("de", "German", "de-DE"), Language("it", "Italian", "it-IT"), Language("pt-br", "Portuguese", "pt-BR"),
        Language("nl", "Dutch", "nl-NL"), Language("sv", "Swedish", "sv-SE"),
    )
    fun speech(code: String): String = languages.firstOrNull { it.code == code }?.speech ?: "en-US"

    /** A key that came with the app, if this build has one. */
    val builtInKey: String get() = BuildConfig.SUBTITLE_KEY.trim()

    private fun headers(key: String) = mapOf("Api-Key" to key, "User-Agent" to "GlassesHub v2.0", "Accept" to "application/json")
    private fun address(path: String, query: Map<String, String>): String {
        // the service wants its parameters in alphabetical order and lower case
        val q = query.toSortedMap().entries.joinToString("&") { it.key + "=" + urlEncode(it.value.lowercase(Locale.US)) }
        return "https://api.opensubtitles.com/api/v1/$path" + (if (q.isEmpty()) "" else "?$q")
    }
    private fun problem(answer: Http.Answer): String {
        val message = answer.text?.let { Json.obj(it) }?.get("message").str()
        return when (answer.status) {
            0 -> "Couldn't reach the subtitle service. Check the connection."
            401, 403 -> "The subtitle service didn't accept the search key."
            406 -> message ?: "Today's download limit is used up. Try again tomorrow."
            429 -> "Too many searches at once. Wait a moment and try again."
            else -> message ?: "The subtitle service had a problem (${answer.status})."
        }
    }

    /** Movies and shows whose name matches. `done` gets the list, or what went wrong. */
    fun titles(query: String, key: String, done: (List<Title>, String?) -> Unit) {
        Http.get(address("features", mapOf("query" to query)), headers(key)) { answer ->
            if (answer.status !in 200..299) { done(emptyList(), problem(answer)); return@get }
            val known = ArrayList<Title>(); val obscure = ArrayList<Title>()
            for (item in Json.obj(answer.text ?: "")?.get("data").list() ?: emptyList()) {
                val fields = item.at("attributes")
                val id = fields.at("feature_id").int() ?: item.at("id").int() ?: continue
                // a plain search says what each result is in "feature_type"; a search for shows only says it outside
                val kind = (fields.at("feature_type").str() ?: item.at("type").str() ?: "").lowercase()
                if (kind == "episode") continue
                val original = (fields.at("original_title").str() ?: "").trim()
                val title = original.ifEmpty { (fields.at("title").str() ?: "").split(" ").joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } } }
                if (title.isEmpty()) continue
                val series = kind == "tvshow"
                val found = Title(id, title, fields.at("year").str() ?: fields.at("year").int()?.toString() ?: "", series)
                // the ones people actually watch first: shows with seasons, films with plenty of subtitles
                val popular = if (series) (fields.at("seasons_count").int() ?: fields.at("seasons").list()?.size ?: 0) > 0 && original.isNotEmpty() else (fields.at("subtitles_count").int() ?: 0) >= 20
                if (popular) known.add(found) else obscure.add(found)
            }
            done(known + obscure, null)
        }
    }

    /** The subtitle files there are for a movie, or one episode of a show, most downloaded first. */
    fun versions(title: Title, season: Int, episode: Int, language: String, key: String, done: (List<Version>, String?) -> Unit) {
        val query = HashMap(mapOf("languages" to language, "order_by" to "download_count", "order_direction" to "desc"))
        if (title.isSeries) { query["parent_feature_id"] = "${title.id}"; query["season_number"] = "$season"; query["episode_number"] = "$episode" } else query["id"] = "${title.id}"
        Http.get(address("subtitles", query), headers(key)) { answer ->
            if (answer.status !in 200..299) { done(emptyList(), problem(answer)); return@get }
            val out = ArrayList<Version>()
            for (item in Json.obj(answer.text ?: "")?.get("data").list() ?: emptyList()) {
                val fields = item.at("attributes")
                val file = fields.at("files").list()?.firstOrNull() ?: continue
                val id = file.at("file_id").int() ?: continue
                out.add(Version(id, fields.at("release").str() ?: file.at("file_name").str() ?: "Subtitles", fields.at("download_count").int() ?: 0, fields.at("hearing_impaired").bool() ?: false))
            }
            done(out, null)
        }
    }

    /** The text of one subtitle file. */
    fun download(version: Version, key: String, done: (String?, String?) -> Unit) {
        Http.post(address("download", emptyMap()), headers(key) + ("Content-Type" to "application/json"), Json.encode(mapOf("file_id" to version.id, "sub_format" to "srt"))) { answer ->
            if (answer.status !in 200..299) { done(null, problem(answer)); return@post }
            val link = Json.obj(answer.text ?: "")?.get("link").str()
            if (link == null) { done(null, "The subtitle service didn't send the file."); return@post }
            Http.get(link) { file ->
                val bytes = file.bytes
                if (file.status in 200..299 && bytes != null) done(SubtitleFile.decode(bytes), null) else done(null, "The download didn't finish. Try again.")
            }
        }
    }
}
