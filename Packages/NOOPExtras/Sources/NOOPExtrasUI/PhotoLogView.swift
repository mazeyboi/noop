#if os(iOS)
import NOOPExtras
import PhotosUI
import StrandDesign
import SwiftUI
import UIKit

/// Take or pick a meal photo, add an optional hint, log it. The entry is saved as pending at once;
/// when a provider is set up and the phone is online, the estimate opens for a one-tap confirm.
struct PhotoLogView: View {
    @ObservedObject var app = ExtrasApp.shared
    @Environment(\.dismiss) var dismiss
    @State private var image: UIImage?
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var hint = ""
    @State private var meal = MealType.suggested(for: Date())
    @State private var at = Date()
    @State private var working = false
    @State private var autoOpened = false
    @State private var result: FoodEntry?

    var body: some View {
        Form {
            Section {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).frame(maxWidth: .infinity)
                }
                HStack {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label(image == nil ? "Take photo" : "Retake", systemImage: "camera") }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    PhotosPicker(selection: $pickerItem, matching: .images) { Label("Library", systemImage: "photo.on.rectangle") }
                        .buttonStyle(.borderless)
                }
            }
            Section("Hint (optional)") {
                TextField("about 200 g rice, cooked in butter, half eaten…", text: $hint, axis: .vertical)
            }
            Section {
                Picker("Meal", selection: $meal) { ForEach(MealType.allCases) { Text($0.title).tag($0) } }
                DatePicker("Time", selection: $at)
            }
            if app.provider() == nil {
                Section {
                    Text("No AI provider is set up yet. The photo is saved and estimated once you add one in Food settings.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Section {
                Button {
                    guard let image else { return }
                    working = true
                    Task {
                        let e = await app.logPhoto(image, hint: hint, meal: meal, at: at)
                        working = false
                        if let e, e.status == .logged { result = e } else { dismiss() }
                    }
                } label: {
                    HStack { Spacer(); if working { ProgressView() } else { Text("Log photo") }; Spacer() }
                }
                .disabled(image == nil || working)
            } footer: {
                Text(working
                     ? "Estimating. This can take a little while. You can close this screen: the estimate keeps going and shows up in the list."
                     : "The photo and hint go to your chosen AI provider. Nothing else does.").font(StrandFont.caption)
            }
        }
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .fullScreenCover(isPresented: $showCamera) { CameraPicker(image: $image).ignoresSafeArea() }
        .onChange(of: pickerItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) { image = img }
            }
        }
        .onAppear { at = app.logTime; meal = MealType.suggested(for: at) }
        .task {
            // Straight to the camera (one tap fewer). The short wait lets the sheet finish presenting:
            // a cover presented mid-transition is dropped.
            guard !autoOpened, image == nil, UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
            autoOpened = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            if image == nil { showCamera = true }
        }
        .navigationDestination(item: $result) { e in EntryEditView(entry: e, isReview: true, onDone: { dismiss() }) }
    }
}

/// UIImagePickerController camera wrapper.
struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

extension FoodEntry: Hashable {
    public func hash(into h: inout Hasher) { h.combine(id); h.combine(updatedAt) }
}

/// Review or edit one entry. Any change marks it `edited` (Oliver's values win over the AI's).
struct EntryEditView: View {
    @ObservedObject var app = ExtrasApp.shared
    @Environment(\.dismiss) var dismiss
    @State var entry: FoodEntry
    var isReview = false
    var onDone: (() -> Void)?
    @State private var original: FoodEntry?
    @State private var saveMealName = ""
    @State private var askMealName = false
    @State private var mealStatus = ""

