package com.jarredsmith.glasseshub.core

import java.util.Locale
import java.util.UUID
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** Distances and directions on the ground. */
object Geo {
    private const val toRad = Math.PI / 180
    /** Metres between two points. */
    fun distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val dLat = (lat2 - lat1) * toRad; val dLon = (lon2 - lon1) * toRad
        val a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * toRad) * cos(lat2 * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_000.0 * atan2(sqrt(a), sqrt(1 - a))
    }
    /** Compass bearing in degrees from the first point to the second. */
    fun bearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val y = sin((lon2 - lon1) * toRad) * cos(lat2 * toRad)
        val x = cos(lat1 * toRad) * sin(lat2 * toRad) - sin(lat1 * toRad) * cos(lat2 * toRad) * cos((lon2 - lon1) * toRad)
        return (atan2(y, x) / toRad + 360) % 360
    }
    fun compass(degrees: Double): String = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")[((((degrees % 360) + 360) % 360 + 22.5) / 45).toInt() % 8]
    /** A distance for reading at a glance: "350 ft", "1.2 mi", "400 m", "2.1 km". */
    fun length(metres: Double, metric: Boolean): String {
        if (metric) return if (metres < 950) "${(metres / 10).rounded() * 10} m" else String.format(Locale.US, "%.1f km", metres / 1000)
        val feet = metres * 3.28084
        return if (feet < 900) "${(feet / 50).rounded() * 50} ft" else String.format(Locale.US, "%.1f mi", metres / 1609.344)
    }
}

// MARK: - Planes overhead

data class Aircraft(
    val id: String, val callsign: String, val type: String, val registration: String,
    /** Feet. */
    val altitude: Int?,
    /** Knots. */
    val speed: Int?, val track: Double?,
    /** Feet a minute. */
    val climb: Int?,
    /** Metres along the ground from the wearer, and the compass bearing to look along. */
    val distance: Double, val bearing: Double,
) {
    val name: String get() = callsign.ifEmpty { registration.ifEmpty { id.uppercase() } }
}

data class PlaneRoute(val from: String, val to: String, val airline: String)

object Planes {
    /** Aircraft within `miles` nautical miles of a point, from the adsb.lol community network. */
    fun url(latitude: Double, longitude: Double, miles: Int = 15): String = String.format(Locale.US, "https://api.adsb.lol/v2/lat/%.4f/lon/%.4f/dist/%d", latitude, longitude, miles)
    fun routeURL(callsign: String): String? {
        val safe = callsign.filter { it.isLetterOrDigit() }
        return if (safe.length >= 3) "https://api.adsbdb.com/v0/callsign/$safe" else null
    }

    /** Airborne aircraft from the network's answer, nearest first. */
    fun parse(data: String, latitude: Double, longitude: Double): List<Aircraft>? {
        val list = Json.obj(data)?.get("ac").list() ?: return null
        fun whole(value: Any?): Int? = (value as? Number)?.toDouble()?.rounded()
        val found = ArrayList<Aircraft>()
        for (item in list) {
            val lat = (item.at("lat") as? Number)?.toDouble() ?: continue
            val lon = (item.at("lon") as? Number)?.toDouble() ?: continue
            val altitude = whole(item.at("alt_baro")) ?: whole(item.at("alt_geom")) ?: continue      // "ground" or nothing: not overhead
            found.add(Aircraft(item.at("hex").str() ?: UUID.randomUUID().toString(), (item.at("flight").str() ?: "").trim(),
                item.at("t").str() ?: "", item.at("r").str() ?: "", altitude, whole(item.at("gs")), (item.at("track") as? Number)?.toDouble(),
                whole(item.at("baro_rate")) ?: whole(item.at("geom_rate")),
                Geo.distance(latitude, longitude, lat, lon), Geo.bearing(latitude, longitude, lat, lon)))
        }
        return found.sortedBy { it.distance }
    }

    /** Where a flight is going, from adsbdb's answer for its callsign. */
    fun route(data: String): PlaneRoute? {
        val route = Json.obj(data)?.get("response").at("flightroute").dict() ?: return null
        fun place(value: Any?): String {
            val airport = value.dict() ?: return ""
            val city = airport["municipality"].str() ?: airport["name"].str() ?: ""
            return city.ifEmpty { airport["iata_code"].str() ?: airport["icao_code"].str() ?: "" }
        }
        val from = place(route["origin"]); val to = place(route["destination"])
        if (from.isEmpty() || to.isEmpty()) return null
        return PlaneRoute(from, to, route["airline"].at("name").str() ?: "")
    }

