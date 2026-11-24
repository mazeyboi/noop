#if os(iOS)
import NOOPExtras
import StrandDesign
import SwiftUI
import Vision
import VisionKit

/// Search: favourites and recents first, then the bundled generic foods (offline), then Open Food Facts.
struct FoodSearchView: View {
    @ObservedObject var app = ExtrasApp.shared
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var online: [Food] = []
    @State private var onlineState = ""
    @State private var picked: Food?
    @State private var custom = false

    var local: [Food] { GenericFoods.shared.search(query) }
    var mine: [Food] {
        let fav = (try? app.store.favourites()) ?? []
        let recent = (try? app.store.recentFoods(limit: 30)) ?? []
        let all = fav + recent.filter { r in !fav.contains { $0.id == r.id } }
        guard !query.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if !mine.isEmpty {
                Section(query.isEmpty ? "Favourites and recent" : "Yours") { ForEach(mine) { row($0) } }
            }
            if !query.isEmpty {
                Section("Generic foods") {
                    ForEach(local) { row($0) }
                    if local.isEmpty { Text("No match").foregroundStyle(StrandPalette.textTertiary) }
                }
                Section("Open Food Facts") {
                    if online.isEmpty {
                        Button(onlineState.isEmpty ? "Search Open Food Facts" : onlineState) { Task { await searchOnline() } }
                    }
                    ForEach(online) { row($0) }
                }
            }
            Section { Button("Create a custom food") { custom = true } }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "oats, chicken breast, skyr…")
        .onChange(of: query) { _, _ in online = []; onlineState = "" }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .navigationDestination(item: $picked) { f in AmountView(food: f, method: .search, onLogged: { dismiss() }) }
        .navigationDestination(isPresented: $custom) { CustomFoodView(barcode: nil) { f in picked = f; custom = false } }
    }

    func row(_ f: Food) -> some View {
        Button { picked = f } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(f.displayName).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary).lineLimit(2)
                Text("\(Int(f.per100.kcal.rounded())) kcal / 100 g" + (f.favourite ? " · ★" : ""))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    func searchOnline() async {
        onlineState = "Searching…"
        do {
            online = try await OpenFoodFacts(transport: app.transport, store: app.store).search(query)
            onlineState = online.isEmpty ? "No results online" : ""
        } catch {
            onlineState = "Offline. Try again later."
        }
    }
}

extension Food: Hashable {
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Choose how much, then log.
struct AmountView: View {
    @ObservedObject var app = ExtrasApp.shared
    @State var food: Food
    let method: EntryMethod
    var onLogged: () -> Void
    @State private var grams: Double = 100
    @State private var servings: Double = 1
    @State private var useServings = false
    @State private var meal = MealType.suggested(for: Date())
    @Environment(\.dismiss) var dismiss
    @State private var editing = false
    @State private var confirmDelete = false

    var amountG: Double { useServings ? servings * (food.servingG ?? 100) : grams }

