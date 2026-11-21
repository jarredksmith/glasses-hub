package com.jarredsmith.glasseshub.core

import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

data class StockQuote(val symbol: String, val name: String, val price: Double,
                      /** The last close before today's session, when the source gives it. */
                      val previous: Double?, val currency: String) {
    val change: Double? get() = previous?.let { price - it }
    val percent: Double? get() = previous?.let { if (it != 0.0) (price - it) / it * 100 else null }
}

object Stocks {
    val defaults = listOf("^DJI", "^GSPC", "^IXIC")

    private val aliases = mapOf(
        "DOW" to "^DJI", "DOWJONES" to "^DJI", "DJIA" to "^DJI", "DJI" to "^DJI",
        "S&P" to "^GSPC", "S&P500" to "^GSPC", "SP500" to "^GSPC", "SPX" to "^GSPC", "GSPC" to "^GSPC",
        "NASDAQ" to "^IXIC", "IXIC" to "^IXIC", "COMP" to "^IXIC", "RUSSELL" to "^RUT", "RUSSELL2000" to "^RUT", "RUT" to "^RUT",
        "VIX" to "^VIX", "BITCOIN" to "BTC-USD", "BTC" to "BTC-USD", "ETHEREUM" to "ETH-USD", "ETH" to "ETH-USD",
        "GOLD" to "GC=F", "OIL" to "CL=F",
    )
    private val labels = mapOf(
        "^DJI" to "Dow", "^GSPC" to "S&P 500", "^IXIC" to "Nasdaq", "^RUT" to "Russell 2000", "^VIX" to "VIX",
        "BTC-USD" to "Bitcoin", "ETH-USD" to "Ethereum", "GC=F" to "Gold", "CL=F" to "Oil",
    )
    private fun squash(typed: String) = typed.uppercase().filter { !it.isWhitespace() }

    /** Turns what someone typed ("dow", "s&p 500", "aapl") into a ticker symbol. Null if it can't be one. */
    fun symbol(typed: String): String? {
        val text = squash(typed)
        if (text.isEmpty() || text.length > 12) return null
        aliases[text]?.let { return it }
        return if (text.all { it in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789^.-=" }) text else null
    }
    /** Symbols from a typed list separated by commas, spaces or new lines. */
    fun symbols(typed: String): List<String> {
        val out = ArrayList<String>()
        for (part in typed.split(',', '\n', ';')) {
            if (part.isBlank()) continue
            // "s&p 500" is one name; "aapl tsla" is two tickers
            val whole = symbol(part)
            val pieces = if (whole != null && aliases.containsKey(squash(part))) listOf(whole) else part.split(' ').filter { it.isNotEmpty() }.mapNotNull { symbol(it) }
            for (s in pieces) if (s !in out) out.add(s)
        }
        return out
    }
    fun label(symbol: String): String = labels[symbol] ?: symbol

    /** Yahoo Finance's chart data for one symbol: today's price and the previous close. */
    fun url(symbol: String): String = "https://query1.finance.yahoo.com/v8/finance/chart/${urlEncode(symbol)}?range=1d&interval=1d"

    fun parse(data: String): StockQuote? {
        val meta = Json.obj(data)?.get("chart").at("result").list()?.firstOrNull().at("meta").dict() ?: return null
        val symbol = meta["symbol"].str() ?: return null
        val price = (meta["regularMarketPrice"] as? Number)?.toDouble() ?: return null
        val previous = (meta["previousClose"] as? Number)?.toDouble() ?: (meta["chartPreviousClose"] as? Number)?.toDouble()
        return StockQuote(symbol, meta["shortName"].str() ?: meta["longName"].str() ?: symbol, price, previous, meta["currency"].str() ?: "")
    }

    /** A price with thousands separators: two decimals, or none once it's in the tens of thousands. */
    fun money(value: Double): String {
        val decimals = if (abs(value) >= 10_000) 0 else if (abs(value) < 1) 4 else 2
        val text = String.format(Locale.US, "%.${decimals}f", abs(value))
        val parts = text.split(".", limit = 2)
        var digits = parts[0]
        var whole = ""
        while (digits.length > 3) { whole = "," + digits.takeLast(3) + whole; digits = digits.dropLast(3) }
        whole = digits + whole
        return (if (value < 0) "-" else "") + whole + (if (parts.size > 1) "." + parts[1] else "")
    }

    internal fun move(quote: StockQuote, arrows: Boolean): String {
        val percent = quote.percent ?: return ""
        val size = String.format(Locale.US, "%.2f%%", abs(percent))
        return if (arrows) (if (percent >= 0) "↑" else "↓") + size else (if (percent >= 0) "+" else "-") + size
    }

    /** One line for a symbol: "Dow 44,210 ↑0.42%". */
    fun line(symbol: String, quote: StockQuote?, arrows: Boolean): String {
        if (quote == null) return label(symbol) + "  …"
        return listOf(label(symbol), money(quote.price), move(quote, arrows)).filter { it.isNotEmpty() }.joinToString(" ")
    }

    /** The markets screen. One symbol gets the screen to itself; more take a line each, a page at a time. */
    fun card(symbols: List<String>, quotes: Map<String, StockQuote>, note: String, page: Int, arrows: Boolean, screen: Screen): Card {
        if (symbols.isEmpty()) return Card(listOf("Stocks", "Add symbols in the app,", "under Apps > Stocks."))
        if (quotes.isEmpty() && note.isNotEmpty()) return Card(listOf("Stocks") + TextLayout.wrap(note, screen.columns, max(1, screen.rows - 1)))
        val only = if (symbols.size == 1) quotes[symbols[0]] else null
        if (only != null) {
            val lines = mutableListOf(label(symbols[0]), TextLayout.headline(money(only.price), screen))
            only.change?.let { lines.add((if (it >= 0) "+" else "") + money(it) + "  " + move(only, arrows)) }
            return Card(lines)
        }
        val room = max(1, screen.rows - 1)
        val pages = max(1, ceil(symbols.size.toDouble() / room).toInt())
        val at = page.mod(pages)
        val shown = symbols.subList(at * room, min(symbols.size, (at + 1) * room))
        val title = "Markets" + (if (pages > 1) "  ${at + 1}/$pages" else "")
        return Card(listOf(title) + shown.map { TextLayout.fit(line(it, quotes[it], arrows), screen.columns) })
    }
}