    var body: some View {
        Form {
            if let img = app.photo(for: entry) {
                Section { Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220).frame(maxWidth: .infinity) }
            }
            if entry.status != .logged {
                Section {
                    Text(entry.error ?? "Waiting for an estimate.").foregroundStyle(StrandPalette.statusWarning)
                    if entry.photoId != nil {
                        Button("Retry estimate") { Task { await app.retry(entry); reloadEntry() } }
                    }
                    Text("Or enter the items below yourself.").font(StrandFont.caption)
                }
            }
            if let c = entry.confidence, entry.aiOriginal != nil {
                Section {
                    Label("AI confidence: \(c.rawValue)", systemImage: c == .low ? "exclamationmark.triangle" : "sparkles")
                        .foregroundStyle(c == .low ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                    if let note = entry.note { Text(note).font(StrandFont.caption) }
                }
            }
            Section {
                Picker("Meal", selection: $entry.meal) { ForEach(MealType.allCases) { Text($0.title).tag($0) } }
                DatePicker("Time", selection: $entry.at)
            }
            Section("Items") {
                ForEach($entry.items) { $item in ItemEditor(item: $item) }
                    .onDelete { entry.items.remove(atOffsets: $0) }
                Button { entry.items.append(EntryItem(name: "Item", grams: nil, nutrients: .zero)) } label: {
                    Label("Add item", systemImage: "plus")
                }
            }
            Section("Total") {
                NutrientSummary(n: entry.totals)
            }
            Section {
                Button(isReview ? "Looks right, save" : "Save") { save() }.bold()
                Button("Save as a meal…") { askMealName = true }.disabled(entry.items.isEmpty)
                if !mealStatus.isEmpty { Text(mealStatus).font(StrandFont.caption) }
                // Also on the review screen: a wrong estimate is already saved, so it must be removable here.
                Button(isReview ? "Discard this entry" : "Delete entry", role: .destructive) { app.delete(entry); close() }
            }
        }
        .navigationTitle(isReview ? "Check estimate" : "Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(isReview ? "Done" : "Cancel") { close() } } }
        .onAppear { if original == nil { original = entry } }
        .alert("Save as meal", isPresented: $askMealName) {
            TextField("Name", text: $saveMealName)
            Button("Save") {
                let name = saveMealName.isEmpty ? entry.title : saveMealName
                do { try app.store.save(SavedMeal(name: name, items: entry.items)); mealStatus = "Saved as the meal “\(name)”." }
                catch { mealStatus = "Couldn't save the meal: \(error.localizedDescription)" }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    func reloadEntry() {
        if let e = try? app.store.entry(id: entry.id) { entry = e; original = e }
    }

    func save() {
        guard let o = original, o.items != entry.items || o.meal != entry.meal || o.at != entry.at else {
            close()   // nothing changed: don't overwrite an estimate that may have arrived meanwhile
            return
        }
        // Apply only what was changed here onto the latest stored version.
        var e = (try? app.store.entry(id: entry.id)) ?? entry
        e.meal = entry.meal
        e.at = entry.at
        if o.items != entry.items {
            e.items = entry.items
            e.edited = true
            if e.status != .logged && !e.items.isEmpty { e.status = .logged; e.error = nil }
        }
        app.save(e)
        close()
    }

    func close() {
        if let onDone { onDone() } else { dismiss() }
    }
}

struct ItemEditor: View {
    @Binding var item: EntryItem
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            NumberRow("Grams", value: Binding(get: { item.grams ?? 0 }, set: { item.grams = $0 > 0 ? $0 : nil }))
            NumberRow("kcal", value: $item.nutrients.kcal)
            NumberRow("Protein g", value: $item.nutrients.proteinG)
            NumberRow("Carbs g", value: $item.nutrients.carbsG)
            NumberRow("Fat g", value: $item.nutrients.fatG)
            NumberRow("Fibre g", value: $item.nutrients.fiberG)
            NumberRow("Caffeine mg", value: $item.nutrients.caffeineMg)
            NumberRow("Alcohol g", value: $item.nutrients.alcoholG)
            if let g = item.grams, g > 0 {
                Button("Scale everything to a new weight…") { scaleTarget = String(Int(g)); askScale = true }
                    .font(StrandFont.caption)
            }
        } label: {
            HStack {
                TextField("Name", text: $item.name)
                Spacer()
                Text(item.nutrients.kcal.kcalText).foregroundStyle(StrandPalette.textSecondary).monospacedDigit()
            }
        }
        .alert("New weight (g)", isPresented: $askScale) {
            TextField("grams", text: $scaleTarget).keyboardType(.decimalPad)
            Button("Scale") {
                if let g = item.grams, g > 0, let new = Double(scaleTarget.replacingOccurrences(of: ",", with: ".")), new > 0 {
                    item.nutrients = item.nutrients.scaled(by: new / g)
                    item.grams = new
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @State private var askScale = false
    @State private var scaleTarget = ""
}

/// A number field that updates its value on every keystroke (a decimal pad has no Return key, and a
/// value-formatted TextField only commits on Return or focus loss, so Save would see the old value).
struct NumberRow: View {
    let label: String
    @Binding var value: Double
    @State private var text = ""
    init(_ label: String, value: Binding<Double>) { self.label = label; self._value = value }
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 110)
        }
        .onAppear { text = NumberInput.text(value) }
        // Compare as displayed text, so showing a rounded value never writes it back (that would mark
        // an AI entry as edited just by opening it).
        .onChange(of: text) { _, t in
            let v = NumberInput.parse(t) ?? 0
            if NumberInput.text(v) != NumberInput.text(value) { value = v }
        }
        .onChange(of: value) { _, v in
            if NumberInput.text(v) != NumberInput.text(NumberInput.parse(text) ?? 0) { text = NumberInput.text(v) }
        }
    }
}

struct NutrientSummary: View {
    let n: Nutrients
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(n.kcal.kcalText).font(StrandFont.headline)
            Text("Protein \(n.proteinG.gramsText) · Carbs \(n.carbsG.gramsText) · Fat \(n.fatG.gramsText)")
                .font(StrandFont.caption)
            if n.caffeineMg > 0 || n.alcoholG > 0 {
                Text([n.caffeineMg > 0 ? "Caffeine \(Int(n.caffeineMg)) mg" : nil, n.alcoholG > 0 ? "Alcohol \(n.alcoholG.gramsText)" : nil]
                    .compactMap { $0 }.joined(separator: " · ")).font(StrandFont.caption)
            }
        }
    }
}
#endif