    var body: some View {
        Form {
            Section {
                Text(food.displayName).font(StrandFont.headline)
                // Saved at once: it used to be lost unless you also tapped Log.
                Toggle("Favourite", isOn: Binding(get: { food.favourite },
                                                  set: { food.favourite = $0; try? app.store.save(food) }))
            }
            Section("Amount") {
                if let s = food.servingG, s > 0 {
                    Picker("Unit", selection: $useServings) {
                        Text("Grams").tag(false)
                        Text(food.servingName.map { "Servings (\($0))" } ?? "Servings (\(Int(s)) g)").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if useServings {
                    Stepper(value: $servings, in: 0.25...20, step: 0.25) { Text("\(servings.formatted()) × \(Int(food.servingG ?? 0)) g") }
                } else {
                    NumberRow("Grams", value: $grams)
                }
                Picker("Meal", selection: $meal) { ForEach(MealType.allCases) { Text($0.title).tag($0) } }
            }
            Section("This amount") { NutrientSummary(n: food.per100.per100(toGrams: amountG)) }
            Section {
                Button("Log") { log() }.bold().disabled(amountG <= 0)
            }
            if food.source == .custom {
                Section {
                    Button("Edit this food") { editing = true }
                    Button("Delete this food", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("Delete \(food.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                var f = food; f.deleted = true; try? app.store.save(f); dismiss()
                            }
                        } message: {
                            Text("Entries you already logged with it stay as they are.")
                        }
                }
            }
        }
        .navigationTitle("Amount")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $editing) {
            CustomFoodView(barcode: food.barcode, editing: food) { f in food = f; editing = false }
        }
        .onAppear {
            meal = MealType.suggested(for: app.logTime)
            if let s = food.servingG, s > 0 { grams = s }
        }
    }

    func log() {
        var f = food
        if f.source == .generic || f.source == .off {
            // keep a local copy so recents, favourites and sync have it
            f.updatedAt = Date()
        }
        try? app.store.save(f)
        let e = FoodEntry.new(at: app.logTime, meal: meal, method: method, items: [f.item(grams: amountG)])
        app.save(e)
        onLogged()
    }
}

/// A food that isn't in any database (or a barcode Open Food Facts doesn't know).
struct CustomFoodView: View {
    let barcode: String?
    /// Set to change an existing custom food instead of creating one.
    var editing: Food? = nil
    var onSaved: (Food) -> Void
    @ObservedObject var app = ExtrasApp.shared
    @State private var name = ""
    @State private var brand = ""
    @State private var per100 = Nutrients.zero
    @State private var serving: Double = 0
    @State private var saveError = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Brand (optional)", text: $brand)
                if let barcode { LabeledContent("Barcode", value: barcode) }
            }
            Section("Per 100 g (from the label)") {
                NumberRow("kcal", value: $per100.kcal)
                NumberRow("Protein g", value: $per100.proteinG)
                NumberRow("Carbs g", value: $per100.carbsG)
                NumberRow("Sugar g", value: $per100.sugarG)
                NumberRow("Fat g", value: $per100.fatG)
                NumberRow("Fibre g", value: $per100.fiberG)
                NumberRow("Salt g", value: $per100.saltG)
                NumberRow("Caffeine mg", value: $per100.caffeineMg)
                NumberRow("Alcohol g", value: $per100.alcoholG)
            }
            Section { NumberRow("Serving size g (optional)", value: $serving) }
            Section {
                Button("Save food") {
                    var f = editing ?? Food(name: "", barcode: barcode, source: .custom, per100: .zero)
                    f.name = name.trimmingCharacters(in: .whitespaces)
                    f.brand = brand.isEmpty ? nil : brand
                    f.per100 = per100
                    f.servingG = serving > 0 ? serving : nil
                    do { try app.store.save(f); onSaved(f) }
                    catch { saveError = "Couldn't save: \(error.localizedDescription)" }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                if !saveError.isEmpty { Text(saveError).font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical) }
            }
        }
        .navigationTitle(editing == nil ? "Custom food" : "Edit food")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let e = editing, name.isEmpty {
                name = e.name; brand = e.brand ?? ""; per100 = e.per100; serving = e.servingG ?? 0
            }
        }
    }
}

/// Barcode scan (VisionKit, on-device) -> local foods -> Open Food Facts -> custom food.
struct BarcodeLogView: View {
    @ObservedObject var app = ExtrasApp.shared
    @Environment(\.dismiss) var dismiss
    @State private var code: String?
    @State private var manual = ""
    @State private var status = ""
    @State private var found: Food?
    @State private var createCustom = false

    var scannerAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        VStack(spacing: 12) {
            if scannerAvailable && code == nil {
                BarcodeScanner { c in if code == nil { code = c; Task { await lookup(c) } } }
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if !scannerAvailable {
                Text("The camera scanner isn't available. Type the barcode instead.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            HStack {
                TextField("Barcode", text: $manual).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                Button("Look up") { code = manual; Task { await lookup(manual) } }.disabled(manual.isEmpty)
            }
            if !status.isEmpty { Text(status).font(StrandFont.subhead) }
            if code != nil {
                Button("Scan another") { code = nil; status = ""; manual = "" }.buttonStyle(.borderless)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .navigationDestination(item: $found) { f in AmountView(food: f, method: .barcode, onLogged: { dismiss() }) }
        .navigationDestination(isPresented: $createCustom) {
            CustomFoodView(barcode: code) { f in createCustom = false; found = f }
        }
    }

    func lookup(_ c: String) async {
        let c = c.trimmingCharacters(in: .whitespaces)
        if let local = try? app.store.food(barcode: c) { found = local; return }
        status = "Looking up \(c)…"
        do {
            if let f = try await OpenFoodFacts(transport: app.transport, store: app.store).product(barcode: c) {
                status = ""
                found = f
            } else {
                status = "Open Food Facts doesn't know \(c)."
                createCustom = true
            }
        } catch {
            status = "Offline: can't look up \(c) now. Create the food from its label, or try later."
            createCustom = true
        }
    }
}

struct BarcodeScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                if case .barcode(let b) = item, let v = b.payloadStringValue {
                    s.stopScanning()
                    onCode(v)
                    return
                }
            }
        }
    }
}
#endif