    fun card(planes: List<Aircraft>, index: Int, routes: Map<String, PlaneRoute>, note: String, metric: Boolean, arrows: Boolean, screen: Screen): Card {
        val width = screen.columns
        if (planes.isEmpty()) return Card(listOf("Planes overhead") + TextLayout.wrap(note.ifEmpty { "Nothing in the air within 15 miles right now." }, width, max(1, screen.rows - 1)))
        val at = min(max(0, index), planes.size - 1)
        val plane = planes[at]
        val lines = mutableListOf(TextLayout.fit(plane.name + (if (plane.type.isEmpty()) "" else "  " + plane.type) + "   ${at + 1}/${planes.size}", width))
        routes[plane.callsign]?.let { route ->
            lines.add(TextLayout.fit(route.from + (if (arrows) " → " else " to ") + route.to, width))
            if (route.airline.isNotEmpty() && screen.rows >= 5) lines.add(TextLayout.fit(route.airline, width))
        }
        val flight = ArrayList<String>()
        plane.altitude?.let { flight.add(if (metric) "${(it * 0.3048 / 10).rounded() * 10} m" else "${(it / 100.0).rounded() * 100} ft") }
        plane.speed?.let { flight.add(if (metric) "${(it * 1.852).rounded()} km/h" else "${(it * 1.15078).rounded()} mph") }
        plane.climb?.let { if (abs(it) >= 300) flight.add(if (it > 0) (if (arrows) "↑" else "climbing") else (if (arrows) "↓" else "descending")) }
        if (flight.isNotEmpty()) lines.add(TextLayout.fit(flight.joinToString("  "), width))
        var where = Geo.length(plane.distance, metric) + " " + Geo.compass(plane.bearing)
        plane.track?.let { where += ", heading " + Geo.compass(it) }
        lines.add(TextLayout.fit(where, width))
        return Card(lines.take(screen.rows))
    }
}

// MARK: - Walking tour

data class NearbyPlace(val id: Int, val title: String, val summary: String, val latitude: Double, val longitude: Double, val distance: Double, val bearing: Double)

object Tour {
    /** Wikipedia articles about places within `radius` metres, with their opening sentences. */
    fun url(latitude: Double, longitude: Double, radius: Int = 1500, language: String = "en"): String =
        "https://$language.wikipedia.org/w/api.php?action=query&format=json&generator=geosearch" +
            "&ggscoord=" + urlEncode(String.format(Locale.US, "%.5f|%.5f", latitude, longitude)) + "&ggsradius=${min(10000, max(10, radius))}&ggslimit=20" +
            "&prop=" + urlEncode("extracts|coordinates") + "&exintro=1&explaintext=1&exsentences=4&exlimit=20&colimit=20"

    fun parse(data: String, latitude: Double, longitude: Double): List<NearbyPlace>? {
        val json = Json.obj(data) ?: return null
        val pages = json["query"].at("pages").dict() ?: return if (json.containsKey("batchcomplete")) emptyList() else null
        val found = ArrayList<NearbyPlace>()
        for (page in pages.values) {
            val id = page.at("pageid").int() ?: continue
            val title = page.at("title").str() ?: continue
            val spot = page.at("coordinates").list()?.firstOrNull() ?: continue
            val lat = (spot.at("lat") as? Number)?.toDouble() ?: continue
            val lon = (spot.at("lon") as? Number)?.toDouble() ?: continue
            val summary = (page.at("extract").str() ?: "").replace("\n", " ").trim()
            found.add(NearbyPlace(id, title, summary, lat, lon, Geo.distance(latitude, longitude, lat, lon), Geo.bearing(latitude, longitude, lat, lon)))
        }
        return found.sortedBy { it.distance }
    }

    /** The same places measured from a new position, nearest first. */
    fun moved(places: List<NearbyPlace>, latitude: Double, longitude: Double): List<NearbyPlace> =
        places.map { it.copy(distance = Geo.distance(latitude, longitude, it.latitude, it.longitude), bearing = Geo.bearing(latitude, longitude, it.latitude, it.longitude)) }.sortedBy { it.distance }

    fun whereLine(place: NearbyPlace, metric: Boolean): String = Geo.length(place.distance, metric) + " " + Geo.compass(place.bearing)

    fun listCard(places: List<NearbyPlace>, index: Int, note: String, metric: Boolean, screen: Screen): Card {
        val width = screen.columns
        if (places.isEmpty()) return Card(listOf("Walking tour") + TextLayout.wrap(note.ifEmpty { "Nothing with a Wikipedia page within a mile of here." }, width, max(1, screen.rows - 1)))
        val at = min(max(0, index), places.size - 1)
        val place = places[at]
        return Card(listOf("Nearby  ${at + 1}/${places.size}") + TextLayout.wrap(place.title, width, max(1, screen.rows - 3)) +
            listOf(whereLine(place, metric), if (place.summary.isEmpty()) "" else "Look up: read").filter { it.isNotEmpty() })
    }
}
