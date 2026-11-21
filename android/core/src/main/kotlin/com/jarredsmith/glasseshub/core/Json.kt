package com.jarredsmith.glasseshub.core

/**
 * A small JSON reader and writer. Objects are maps, arrays are lists, numbers are Long or Double.
 * Written out with sorted keys so the same message is always the same bytes.
 */
object Json {
    fun encode(value: Any?): String = StringBuilder().also { write(value, it) }.toString()

    private fun write(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is Boolean -> out.append(if (value) "true" else "false")
            is Int, is Long, is Short, is Byte -> out.append(value.toString())
            is Number -> {
                val d = value.toDouble()
                if (d.isNaN() || d.isInfinite()) out.append("null")
                else if (d == Math.rint(d) && Math.abs(d) < 1e15) out.append(d.toLong().toString()) else out.append(d.toString())
            }
            is String -> quote(value, out)
            is Map<*, *> -> {
                out.append('{')
                var first = true
                for (key in value.keys.map { it.toString() }.sorted()) {
                    if (!first) out.append(',')
                    first = false
                    quote(key, out); out.append(':'); write(value[key], out)
                }
                out.append('}')
            }
            is Iterable<*> -> {
                out.append('[')
                var first = true
                for (item in value) { if (!first) out.append(','); first = false; write(item, out) }
                out.append(']')
            }
            else -> quote(value.toString(), out)
        }
    }

    private fun quote(text: String, out: StringBuilder) {
        out.append('"')
        for (ch in text) {
            when (ch) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> if (ch < ' ') out.append(String.format("\\u%04x", ch.code)) else out.append(ch)
            }
        }
        out.append('"')
    }

    /** The parsed value, or null when the text isn't JSON. */
    fun parse(text: String): Any? = try {
        val p = Parser(text)
        p.space()
        val v = p.value()
        p.space()
        if (p.i == text.length) v else null
    } catch (e: Exception) { null }

    @Suppress("UNCHECKED_CAST")
    fun obj(text: String): Map<String, Any?>? = parse(text) as? Map<String, Any?>

    private class Bad : Exception()

    private class Parser(val s: String) {
        var i = 0
        fun space() { while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) i++ }
        fun value(): Any? {
            if (i >= s.length) throw Bad()
            return when (s[i]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> word("true", true)
                'f' -> word("false", false)
                'n' -> word("null", null)
                else -> num()
            }
        }
        fun word(w: String, v: Any?): Any? { if (!s.startsWith(w, i)) throw Bad(); i += w.length; return v }
        fun obj(): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>()
            i++; space()
            if (i < s.length && s[i] == '}') { i++; return out }
            while (true) {
                space()
                if (i >= s.length || s[i] != '"') throw Bad()
                val key = str()
                space()
                if (i >= s.length || s[i] != ':') throw Bad()
                i++; space()
                out[key] = value()
                space()
                if (i >= s.length) throw Bad()
                if (s[i] == ',') { i++; continue }
                if (s[i] == '}') { i++; return out }
                throw Bad()
            }
        }
        fun arr(): List<Any?> {
            val out = ArrayList<Any?>()
            i++; space()
            if (i < s.length && s[i] == ']') { i++; return out }
            while (true) {
                space()
                out.add(value())
                space()
                if (i >= s.length) throw Bad()
                if (s[i] == ',') { i++; continue }
                if (s[i] == ']') { i++; return out }
                throw Bad()
            }
        }
        fun str(): String {
            val out = StringBuilder()
            i++
            while (true) {
                if (i >= s.length) throw Bad()
                val ch = s[i++]
                if (ch == '"') return out.toString()
                if (ch != '\\') { out.append(ch); continue }
                if (i >= s.length) throw Bad()
                when (val e = s[i++]) {
                    'n' -> out.append('\n'); 't' -> out.append('\t'); 'r' -> out.append('\r')
                    'b' -> out.append('\b'); 'f' -> out.append('\u000C')
                    'u' -> { if (i + 4 > s.length) throw Bad(); out.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4 }
                    else -> out.append(e)
                }
            }
        }
        fun num(): Any {
            val start = i
            while (i < s.length && (s[i].isDigit() || s[i] == '-' || s[i] == '+' || s[i] == '.' || s[i] == 'e' || s[i] == 'E')) i++
            if (i == start) throw Bad()
            val text = s.substring(start, i)
            return text.toLongOrNull() ?: text.toDoubleOrNull() ?: throw Bad()
        }
    }
}

// Reading values out of parsed JSON without a cast at every step.
@Suppress("UNCHECKED_CAST")
fun Any?.dict(): Map<String, Any?>? = this as? Map<String, Any?>
@Suppress("UNCHECKED_CAST")
fun Any?.list(): List<Any?>? = this as? List<Any?>
fun Any?.str(): String? = this as? String
fun Any?.bool(): Boolean? = this as? Boolean
/** A whole number, from a number or a string of digits. */
fun Any?.int(): Int? = when (this) {
    is Long -> if (this in Int.MIN_VALUE..Int.MAX_VALUE) this.toInt() else null
    is Int -> this
    is Double -> if (this == Math.rint(this) && Math.abs(this) < 1e15) this.toInt() else null
    is String -> this.trim().toIntOrNull()
    else -> null
}
fun Any?.num(): Double? = when (this) {
    is Number -> this.toDouble()
    is String -> this.trim().toDoubleOrNull()
    else -> null
}
/** One step into an object: the value under this key, or null when this isn't an object. */
fun Any?.at(key: String): Any? = (this as? Map<*, *>)?.get(key)
