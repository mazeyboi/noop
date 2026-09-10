import SwiftUI
import NutritionCore
import StrandDesign

private enum NutritionLoggerMode: String, CaseIterable, Identifiable {
    case search
    case ai
    case barcode
    case quickAdd
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "Search"
        case .ai: return "AI Photo"
        case .barcode: return "Barcode"
        case .quickAdd: return "Quick Add"
        case .library: return "Library"
        }
    }

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .ai: return "camera.viewfinder"
        case .barcode: return "barcode.viewfinder"
        case .quickAdd: return "plus.circle"
        case .library: return "books.vertical"
        }
    }
}

struct NutritionLoggerView: View {
    @ObservedObject var controller: NutritionController
    let localDate: String

    @Environment(\.dismiss) private var dismiss
    @State private var mode: NutritionLoggerMode = .search
    @State private var query = ""
    @State private var searchResults: [NutritionFood] = []
    @State private var plate: NutritionPlate
    @State private var editingPlateItem: NutritionPlateItem?
    @State private var editingFood: NutritionFood?
    @State private var showingNewFood = false
    @State private var isLogging = false
    @State private var confirmedEstimateIDs: Set<UUID> = []

    init(controller: NutritionController, localDate: String, initialMeal: NutritionMeal) {
        self.controller = controller
        self.localDate = localDate
        _plate = State(initialValue: NutritionPlate(meal: initialMeal))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    modePicker
                    if !plate.items.isEmpty { plateSection }
                    modeContent
                }
                .padding(NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Add Food")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task(id: "\(mode.rawValue):\(query):\(controller.revision)") {
            guard mode == .search else { return }
            searchResults = await controller.search(query)
        }
        .sheet(item: $editingPlateItem) { item in
            NutritionPlateItemEditor(item: item) { edited in
                plate.replace(edited)
                if edited.source == .geminiEstimate { confirmedEstimateIDs.insert(edited.id) }
            }
        }
        .sheet(item: $editingFood) { food in
            NutritionCustomFoodSheet(existing: food) { saved in
                await controller.saveFood(saved, localDate: localDate)
            }
        }
        .sheet(isPresented: $showingNewFood) {
            NutritionCustomFoodSheet { food in
                guard await controller.saveFood(food, localDate: localDate) else { return false }
                let quantity = await controller.lastQuantity(for: food)
                await MainActor.run {
                    plate.add(NutritionPlateItem(food: food, quantityGrams: quantity))
                }
                return true
            }
        }
    }

    private var modePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NoopMetrics.space2) {
                ForEach(NutritionLoggerMode.allCases) { option in
                    Button {
                        mode = option
                    } label: {
                        Label(option.title, systemImage: option.icon)
                            .font(StrandFont.footnote.weight(.semibold))
                            .foregroundStyle(mode == option ? StrandPalette.onDarkPrimary : StrandPalette.textSecondary)
                            .padding(.horizontal, NoopMetrics.space3)
                            .frame(height: NoopMetrics.controlHeight)
                            .background(mode == option ? StrandPalette.accent : StrandPalette.surfaceInset)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var modeContent: some View {
        switch mode {
        case .search:
            searchContent
        case .library:
            libraryContent
        case .quickAdd:
            StrandCard { NutritionQuickAddView { plate.add($0) } }
        case .ai:
            #if os(iOS)
            StrandCard {
                NutritionAIPhotoView { items in
                    for item in items {
                        confirmedEstimateIDs.remove(item.id)
                        plate.add(item)
                    }
                }
            }
            #else
            unavailableFeature("AI Photo is available in the iPhone app.")
            #endif
        case .barcode:
            #if os(iOS)
            StrandCard {
                NutritionBarcodeLookupView(controller: controller, localDate: localDate) { plate.add($0) }
            }
            #else
            unavailableFeature("Barcode scanning is available in the iPhone app.")
            #endif
        }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "magnifyingglass").foregroundStyle(StrandPalette.textTertiary)
                TextField("Search your foods", text: $query)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .padding(.horizontal, NoopMetrics.space3)
            .frame(height: NoopMetrics.controlHeight)
            .background(StrandPalette.surfaceInset)
            .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))

            if query.isEmpty {
                foodSection("Favourites", foods: controller.favourites)
                foodSection("Recent", foods: excluding(controller.recents, ids: Set(controller.favourites.map(\.id))))
                let used = Set(controller.favourites.map(\.id) + controller.recents.map(\.id))
                foodSection("Frequent", foods: excluding(controller.frequent, ids: used))
            } else if searchResults.isEmpty {
                emptySearch
            } else {
                foodSection("Results", foods: searchResults)
            }
        }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                Text("Food Library").strandOverline()
                Spacer()
                Button("New Custom Food") { showingNewFood = true }
                    .font(StrandFont.footnote.weight(.semibold))
            }
            if controller.library.isEmpty {
                Text("Create a custom food or scan a packaged product to start your library.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.vertical, NoopMetrics.space4)
            } else {
                StrandCard {
                    VStack(spacing: 0) {
                        ForEach(Array(controller.library.enumerated()), id: \.element.id) { index, food in
                            foodRow(food)
                            if index < controller.library.count - 1 { Divider().overlay(StrandPalette.hairline) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func foodSection(_ title: String, foods: [NutritionFood]) -> some View {
        if !foods.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(title).strandOverline()
                StrandCard {
                    VStack(spacing: 0) {
                        ForEach(Array(foods.enumerated()), id: \.element.id) { index, food in
                            foodRow(food)
                            if index < foods.count - 1 { Divider().overlay(StrandPalette.hairline) }
                        }
                    }
                }
            }
        }
    }

    private func foodRow(_ food: NutritionFood) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Button {
                add(food)
            } label: {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(food.name)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    HStack(spacing: NoopMetrics.space2) {
                        if let brand = food.brand { Text(brand) }
                        Text("\(whole(food.nutrientsPer100Grams.calories)) kcal / 100 g")
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { add(food) } label: { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.plain)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Add \(food.name) to plate")

            Button {
                Task { await controller.setFavourite(food, isFavourite: !food.isFavourite, localDate: localDate) }
            } label: {
                Image(systemName: food.isFavourite ? "star.fill" : "star")
            }
            .buttonStyle(.plain)
            .foregroundStyle(food.isFavourite ? StrandPalette.accent : StrandPalette.textTertiary)
            .accessibilityLabel(food.isFavourite ? "Remove \(food.name) from favourites" : "Favourite \(food.name)")

            if food.source == .custom {
                Menu {
                    Button("Edit") { editingFood = food }
                    Button("Delete", role: .destructive) {
                        Task { await controller.deleteFood(food, localDate: localDate) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityLabel("More actions for \(food.name)")
            }
        }
        .frame(minHeight: NoopMetrics.controlHeight)
        .contextMenu {
            Button(food.isFavourite ? "Remove Favourite" : "Favourite") {
                Task { await controller.setFavourite(food, isFavourite: !food.isFavourite, localDate: localDate) }
            }
            if food.source == .custom {
                Button("Edit") { editingFood = food }
                Button("Delete", role: .destructive) {
                    Task { await controller.deleteFood(food, localDate: localDate) }
                }
            }
        }
    }

    private var emptySearch: some View {
        VStack(spacing: NoopMetrics.space3) {
            Text("No local food found")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Create a custom food, scan a barcode, or use Quick Add.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            NoopButton("Create Custom Food", systemImage: "plus", kind: .secondary) {
                showingNewFood = true
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space5)
    }

    private var plateSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                Text("Plate").strandOverline()
                Spacer()
                Text("\(plate.items.count) item\(plate.items.count == 1 ? "" : "s")")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }

            StrandCard {
                VStack(spacing: 0) {
                    ForEach(Array(plate.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: NoopMetrics.space3) {
                            Button { editingPlateItem = item } label: {
                                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                    Text(item.name)
                                        .font(StrandFont.subhead.weight(.semibold))
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text("\(item.quantityDescription) / \(whole(item.macros.calories)) kcal")
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            if item.source == .geminiEstimate {
                                Button {
                                    confirmedEstimateIDs.insert(item.id)
                                } label: {
                                    Image(systemName: confirmedEstimateIDs.contains(item.id)
                                          ? "checkmark.circle.fill" : "checkmark.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(confirmedEstimateIDs.contains(item.id)
                                                 ? StrandPalette.accent : StrandPalette.textTertiary)
                                .accessibilityLabel(confirmedEstimateIDs.contains(item.id)
                                                    ? "AI estimate confirmed" : "Confirm AI estimate")
                            }
                            Button {
                                confirmedEstimateIDs.remove(item.id)
                                plate.remove(id: item.id)
                            } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityLabel("Remove \(item.name)")
                        }
                        .frame(minHeight: NoopMetrics.controlHeight)
                        if index < plate.items.count - 1 { Divider().overlay(StrandPalette.hairline) }
                    }

                    Divider().overlay(StrandPalette.hairline)
                    macroPreview(plate.macros)
                }
            }

            Picker("Meal", selection: $plate.meal) {
                ForEach(NutritionMeal.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .tint(StrandPalette.accent)

            if hasUnconfirmedEstimates {
                Text("Review or confirm every AI estimate before logging.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }

            NoopButton(
                isLogging ? "Logging..." : "Log Foods",
                systemImage: "checkmark",
                kind: .primary,
                fullWidth: true
            ) {
                logPlate()
            }
            .disabled(isLogging || hasUnconfirmedEstimates)
        }
    }

    private func macroPreview(_ macros: NutritionMacros) -> some View {
        HStack {
            macroValue("Calories", whole(macros.calories))
            macroValue("Protein", "\(decimal(macros.protein)) g")
            macroValue("Carbs", "\(decimal(macros.carbohydrates)) g")
            macroValue("Fat", "\(decimal(macros.fat)) g")
        }
        .padding(.top, NoopMetrics.space3)
    }

    private func macroValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(value).font(StrandFont.footnote.weight(.semibold)).monospacedDigit()
            Text(title).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add(_ food: NutritionFood) {
        Task {
            let quantity = await controller.lastQuantity(for: food)
            await MainActor.run {
                plate.add(NutritionPlateItem(food: food, quantityGrams: quantity))
            }
        }
    }

    private func logPlate() {
        guard !hasUnconfirmedEstimates else { return }
        isLogging = true
        Task {
            let logged = await controller.log(plate, localDate: localDate)
            await MainActor.run {
                isLogging = false
                if logged { dismiss() }
            }
        }
    }

    private func excluding(_ foods: [NutritionFood], ids: Set<UUID>) -> [NutritionFood] {
        foods.filter { !ids.contains($0.id) }
    }

    private var hasUnconfirmedEstimates: Bool {
        plate.items.contains {
            $0.source == .geminiEstimate && !confirmedEstimateIDs.contains($0.id)
        }
    }

    private func unavailableFeature(_ message: String) -> some View {
        Text(message)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(NoopMetrics.space5)
    }
}

#if os(iOS)
private struct NutritionBarcodeLookupView: View {
    @ObservedObject var controller: NutritionController
    let localDate: String
    let onAdd: (NutritionPlateItem) -> Void

    @State private var showingScanner = false
    @State private var food: NutritionFood?
    @State private var grams = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage("noop.nutrition.openFoodFactsConsent") private var lookupConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            Text("Packaged food").strandOverline()
            Text("A scan is processed on-device. For products not already in your library, the barcode and your network address are sent to Open Food Facts for lookup.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NoopButton(
                lookupConsent ? "Scan Barcode" : "Allow Lookup and Scan",
                systemImage: "barcode.viewfinder",
                kind: .secondary,
                fullWidth: true
            ) {
                lookupConsent = true
                showingScanner = true
            }

            if isLoading {
                HStack(spacing: NoopMetrics.space2) {
                    ProgressView().tint(StrandPalette.accent)
                    Text("Looking up Open Food Facts...")
                }
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.recovery000)
            }

            if let food {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text(food.name)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let brand = food.brand {
                        Text(brand).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text("\(whole(food.nutrientsPer100Grams.calories)) kcal / P \(decimal(food.nutrientsPer100Grams.protein)) / C \(decimal(food.nutrientsPer100Grams.carbohydrates)) / F \(decimal(food.nutrientsPer100Grams.fat)) per 100 g")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    NutritionNumberField(title: "Quantity", text: $grams, suffix: "g")
                    NoopButton("Add to Plate", systemImage: "plus", kind: .primary, fullWidth: true) {
                        addProduct(food)
                    }
                    .disabled(positiveNumber(grams) == nil)
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            NutritionBarcodeScannerView { code in lookup(code) }
        }
    }

    private func lookup(_ code: String) {
        isLoading = true
        errorMessage = nil
        food = nil
        Task {
            do {
                let result: NutritionFood
                if let cached = await controller.food(barcode: code) {
                    result = cached
                } else {
                    result = try await OpenFoodFactsService().find(barcode: code)
                }
                let remembered = await controller.lastQuantity(for: result)
                await MainActor.run {
                    food = result
                    grams = decimal(remembered ?? result.serving?.grams ?? 100)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? "The product could not be looked up."
                    isLoading = false
                }
            }
        }
    }

    private func addProduct(_ food: NutritionFood) {
        guard let grams = positiveNumber(grams) else { return }
        Task {
            guard await controller.saveFood(food, localDate: localDate) else { return }
            await MainActor.run {
                onAdd(NutritionPlateItem(food: food, quantityGrams: grams))
                self.food = nil
                self.grams = ""
            }
        }
    }
}
#endif
