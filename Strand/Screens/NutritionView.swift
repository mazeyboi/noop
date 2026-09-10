import SwiftUI
import NutritionCore
import StrandDesign

struct NutritionView: View {
    private enum Goal {
        static let calories = 2_400.0
        static let protein = 150.0
        static let carbohydrates = 250.0
        static let fat = 70.0
    }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = NutritionController()
    @State private var localDate = NutritionLocalDate.key(for: Date())
    @State private var showingLogger = false
    @State private var loggerMeal = NutritionMeal.breakfast
    @State private var editingEntry: NutritionLogEntry?
    @State private var deletedEntry: NutritionLogEntry?
    @State private var undoTask: Task<Void, Never>?

    var body: some View {
        ScreenScaffold(
            title: "Nutrition",
            subtitle: "Today / logged on this device",
            topBackground: liquidScaffoldSky()
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                dailyStatus
                if let deletedEntry { undoBanner(deletedEntry) }
                meals
                NoopButton(
                    "Add Food",
                    systemImage: "plus",
                    kind: .primary,
                    fullWidth: true
                ) {
                    loggerMeal = suggestedMeal(at: Date())
                    showingLogger = true
                }
            }
        }
        .task(id: localDate) { await controller.reload(localDate: localDate) }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            let today = NutritionLocalDate.key(for: Date())
            if today == localDate {
                Task { await controller.reload(localDate: localDate) }
            } else {
                localDate = today
            }
        }
        .sheet(isPresented: $showingLogger) {
            NutritionLoggerView(controller: controller, localDate: localDate, initialMeal: loggerMeal)
        }
        .sheet(item: $editingEntry) { entry in
            NutritionLogEntryEditor(entry: entry) { edited in
                Task { await controller.update(edited) }
            }
        }
        .alert("Nutrition", isPresented: errorBinding) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "Nutrition could not complete that action.")
        }
    }

    private var dailyStatus: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(whole(controller.summary.macros.calories))
                        .font(StrandFont.rounded(42))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                    Text("/ \(whole(Goal.calories)) kcal")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                }
                ProgressView(value: min(controller.summary.macros.calories, Goal.calories), total: Goal.calories)
                    .tint(StrandPalette.accent)

                HStack(spacing: NoopMetrics.space4) {
                    macroStatus("Protein", value: controller.summary.macros.protein, goal: Goal.protein)
                    macroStatus("Carbs", value: controller.summary.macros.carbohydrates, goal: Goal.carbohydrates)
                    macroStatus("Fat", value: controller.summary.macros.fat, goal: Goal.fat)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func macroStatus(_ title: String, value: Double, goal: Double) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text("\(decimal(value)) / \(whole(goal)) g")
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            ProgressView(value: min(value, goal), total: goal)
                .tint(StrandPalette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meals: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            ForEach(NutritionMeal.allCases) { meal in
                mealSection(meal)
            }
        }
    }

    private func mealSection(_ meal: NutritionMeal) -> some View {
        let entries = controller.summary.entries(for: meal)
        let calories = controller.summary.macros(for: meal).calories
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text(meal.title).strandOverline()
                Text("\(whole(calories)) kcal")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
                Spacer()
                Button {
                    loggerMeal = meal
                    showingLogger = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(StrandFont.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Add food to \(meal.title)")
            }

            StrandCard {
                if entries.isEmpty {
                    Button {
                        loggerMeal = meal
                        showingLogger = true
                    } label: {
                        HStack {
                            Text("Nothing logged")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(StrandPalette.accent)
                        }
                        .frame(minHeight: NoopMetrics.controlHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry)
                            if index < entries.count - 1 {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: NutritionLogEntry) -> some View {
        Button { editingEntry = entry } label: {
            HStack(spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(entry.name)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    HStack(spacing: NoopMetrics.space2) {
                        Text(entry.quantityDescription)
                        Text("P \(decimal(entry.macros.protein)) / C \(decimal(entry.macros.carbohydrates)) / F \(decimal(entry.macros.fat))")
                        if entry.source == .geminiEstimate { Text("AI estimate") }
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                }
                Spacer(minLength: NoopMetrics.space2)
                Text("\(whole(entry.macros.calories))")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(minHeight: NoopMetrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { editingEntry = entry }
            Button("Duplicate") { Task { await controller.duplicate(entry) } }
            Button("Delete", role: .destructive) { delete(entry) }
        }
        .accessibilityHint("Opens quantity and nutrition editing")
    }

    private func undoBanner(_ entry: NutritionLogEntry) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Text("Deleted \(entry.name)")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
            Spacer()
            Button("Undo") {
                undoTask?.cancel()
                deletedEntry = nil
                Task { await controller.restore(entry) }
            }
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.accent)
        }
        .padding(NoopMetrics.space3)
        .background(StrandPalette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: NoopMetrics.hairlineWidth)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )
    }

    private func delete(_ entry: NutritionLogEntry) {
        Task {
            guard let deleted = await controller.delete(entry) else { return }
            undoTask?.cancel()
            deletedEntry = deleted
            undoTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if deletedEntry?.id == deleted.id { deletedEntry = nil }
                }
            }
        }
    }

    private func suggestedMeal(at date: Date, calendar: Calendar = .current) -> NutritionMeal {
        switch calendar.component(.hour, from: date) {
        case 5..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<22: return .dinner
        default: return .snacks
        }
    }
}
