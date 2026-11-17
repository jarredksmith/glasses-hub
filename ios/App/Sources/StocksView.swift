import SwiftUI
import HubCore

/// The symbols to follow, inside the Stocks app's settings.
struct StockSettings: View {
    @EnvironmentObject private var model: HubModel
    @State private var typed = ""
    @State private var problem = ""

    var body: some View {
        Section {
            ForEach(model.stockSymbols, id: \.self) { symbol in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Stocks.label(symbol))
                        if Stocks.label(symbol) != symbol { Text(symbol).font(.caption).foregroundStyle(.secondary) }
                        else if let name = model.stockQuotes[symbol]?.name, name != symbol { Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if let quote = model.stockQuotes[symbol] {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Stocks.money(quote.price)).monospacedDigit()
                            if let percent = quote.percent {
                                Text(String(format: "%+.2f%%", percent)).font(.caption).monospacedDigit()
                                    .foregroundStyle(percent >= 0 ? Color.green : Color.red)
                            }
                        }
                    }
                }
            }
            .onDelete { model.stockSymbols.remove(atOffsets: $0) }
            .onMove { model.stockSymbols.move(fromOffsets: $0, toOffset: $1) }
            HStack {
                TextField("Add: AAPL, TSLA, Nasdaq…", text: $typed)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .onSubmit(add)
                Button("Add", action: add).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !problem.isEmpty { Text(problem).font(.footnote).foregroundStyle(.secondary) }
            else if !model.stockNote.isEmpty { Text(model.stockNote).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            HStack { Text("Following"); Spacer(); EditButton().font(.footnote) }
        } footer: {
            Text("Type ticker symbols separated by commas. Names work for the main ones: Dow, S&P 500, Nasdaq, Russell 2000, VIX, Bitcoin, Gold, Oil. Swipe to remove; tap Edit to reorder. On the glasses: turn the crown for the next page.")
        }
        Section {
            Toggle("Show the first two on the dashboard", isOn: $model.dashStocks)
        } footer: {
            Text("Prices come from Yahoo Finance and can be delayed by 15 minutes or more. They refresh every minute while this app is showing. For a glance only, not for trading decisions.")
        }
    }

    private func add() {
        problem = model.addStocks(typed) ? "" : "That doesn't look like a ticker symbol."
        if problem.isEmpty { typed = "" }
    }
}
