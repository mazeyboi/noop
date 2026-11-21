#if os(iOS)
import NOOPExtras
import StrandDesign
import SwiftUI

/// The row NOOP's "More" tab shows. Styled like upstream's own (private) `MoreRow` in RootTabView:
/// accent icon, primary title, chevron, hairline underneath.
public struct ExtrasMoreRow: View {
    public init() {}
    public var body: some View {
        NavigationLink {
            FoodHomeView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 26, alignment: .center)
                Text("Food")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The Food tab. NOOP's tab bar shows it in Coach's slot when the AI Coach is switched off
/// (Settings → AI Coach); iPhone fits five tabs.
public struct ExtrasFoodTab: View {
    public init() {}
    public var body: some View {
        NavigationStack {
            FoodHomeView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
        }
        .tabItem { Label("Food", systemImage: "fork.knife") }
    }
}

enum FoodSheet: Identifiable {
    case photo, scan, search, quickAdd, drinks, savedMeals, settings
    case edit(FoodEntry)
    var id: String {
        switch self {
        case .photo: return "photo"
        case .scan: return "scan"
        case .search: return "search"
        case .quickAdd: return "quick"
        case .drinks: return "drinks"
        case .savedMeals: return "saved"
        case .settings: return "settings"
        case .edit(let e): return "edit-\(e.id)"
        }
    }
}

public struct FoodHomeView: View {
    @ObservedObject var app = ExtrasApp.shared
    @State private var sheet: FoodSheet?

    public init() {}

    public var body: some View {
        Group {
            if let error = app.startupError {
                ContentUnavailableView("Food log unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                content
            }
        }
        .navigationTitle("Food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if app.startupError == nil {
                    Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Food settings")
                }
            }
        }
        .sheet(item: $sheet, onDismiss: { app.reload() }) { s in
            NavigationStack { sheetView(s) }
        }
        .onAppear { app.refreshDay(); app.reload() }
        .task { await app.estimatePending() }
    }

    @ViewBuilder func sheetView(_ s: FoodSheet) -> some View {
        switch s {
        case .photo: PhotoLogView()
        case .scan: BarcodeLogView()
        case .search: FoodSearchView()
        case .quickAdd: QuickAddView()
        case .drinks: DrinksView()
        case .savedMeals: SavedMealsView()
        case .settings: ExtrasSettingsView()
        case .edit(let e): EntryEditView(entry: e)
        }
    }

    var content: some View {
        List {
            Section { dayBar }
            Section { TotalsCard(totals: app.totals, targets: app.targets) }
            if let banner = app.banner {
                Section {
                    Text(banner).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                        .onTapGesture { app.banner = nil }
                }
            }
            Section { actions }
            ForEach(MealType.allCases) { meal in
                let items = app.entries.filter { $0.meal == meal }
                Section {
                    ForEach(items) { e in
                        Button { sheet = .edit(e) } label: { EntryRow(entry: e) }
                            .buttonStyle(.plain)
                            .swipeActions { Button(role: .destructive) { app.delete(e) } label: { Label("Delete", systemImage: "trash") } }
                    }
                    if items.isEmpty {
                        Text("Nothing logged").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                } header: {
                    HStack {
                        Text(meal.title)
                        Spacer()
                        let kcal = items.filter { $0.status == .logged }.reduce(0) { $0 + $1.totals.kcal }
                        if kcal > 0 { Text(kcal.kcalText).monospacedDigit() }
                        Menu {
                            Button("Copy from the day before") { app.copyMeal(meal, fromDaysAgo: 1) }
                            Button("Copy from a week ago") { app.copyMeal(meal, fromDaysAgo: 7) }
                        } label: { Image(systemName: "doc.on.doc") }
                            .accessibilityLabel("Copy \(meal.title.lowercased())")
                    }
                }
            }
            Section { SyncStatusRow() }
        }
        .refreshable { await app.sync(force: true) }
    }

    var dayBar: some View {
        HStack {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            Spacer()
            Text(dayTitle).font(StrandFont.headline)
            Spacer()
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                .disabled(Calendar.current.isDateInToday(app.day))
        }
    }

    var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(app.day) { return "Today" }
        if cal.isDateInYesterday(app.day) { return "Yesterday" }
        return app.day.formatted(.dateTime.weekday(.wide).day().month())
    }

    func shiftDay(_ n: Int) { app.shiftDay(n) }

    var actions: some View {
        VStack(spacing: 10) {
            Button { sheet = .photo } label: {
                Label("Photo", systemImage: "camera.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            HStack(spacing: 8) {
                small("Scan", "barcode.viewfinder", .scan)
                small("Search", "magnifyingglass", .search)
                small("Quick", "plus", .quickAdd)
                small("Drinks", "cup.and.saucer.fill", .drinks)
                small("Meals", "star", .savedMeals)
            }
        }
        .padding(.vertical, 4)
    }

    func small(_ title: String, _ icon: String, _ s: FoodSheet) -> some View {
        Button { sheet = s } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(StrandFont.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }
}

struct TotalsCard: View {
    let totals: DayTotals
    let targets: Targets?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(totals.logged.kcal.rounded()))").font(StrandFont.rounded(34)).monospacedDigit()
                Text(targets.map { "of \(Int($0.kcal)) kcal" } ?? "kcal").font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                if let t = targets {
                    let left = t.kcal - totals.logged.kcal
                    Text(left >= 0 ? "\(Int(left.rounded())) left" : "\(Int((-left).rounded())) over")
                        .font(StrandFont.subhead)
                        .foregroundStyle(left >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical)
                }
            }
            if let t = targets, t.kcal > 0 {
                ProgressView(value: min(totals.logged.kcal, t.kcal), total: t.kcal).tint(StrandPalette.accent)
            }
            HStack {
                macro("Protein", totals.logged.proteinG, targets?.proteinG)
                macro("Carbs", totals.logged.carbsG, targets?.carbsG)
                macro("Fat", totals.logged.fatG, targets?.fatG)
            }
            if totals.logged.caffeineMg > 0 || totals.logged.alcoholG > 0 {
                Text([totals.logged.caffeineMg > 0 ? "Caffeine \(Int(totals.logged.caffeineMg)) mg" : nil,
                      totals.logged.alcoholG > 0 ? "Alcohol \(Int(totals.logged.alcoholG.rounded())) g" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            if totals.pendingCount > 0 {
                Label("\(totals.pendingCount) photo\(totals.pendingCount == 1 ? "" : "s") not counted yet (waiting for an estimate, or tap to fix)",
                      systemImage: "hourglass")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
        }
        .padding(.vertical, 6)
    }

    func macro(_ name: String, _ v: Double, _ target: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(target.map { "\(Int(v.rounded()))/\(Int($0)) g" } ?? "\(Int(v.rounded())) g")
                .font(StrandFont.subhead).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EntryRow: View {
    let entry: FoodEntry
    var body: some View {
        HStack(spacing: 12) {
            if let img = ExtrasApp.shared.photo(for: entry) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: icon).frame(width: 44, height: 44).foregroundStyle(StrandPalette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(StrandFont.body).lineLimit(1)
                Text(subtitle).font(StrandFont.caption).foregroundStyle(subtitleColor).lineLimit(2)
            }
            Spacer()
            if entry.status == .logged {
                Text(entry.totals.kcal.kcalText).font(StrandFont.subhead).monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }

    var icon: String {
        switch entry.method {
        case .photo_ai: return "camera"
        case .barcode: return "barcode"
        case .search: return "magnifyingglass"
        case .quick_add: return "plus.circle"
        case .custom: return "square.and.pencil"
        }
    }

    var subtitle: String {
        switch entry.status {
        case .pending: return entry.error ?? "Waiting for an estimate"
        case .failed: return entry.error ?? "Couldn't estimate. Tap to retry or enter it manually."
        case .logged:
            var parts = [entry.at.formatted(date: .omitted, time: .shortened)]
            if entry.confidence == .low && !entry.edited { parts.append("low confidence") }
            if entry.edited && entry.aiOriginal != nil { parts.append("edited") }
            return parts.joined(separator: " · ")
        }
    }

    var subtitleColor: Color {
        switch entry.status {
        case .logged: return entry.confidence == .low && !entry.edited ? StrandPalette.statusWarning : StrandPalette.textSecondary
        case .pending: return StrandPalette.textSecondary
        case .failed: return StrandPalette.statusCritical
        }
    }
}

struct SyncStatusRow: View {
    @ObservedObject var app = ExtrasApp.shared
    var body: some View {
        HStack {
            if app.syncing { ProgressView().controlSize(.small) }
            Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button("Sync now") { Task { await app.sync(force: true) } }.font(StrandFont.caption).disabled(app.syncing)
        }
    }
    var text: String {
        if app.syncing { return "Syncing…" }
        guard let r = app.lastSync else { return "Syncs to the health server on your home Wi-Fi." }
        if let e = r.error { return e.message }
        let n = r.sent.values.reduce(0, +)
        return "Synced \(n) record\(n == 1 ? "" : "s")\(r.photos > 0 ? ", \(r.photos) photos" : "")"
            + (r.quarantined > 0 ? ", \(r.quarantined) rejected (see settings)" : "")
    }
}
#endif
