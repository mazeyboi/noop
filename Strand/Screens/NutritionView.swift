import SwiftUI
import StrandDesign

enum NutritionMeal: String, CaseIterable, Identifiable {
    case breakfast
    case lunch
    case dinner
    case snacks

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snacks: "Snacks"
        }
    }
}

struct NutritionDayState {
    private var mealCalories: [NutritionMeal: Int] = [:]

    var totalCalories: Int {
        mealCalories.values.reduce(0, +)
    }

    func calories(for meal: NutritionMeal) -> Int {
        mealCalories[meal, default: 0]
    }

    mutating func addCalories(_ calories: Int, to meal: NutritionMeal) {
        guard calories > 0 else { return }
        mealCalories[meal, default: 0] += calories
    }
}

struct NutritionView: View {
    @State private var day = NutritionDayState()
    @State private var showingQuickAdd = false

    var body: some View {
        ScreenScaffold(
            title: "Nutrition",
            subtitle: "Today's intake, kept on this device.",
            topBackground: liquidScaffoldSky()
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                section("Today") {
                    StrandCard {
                        valueRow("Calories", value: "\(day.totalCalories) / 2400 kcal")
                    }
                }

                section("Macros") {
                    StrandCard {
                        VStack(spacing: 0) {
                            valueRow("Protein", value: "0 / 150 g")
                            rowDivider
                            valueRow("Carbohydrates", value: "0 / 250 g")
                            rowDivider
                            valueRow("Fat", value: "0 / 70 g")
                        }
                    }
                }

                section("Meals") {
                    StrandCard {
                        VStack(spacing: 0) {
                            ForEach(Array(NutritionMeal.allCases.enumerated()), id: \.element.id) { index, meal in
                                valueRow(meal.title, value: "\(day.calories(for: meal)) kcal")
                                if index < NutritionMeal.allCases.count - 1 {
                                    rowDivider
                                }
                            }
                        }
                    }
                }

                NoopButton(
                    "Quick Add Calories",
                    systemImage: "plus",
                    kind: .primary,
                    fullWidth: true
                ) {
                    showingQuickAdd = true
                }
            }
        }
        .sheet(isPresented: $showingQuickAdd) {
            QuickAddCaloriesSheet { calories, meal in
                day.addCalories(calories, to: meal)
            }
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text(title).strandOverline()
            content()
        }
    }

    private func valueRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: NoopMetrics.space2)
            Text(value)
                .font(StrandFont.headline.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
        }
        .frame(minHeight: NoopMetrics.controlHeight)
        .accessibilityElement(children: .combine)
    }

    private var rowDivider: some View {
        Divider().overlay(StrandPalette.hairline)
    }
}

private struct QuickAddCaloriesSheet: View {
    let onSave: (Int, NutritionMeal) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var calorieDraft = ""
    @State private var meal: NutritionMeal = .breakfast

    private var calories: Int? {
        guard let value = Int(calorieDraft), value > 0 else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            Text("Quick Add Calories")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)

            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Calories").strandOverline()
                calorieField
            }

            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Meal").strandOverline()
                Picker("Meal", selection: $meal) {
                    ForEach(NutritionMeal.allCases) { meal in
                        Text(meal.title).tag(meal)
                    }
                }
                .pickerStyle(.segmented)
                .tint(StrandPalette.accent)
            }

            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Cancel", kind: .secondary, fullWidth: true) {
                    dismiss()
                }
                NoopButton("Save", kind: .primary, fullWidth: true) {
                    guard let calories else { return }
                    onSave(calories, meal)
                    dismiss()
                }
                .disabled(calories == nil)
            }
        }
        .padding(NoopMetrics.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if os(iOS)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var calorieField: some View {
        TextField("Enter calorie amount", text: $calorieDraft)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, NoopMetrics.space4)
            .frame(height: NoopMetrics.controlHeight)
            .background(StrandPalette.surfaceInset)
            .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: NoopMetrics.hairlineWidth)
            }
    }
}
