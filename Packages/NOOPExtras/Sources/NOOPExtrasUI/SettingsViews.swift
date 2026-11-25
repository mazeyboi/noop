#if os(iOS)
import NOOPExtras
import StrandDesign
import SwiftUI
import UIKit

struct ExtrasSettingsView: View {
    @ObservedObject var app = ExtrasApp.shared
    @Environment(\.dismiss) var dismiss
    @State private var targets = Targets(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0)
    @State private var serverURL = ""
    @State private var token = ""
    @State private var serverStatus = ""
    @State private var confirmRestore = false
    @State private var quarantined: [QuarantinedRecord] = []
    @State private var drinks: [DrinkPreset] = []
    @State private var targetsStatus = ""
    @State private var drinksStatus = ""
    @State private var confirmClear = false
    @State private var confirmResetDrinks = false
    @State private var askDrinkName = false
    @State private var newDrinkName = ""

    var body: some View {
        Form {
            Section {
                NumberRow("kcal", value: $targets.kcal)
                NumberRow("Protein g", value: $targets.proteinG)
                NumberRow("Carbs g", value: $targets.carbsG)
                NumberRow("Fat g", value: $targets.fatG)
                NumberRow("Caffeine max mg", value: Binding(get: { targets.caffeineMaxMg ?? 0 }, set: { targets.caffeineMaxMg = $0 > 0 ? $0 : nil }))
                NumberRow("Alcohol max g", value: Binding(get: { targets.alcoholMaxG ?? 0 }, set: { targets.alcoholMaxG = $0 > 0 ? $0 : nil }))
                Button("Save targets") {
                    do { try app.store.save(targets); app.reload(); targetsStatus = "Saved." }
                    catch { targetsStatus = "Couldn't save: \(error.localizedDescription)" }
                }
                if !targetsStatus.isEmpty { Text(targetsStatus).font(StrandFont.caption) }
            } header: {
                Text("Daily targets")
            } footer: {
                if app.targets == nil {
                    Text("No targets saved yet. These numbers are only a suggestion: change them and tap Save targets.")
                }
            }
            Section {
                NavigationLink {
                    ProviderSettingsView()
                } label: {
                    LabeledContent("AI provider", value: app.providerSettings.map { "\($0.kind.displayName) · \($0.model)" } ?? "Not set up")
                }
            } footer: {
                Text("Meal photos and hints go to the provider you choose. There is no default.")
            }
            Section {
                TextField("Server URL", text: $serverURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(app.secrets.get(SyncConfig.tokenKey) == nil ? "Device token" : "Device token (saved)", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save and test connection") { Task { await saveServer() } }
                if !serverStatus.isEmpty { Text(serverStatus).font(StrandFont.caption) }
                SyncStatusRow()
                Button("Restore food log from server…", role: .destructive) { confirmRestore = true }
            } header: {
                Text("Health server")
            } footer: {
                Text("Syncs only on your home network. The token comes from the server (see the health-dashboard RUNBOOK).")
            }
            if !quarantined.isEmpty {
                Section {
                    ForEach(quarantined, id: \.id) { q in
                        VStack(alignment: .leading) {
                            Text("\(q.kind) \(q.id)").font(StrandFont.caption).lineLimit(1)
                            Text(q.error).font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical)
                        }
                    }
                    Button("Send these again") { try? app.store.requeueQuarantined(); quarantined = []; Task { await app.sync(force: true) } }
                    Button("Clear list", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Drop these records without sending them?", isPresented: $confirmClear,
                                            titleVisibility: .visible) {
                            Button("Clear list", role: .destructive) { try? app.store.clearQuarantine(); quarantined = [] }
                        } message: {
                            Text("They never reach the server unless you edit the entries again.")
                        }
                } header: {
                    Text("Rejected by the server (\(quarantined.count))")
                } footer: {
                    Text("These records were skipped so the rest could sync. Editing an entry sends it again.")
                }
            }
            Section {
                ForEach($drinks) { $d in
                    DisclosureGroup(d.name) {
                        NumberRow("ml", value: $d.ml)
                        NumberRow("kcal", value: $d.kcal)
                        NumberRow("Caffeine mg", value: $d.caffeineMg)
                        NumberRow("Alcohol g", value: $d.alcoholG)
                    }
                }
                .onDelete { drinks.remove(atOffsets: $0); saveDrinks() }
                Button("Add a drink…") { newDrinkName = ""; askDrinkName = true }
                    .alert("New drink", isPresented: $askDrinkName) {
                        TextField("Name", text: $newDrinkName)
                        Button("Add") { addDrink() }
                        Button("Cancel", role: .cancel) {}
                    }
                Button("Save drinks") { saveDrinks() }
                if !drinksStatus.isEmpty { Text(drinksStatus).font(StrandFont.caption) }
                Button("Reset to defaults", role: .destructive) { confirmResetDrinks = true }
                    .confirmationDialog("Replace your drinks with the five defaults?", isPresented: $confirmResetDrinks,
                                        titleVisibility: .visible) {
                        Button("Reset to defaults", role: .destructive) { drinks = Drinks.defaults; saveDrinks() }
                    }
            } header: {
                Text("Drinks quick add")
            } footer: {
                Text("Swipe a drink left to remove it.")
            }
            Section("About") {
                Text(GenericFoods.attribution).font(StrandFont.caption)
                Text(ExtrasResources.openFoodFactsAttribution).font(StrandFont.caption)
                Text("Food log: part of a personal fork of NOOP (PolyForm Noncommercial 1.0.0).").font(StrandFont.caption)
            }
        }
        .navigationTitle("Food settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear {
            targets = app.targets ?? Targets(kcal: 2000, proteinG: 140, carbsG: 200, fatG: 70)
            serverURL = app.syncConfig.baseURL.absoluteString
            quarantined = (try? app.store.quarantined()) ?? []
            drinks = Drinks.load(store: app.store)
        }
        .confirmationDialog("Replace this phone's food log with the server's copy?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore from server", role: .destructive) { Task { serverStatus = await app.restore() } }
        } message: {
            Text("For a new or reset phone. This phone's unsynced changes are sent to the server first; if that fails, nothing is replaced.")
        }
    }

