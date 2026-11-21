#if os(iOS)
import NOOPExtras
import StrandDesign
import SwiftUI

/// Just a number of kcal (and optional macros) when there's no time for anything else.
struct QuickAddView: View {
    @ObservedObject var app = ExtrasApp.shared
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var n = Nutrients.zero
    @State private var meal = MealType.suggested(for: Date())

    var body: some View {
        Form {
            Section {
                NumberRow("kcal", value: $n.kcal)
                TextField("What was it? (optional)", text: $name)
                Picker("Meal", selection: $meal) { ForEach(MealType.allCases) { Text($0.title).tag($0) } }
            }
            Section("Optional") {
                NumberRow("Protein g", value: $n.proteinG)
                NumberRow("Carbs g", value: $n.carbsG)
                NumberRow("Fat g", value: $n.fatG)
                NumberRow("Caffeine mg", value: $n.caffeineMg)
                NumberRow("Alcohol g", value: $n.alcoholG)
            }
            Section {
                Button("Log") {
                    let e = FoodEntry.new(at: app.logTime, meal: meal, method: .quick_add, items: [
                        EntryItem(name: name.isEmpty ? "Quick add" : name, grams: nil, nutrients: n),
                    ])
                    app.save(e)
                    dismiss()
                }
                .bold()
                .disabled(n.kcal <= 0 && n.caffeineMg <= 0 && n.alcoholG <= 0)
            }
        }
        .navigationTitle("Quick add")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear { meal = MealType.suggested(for: app.logTime) }
    }
}

/// One tap per drink. Defaults are editable in Food settings.
struct DrinksView: View {
    @ObservedObject var app = ExtrasApp.shared
    @Environment(\.dismiss) var dismiss
    @State private var logged: String?

    var body: some View {
        List {
            Section {
                ForEach(Drinks.load(store: app.store)) { d in
                    Button {
                        app.save(d.entry(at: app.logTime, meal: MealType.suggested(for: app.logTime)))
                        logged = d.name
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                Text(detail(d)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill").foregroundStyle(StrandPalette.accent)
                        }
                    }
                }
            } footer: {
                if let logged { Text("Logged \(logged.lowercased()).") }
            }
        }
        .navigationTitle("Drinks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    func detail(_ d: DrinkPreset) -> String {
        var parts = ["\(Int(d.ml)) ml", "\(Int(d.kcal)) kcal"]
        if d.caffeineMg > 0 { parts.append("\(Int(d.caffeineMg)) mg caffeine") }
        if d.alcoholG > 0 { parts.append("\(d.alcoholG.gramsText) alcohol") }
        return parts.joined(separator: " · ")
    }
}

/// Meals saved from an entry ("Save as a meal…"), logged again with one tap.
struct SavedMealsView: View {
    @ObservedObject var app = ExtrasApp.shared
    @Environment(\.dismiss) var dismiss
    @State private var meals: [SavedMeal] = []

    var body: some View {
        List {
            if meals.isEmpty {
                Text("No saved meals yet. Open any entry and choose “Save as a meal…”.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(meals) { m in
                Button {
                    _ = try? app.store.logSavedMeal(m, at: app.logTime, meal: MealType.suggested(for: app.logTime))
                    app.reload()
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(m.name).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Text(EntryItem.total(m.items).kcal.kcalText + " · " + m.items.map(\.name).joined(separator: ", "))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(2)
                    }
                }
            }
            .onDelete { idx in
                for i in idx { var m = meals[i]; m.deleted = true; try? app.store.save(m) }
                load()
            }
        }
        .navigationTitle("Saved meals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onAppear(perform: load)
    }

    func load() { meals = (try? app.store.savedMeals()) ?? [] }
}
#endif
