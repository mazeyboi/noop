import SwiftUI
import NutritionCore
import StrandDesign

struct NutritionQuickAddView: View {
    let onAdd: (NutritionPlateItem) -> Void

    @State private var name = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbohydrates = ""
    @State private var fat = ""

    private var macros: NutritionMacros? {
        guard let calories = positiveNumber(calories) else { return nil }
        let result = NutritionMacros(
            calories: calories,
            protein: optionalNumber(protein) ?? 0,
            carbohydrates: optionalNumber(carbohydrates) ?? 0,
            fat: optionalNumber(fat) ?? 0
        )
        return result.isValid ? result : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            Text("One-off totals").strandOverline()
            NutritionTextField(title: "Name (optional)", text: $name)
            NutritionNumberField(title: "Calories", text: $calories)
            HStack(spacing: NoopMetrics.space2) {
                NutritionNumberField(title: "Protein", text: $protein, suffix: "g")
                NutritionNumberField(title: "Carbs", text: $carbohydrates, suffix: "g")
                NutritionNumberField(title: "Fat", text: $fat, suffix: "g")
            }

            if let macros, macros.approximateMacroCalories > 0 {
                Text("Macros contribute about \(whole(macros.approximateMacroCalories)) kcal")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }

            NoopButton("Add to Plate", systemImage: "plus", kind: .primary, fullWidth: true) {
                guard let macros else { return }
                onAdd(.quickAdd(name: name, macros: macros))
                name = ""
                calories = ""
                protein = ""
                carbohydrates = ""
                fat = ""
            }
            .disabled(macros == nil)

            Text("Quick Add stays out of the searchable food library.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

struct NutritionCustomFoodSheet: View {
    let existing: NutritionFood?
    let onSave: (NutritionFood) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var brand: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbohydrates: String
    @State private var fat: String
    @State private var servingGrams: String
    @State private var unitSingular: String
    @State private var unitPlural: String
    @State private var barcode: String

    init(existing: NutritionFood? = nil, onSave: @escaping (NutritionFood) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let grams = existing?.serving?.grams ?? 100
        let scale = grams / 100
        _name = State(initialValue: existing?.name ?? "")
        _brand = State(initialValue: existing?.brand ?? "")
        _calories = State(initialValue: decimal((existing?.nutrientsPer100Grams.calories ?? 0) * scale))
        _protein = State(initialValue: decimal((existing?.nutrientsPer100Grams.protein ?? 0) * scale))
        _carbohydrates = State(initialValue: decimal((existing?.nutrientsPer100Grams.carbohydrates ?? 0) * scale))
        _fat = State(initialValue: decimal((existing?.nutrientsPer100Grams.fat ?? 0) * scale))
        _servingGrams = State(initialValue: decimal(grams))
        _unitSingular = State(initialValue: existing?.serving?.unitSingular ?? "serving")
        _unitPlural = State(initialValue: existing?.serving?.unitPlural ?? "servings")
        _barcode = State(initialValue: existing?.barcode ?? "")
    }

    private var food: NutritionFood? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let grams = positiveNumber(servingGrams),
              let calories = nonnegativeNumber(calories) else { return nil }
        let servingMacros = NutritionMacros(
            calories: calories,
            protein: optionalNumber(protein) ?? 0,
            carbohydrates: optionalNumber(carbohydrates) ?? 0,
            fat: optionalNumber(fat) ?? 0
        )
        guard servingMacros.isValid else { return nil }
        let singular = unitSingular.trimmingCharacters(in: .whitespacesAndNewlines)
        let plural = unitPlural.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singular.isEmpty, !plural.isEmpty else { return nil }
        return NutritionFood(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            brand: normalized(brand),
            nutrientsPer100Grams: servingMacros.scaled(by: 100 / grams),
            serving: NutritionServing(
                amount: 1,
                unitSingular: singular,
                unitPlural: plural,
                grams: grams
            ),
            source: .custom,
            barcode: normalized(barcode),
            isFavourite: existing?.isFavourite ?? false,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date()
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Text("Food").strandOverline()
                    NutritionTextField(title: "Name", text: $name)
                    NutritionTextField(title: "Brand (optional)", text: $brand)

                    Text("Nutrition per serving").strandOverline()
                    NutritionNumberField(title: "Calories", text: $calories)
                    HStack(spacing: NoopMetrics.space2) {
                        NutritionNumberField(title: "Protein", text: $protein, suffix: "g")
                        NutritionNumberField(title: "Carbs", text: $carbohydrates, suffix: "g")
                        NutritionNumberField(title: "Fat", text: $fat, suffix: "g")
                    }

                    Text("Serving").strandOverline()
                    NutritionNumberField(title: "Grams", text: $servingGrams, suffix: "g")
                    HStack(spacing: NoopMetrics.space2) {
                        NutritionTextField(title: "Unit", text: $unitSingular)
                        NutritionTextField(title: "Plural", text: $unitPlural)
                    }
                    NutritionTextField(title: "Barcode (optional)", text: $barcode)
                }
                .padding(NoopMetrics.space5)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(existing == nil ? "Custom Food" : "Edit Food")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let food else { return }
                        onSave(food)
                        dismiss()
                    }
                    .disabled(food == nil)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }
}

struct NutritionPlateItemEditor: View {
    let item: NutritionPlateItem
    let onSave: (NutritionPlateItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var grams: String
    @State private var servingUnits: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbohydrates: String
    @State private var fat: String

    init(item: NutritionPlateItem, onSave: @escaping (NutritionPlateItem) -> Void) {
        self.item = item
        self.onSave = onSave
        _name = State(initialValue: item.name)
        _grams = State(initialValue: item.quantityGrams.map(decimal) ?? "")
        _servingUnits = State(initialValue: {
            guard let grams = item.quantityGrams,
                  let units = item.serving?.unitCount(forGrams: grams) else { return "" }
            return decimal(units)
        }())
        _calories = State(initialValue: decimal(item.macros.calories))
        _protein = State(initialValue: decimal(item.macros.protein))
        _carbohydrates = State(initialValue: decimal(item.macros.carbohydrates))
        _fat = State(initialValue: decimal(item.macros.fat))
    }

    private var editedItem: NutritionPlateItem? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let calories = nonnegativeNumber(calories) else { return nil }
        let macros = NutritionMacros(
            calories: calories,
            protein: optionalNumber(protein) ?? 0,
            carbohydrates: optionalNumber(carbohydrates) ?? 0,
            fat: optionalNumber(fat) ?? 0
        )
        guard macros.isValid else { return nil }
        var copy = item
        copy.name = trimmedName
        copy.baseMacros = macros
        if item.quantityGrams != nil {
            guard let grams = positiveNumber(grams) else { return nil }
            copy.baseQuantityGrams = grams
            copy.quantityGrams = grams
        } else {
            copy.baseQuantityGrams = nil
            copy.quantityGrams = nil
        }
        return copy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    NutritionTextField(title: "Name", text: $name)
                    if item.quantityGrams != nil {
                        NutritionNumberField(title: "Quantity", text: $grams, suffix: "g")
                        if let serving = item.serving {
                            NutritionNumberField(title: serving.unitPlural.capitalized, text: $servingUnits)
                        }
                    }
                    NutritionNumberField(title: "Calories", text: $calories)
                    HStack(spacing: NoopMetrics.space2) {
                        NutritionNumberField(title: "Protein", text: $protein, suffix: "g")
                        NutritionNumberField(title: "Carbs", text: $carbohydrates, suffix: "g")
                        NutritionNumberField(title: "Fat", text: $fat, suffix: "g")
                    }
                    if item.source == .geminiEstimate {
                        Text("AI values are estimates. Confirm each amount before logging.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .padding(NoopMetrics.space5)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Edit Plate Item")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let editedItem else { return }
                        onSave(editedItem)
                        dismiss()
                    }
                    .disabled(editedItem == nil)
                }
            }
        }
        .onChange(of: grams) { value in
            guard let originalGrams = item.quantityGrams,
                  originalGrams > 0,
                  let newGrams = positiveNumber(value) else { return }
            applyMacroScale(newGrams / originalGrams)
        }
        .onChange(of: servingUnits) { value in
            guard let count = positiveNumber(value),
                  let converted = item.serving?.grams(forUnitCount: count) else { return }
            grams = decimal(converted)
        }
    }

    private func applyMacroScale(_ factor: Double) {
        let scaled = item.macros.scaled(by: factor)
        calories = decimal(scaled.calories)
        protein = decimal(scaled.protein)
        carbohydrates = decimal(scaled.carbohydrates)
        fat = decimal(scaled.fat)
    }
}