    func saveDrinks() {
        do { try Drinks.save(drinks, store: app.store); drinksStatus = "Saved." }
        catch { drinksStatus = "Couldn't save: \(error.localizedDescription)" }
    }

    func addDrink() {
        let name = newDrinkName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // The name is the preset's identity, so it has to be unique.
        guard !drinks.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            drinksStatus = "There's already a drink called \(name)."; return
        }
        drinks.append(DrinkPreset(name: name, ml: 250, kcal: 0))
        saveDrinks()
    }

    func saveServer() async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else {
            serverStatus = "That isn't a valid URL."; return
        }
        try? app.store.setKV(SyncConfig.urlKey, trimmed)
        if !token.isEmpty { app.secrets.set(SyncConfig.tokenKey, token.trimmingCharacters(in: .whitespacesAndNewlines)); token = "" }
        serverStatus = "Testing…"
        do {
            let name = try await SyncAPI(config: app.syncConfig, transport: app.transport).whoami()
            serverStatus = "Connected as \(name)."
        } catch let e as SyncError {
            serverStatus = e.message
        } catch {
            serverStatus = error.localizedDescription
        }
    }
}

/// Pick a provider, paste a key (Keychain), choose a model, test it on the bundled sample photo.
struct ProviderSettingsView: View {
    @ObservedObject var app = ExtrasApp.shared
    @State private var kind: ProviderKind?
    @State private var model = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var testing = false
    @State private var testResult = ""
    @State private var saveStatus = ""

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $kind) {
                    Text("None").tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag(ProviderKind?.some($0)) }
                }
            } footer: {
                if let note = kind?.privacyNote { Text(note) }
            }
            if let kind {
                Section("API key") {
                    SecureField(app.secrets.get(ProviderFactory.keyName(kind)) == nil
                                ? (kind.needsKey ? "Paste key" : "Key (optional for a local server)")
                                : "Saved. Paste to replace", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextField("Model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !kind.suggestedModels.isEmpty {
                        Menu("Suggestions") { ForEach(kind.suggestedModels, id: \.self) { m in Button(m) { model = m } } }
                    }
                    if kind.needsBaseURL {
                        TextField("Base URL, e.g. https://openrouter.ai/api/v1", text: $baseURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("Model") }
                Section {
                    Button("Save") {
                        save()
                        saveStatus = app.provider() == nil
                            ? "Saved, but the key, model or base URL is still missing, so photos will wait."
                            : "Saved."
                    }.bold()
                    if !saveStatus.isEmpty { Text(saveStatus).font(StrandFont.caption) }
                    Button(testing ? "Testing…" : "Save and test with a sample photo") { Task { await test() } }.disabled(testing)
                    if !testResult.isEmpty { Text(testResult).font(StrandFont.caption) }
                } footer: {
                    Text("Set a spending limit with the provider. A photo costs from a fraction of a cent to a few cents.")
                }
            } else {
                Section {
                    Text("Without a provider, meal photos are saved and wait. They're estimated once you set one up.")
                        .font(StrandFont.caption)
                    Button("Save") { app.providerSettings = nil; saveStatus = "Saved. No provider is set." }
                    if !saveStatus.isEmpty { Text(saveStatus).font(StrandFont.caption) }
                }
            }
        }
        .navigationTitle("AI provider")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let s = app.providerSettings
            kind = s?.kind
            model = s?.model ?? ""
            baseURL = s?.baseURL ?? ""
        }
        .onChange(of: kind) { old, new in
            saveStatus = ""
            if old != nil, new != old { model = new?.suggestedModels.first ?? ""; testResult = "" }
            if old == nil, model.isEmpty { model = new?.suggestedModels.first ?? "" }
        }
    }

    func save() {
        guard let kind else { app.providerSettings = nil; return }
        if !key.isEmpty { app.secrets.set(ProviderFactory.keyName(kind), key.trimmingCharacters(in: .whitespacesAndNewlines)); key = "" }
        app.providerSettings = ProviderSettings(kind: kind, model: model.trimmingCharacters(in: .whitespaces),
                                                baseURL: kind.needsBaseURL ? baseURL : nil)
        Task { await app.estimatePending() }
    }

    func test() async {
        save()
        guard let provider = app.provider() else {
            testResult = kind?.needsKey == true ? "Add a key and a model first." : "Add a model (and base URL) first."
            return
        }
        guard let png = ExtrasResources.samplePNG(), let img = UIImage(data: png), let jpeg = ImageTools.downscaledJPEG(img) else {
            testResult = "The sample photo is missing."; return
        }
        testing = true
        let start = Date()
        do {
            let est = try await provider.estimate(EstimateRequest(image: jpeg, hint: nil, meal: .dinner, at: Date()))
            let secs = Date().timeIntervalSince(start)
            testResult = String(format: "Works (%.1f s): ", secs)
                + est.items.map { "\($0.name) \(Int($0.kcal)) kcal" }.joined(separator: ", ")
                + " · \(est.totals.kcal.kcalText), confidence \(est.confidence.rawValue)"
        } catch let e as ProviderError {
            testResult = String(format: "Failed after %.1f s: ", Date().timeIntervalSince(start)) + e.message
        } catch {
            testResult = error.localizedDescription
        }
        testing = false
    }
}
#endif
