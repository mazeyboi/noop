#if os(iOS)
import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import NutritionCore
import StrandDesign

struct NutritionAIPhotoView: View {
    let onDetected: ([NutritionPlateItem]) -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var note = ""
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var showingCamera = false
    @State private var showingSettings = false
    @State private var cameraPermissionDenied = false
    @State private var hasKey = NutritionAIKeyStore.read() != nil

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("Gemini food estimate")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("AI estimates must be reviewed before logging.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "key")
                }
                .buttonStyle(NoopButtonStyle(.tertiary))
                .accessibilityLabel("Nutrition AI Settings")
            }

            if !hasKey {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "key.slash")
                    Text("Gemini API key missing")
                    Spacer()
                    Button("Add Key") { showingSettings = true }
                }
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(NoopMetrics.space3)
                .background(StrandPalette.surfaceInset)
                .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
            }

            HStack(spacing: NoopMetrics.space2) {
                NoopButton("Take Photo", systemImage: "camera", kind: .secondary, fullWidth: true) {
                    requestCamera()
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            }

            if imageData != nil {
                Label("Photo ready", systemImage: "checkmark.circle.fill")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
            }

            NutritionTextField(title: "Optional note, e.g. dressing on the side", text: $note)

            if let errorMessage {
                Text(errorMessage)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.recovery000)
            }

            NoopButton(
                isAnalyzing ? "Analyzing..." : "Analyze Photo",
                systemImage: "sparkles",
                kind: .primary,
                fullWidth: true
            ) {
                analyze()
            }
            .disabled(imageData == nil || !hasKey || isAnalyzing)
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    imageData = data.flatMap(NutritionImageProcessor.jpegData)
                    if imageData == nil { errorMessage = NutritionAIError.invalidImage.localizedDescription }
                    photoItem = nil
                }
            }
        }
        .sheet(isPresented: $showingCamera) {
            NutritionCameraPicker { data in
                if let data {
                    imageData = data
                    errorMessage = nil
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            hasKey = NutritionAIKeyStore.read() != nil
        }) {
            NutritionAISettingsView()
        }
        .alert("Camera Access Needed", isPresented: $cameraPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow camera access in Settings to take a food photo. Choosing an existing photo still works without it.")
        }
    }

    private func analyze() {
        guard let imageData else { return }
        isAnalyzing = true
        errorMessage = nil
        Task {
            do {
                let items = try await NutritionAIService().analyze(imageData: imageData, note: note)
                await MainActor.run {
                    onDetected(items)
                    self.imageData = nil
                    note = ""
                    isAnalyzing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? "The photo could not be analyzed."
                    isAnalyzing = false
                }
            }
        }
    }

    private func requestCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "A camera is not available on this device."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingCamera = true
        case .notDetermined:
            Task {
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                await MainActor.run {
                    if allowed { showingCamera = true } else { cameraPermissionDenied = true }
                }
            }
        default:
            cameraPermissionDenied = true
        }
    }
}

private struct NutritionAISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Text("Gemini API Key").strandOverline()
                SecureField("Paste API key", text: $key)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .padding(.horizontal, NoopMetrics.space3)
                    .frame(height: NoopMetrics.controlHeight)
                    .background(StrandPalette.surfaceInset)
                    .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))

                Text("The key is stored in Apple Keychain. A selected food photo and optional note are sent directly to Google only when you tap Analyze. Nutrition remains fully usable without AI.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if saveFailed {
                    Text("The key could not be stored in Keychain.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.recovery000)
                }

                if NutritionAIKeyStore.read() != nil {
                    NoopButton("Remove Key", systemImage: "trash", kind: .destructive, fullWidth: true) {
                        NutritionAIKeyStore.clear()
                        dismiss()
                    }
                }
                Spacer()
            }
            .padding(NoopMetrics.space5)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Nutrition AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if NutritionAIKeyStore.save(key) { dismiss() } else { saveFailed = true }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
#endif