struct NutritionLogEntryEditor: View {
    let entry: NutritionLogEntry
    let onSave: (NutritionLogEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var meal: NutritionMeal
    @State private var grams: String
    @State private var servingUnits: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbohydrates: String
    @State private var fat: String

    init(entry: NutritionLogEntry, onSave: @escaping (NutritionLogEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _meal = State(initialValue: entry.meal)
        _grams = State(initialValue: entry.quantityGrams.map(decimal) ?? "")
        _servingUnits = State(initialValue: {
            guard let grams = entry.quantityGrams,
                  let units = entry.serving?.unitCount(forGrams: grams) else { return "" }
            return decimal(units)
        }())
        _calories = State(initialValue: decimal(entry.macros.calories))
        _protein = State(initialValue: decimal(entry.macros.protein))
        _carbohydrates = State(initialValue: decimal(entry.macros.carbohydrates))
        _fat = State(initialValue: decimal(entry.macros.fat))
    }

    private var editedEntry: NutritionLogEntry? {
        guard let calories = nonnegativeNumber(calories) else { return nil }
        let macros = NutritionMacros(
            calories: calories,
            protein: optionalNumber(protein) ?? 0,
            carbohydrates: optionalNumber(carbohydrates) ?? 0,
            fat: optionalNumber(fat) ?? 0
        )
        guard macros.isValid else { return nil }
        var copy = entry
        copy.meal = meal
        copy.macros = macros
        if entry.quantityGrams != nil {
            guard let grams = positiveNumber(grams) else { return nil }
            copy.quantityGrams = grams
        }
        return copy
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Picker("Meal", selection: $meal) {
                    ForEach(NutritionMeal.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .tint(StrandPalette.accent)
                if entry.quantityGrams != nil {
                    NutritionNumberField(title: "Quantity", text: $grams, suffix: "g")
                    if let serving = entry.serving {
                        NutritionNumberField(title: serving.unitPlural.capitalized, text: $servingUnits)
                    }
                }
                NutritionNumberField(title: "Calories", text: $calories)
                HStack(spacing: NoopMetrics.space2) {
                    NutritionNumberField(title: "Protein", text: $protein, suffix: "g")
                    NutritionNumberField(title: "Carbs", text: $carbohydrates, suffix: "g")
                    NutritionNumberField(title: "Fat", text: $fat, suffix: "g")
                }
                Spacer()
            }
            .padding(NoopMetrics.space5)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(entry.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let editedEntry else { return }
                        onSave(editedEntry)
                        dismiss()
                    }
                    .disabled(editedEntry == nil)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
        .onChange(of: grams) { value in
            guard let originalGrams = entry.quantityGrams,
                  originalGrams > 0,
                  let newGrams = positiveNumber(value) else { return }
            applyMacroScale(newGrams / originalGrams)
        }
        .onChange(of: servingUnits) { value in
            guard let count = positiveNumber(value),
                  let converted = entry.serving?.grams(forUnitCount: count) else { return }
            grams = decimal(converted)
        }
    }

    private func applyMacroScale(_ factor: Double) {
        let scaled = entry.macros.scaled(by: factor)
        calories = decimal(scaled.calories)
        protein = decimal(scaled.protein)
        carbohydrates = decimal(scaled.carbohydrates)
        fat = decimal(scaled.fat)
    }
}

struct NutritionTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, NoopMetrics.space3)
            .frame(height: NoopMetrics.controlHeight)
            .background(StrandPalette.surfaceInset)
            .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: NoopMetrics.hairlineWidth)
            }
    }
}

struct NutritionNumberField: View {
    let title: String
    @Binding var text: String
    var suffix: String? = nil

    var body: some View {
        HStack(spacing: NoopMetrics.space1) {
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            if let suffix {
                Text(suffix).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .font(StrandFont.body)
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, NoopMetrics.space3)
        .frame(height: NoopMetrics.controlHeight)
        .background(StrandPalette.surfaceInset)
        .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: NoopMetrics.hairlineWidth)
        }
    }
}

func nonnegativeNumber(_ value: String) -> Double? {
    guard let number = Double(value.replacingOccurrences(of: ",", with: ".")),
          number.isFinite,
          number >= 0 else { return nil }
    return number
}

func positiveNumber(_ value: String) -> Double? {
    guard let number = nonnegativeNumber(value), number > 0 else { return nil }
    return number
}

func optionalNumber(_ value: String) -> Double? {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : nonnegativeNumber(value)
}

func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func decimal(_ value: Double) -> String {
    abs(value.rounded() - value) < 0.0001 ? String(Int(value.rounded())) : String(format: "%.1f", value)
}

func whole(_ value: Double) -> String { String(Int(value.rounded())) }
