#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit
import StrandDesign

struct NutritionBarcodeScannerView: View {
    let onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var permissionDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                StrandPalette.surfaceBase.ignoresSafeArea()
                NutritionBarcodeScannerRepresentable(
                    onCode: { code in
                        onCode(code)
                        dismiss()
                    },
                    onPermissionDenied: { permissionDenied = true }
                )
                .ignoresSafeArea()

                RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous)
                    .stroke(StrandPalette.accent, lineWidth: 3)
                    .frame(width: 280, height: 170)
                    .accessibilityHidden(true)

                VStack {
                    Spacer()
                    Text("Hold a packaged-food barcode inside the frame")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(NoopMetrics.space4)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
                        .padding(.bottom, NoopMetrics.space6)
                }
            }
            .navigationTitle("Scan Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Camera Access Needed", isPresented: $permissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { dismiss() }
            } message: {
                Text("Allow camera access in Settings to scan packaged-food barcodes. You can still search or add food manually.")
            }
        }
    }
}

private struct NutritionBarcodeScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onPermissionDenied: () -> Void

    func makeUIViewController(context: Context) -> NutritionBarcodeScannerController {
        NutritionBarcodeScannerController(onCode: onCode, onPermissionDenied: onPermissionDenied)
    }

    func updateUIViewController(_ uiViewController: NutritionBarcodeScannerController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: NutritionBarcodeScannerController, coordinator: ()) {
        uiViewController.stopSession()
    }
}

private final class NutritionBarcodeScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.noop.nutrition.barcode-session")
    private let onCode: (String) -> Void
    private let onPermissionDenied: () -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didEmitCode = false
    private var configured = false
    private var wantsRunning = false

    init(onCode: @escaping (String) -> Void, onPermissionDenied: @escaping () -> Void) {
        self.onCode = onCode
        self.onPermissionDenied = onPermissionDenied
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task { @MainActor in
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                allowed = true
            case .notDetermined:
                allowed = await AVCaptureDevice.requestAccess(for: .video)
            default:
                allowed = false
            }
            guard allowed else {
                onPermissionDenied()
                return
            }
            configureSession()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            wantsRunning = true
            if configured, !session.isRunning { session.startRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configureSession() {
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        sessionQueue.async { [weak self] in
            guard let self, !configured else { return }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                DispatchQueue.main.async { self.onPermissionDenied() }
                return
            }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.onPermissionDenied() }
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.ean8, .ean13, .upce, .code128]
            session.commitConfiguration()
            configured = true
            if wantsRunning, !session.isRunning { session.startRunning() }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            wantsRunning = false
            if session.isRunning { session.stopRunning() }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmitCode,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue,
              !code.isEmpty else { return }
        didEmitCode = true
        stopSession()
        onCode(code)
    }
}

struct NutritionCameraPicker: UIViewControllerRepresentable {
    let onImage: (Data?) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: NutritionCameraPicker

        init(parent: NutritionCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            parent.onImage(image.flatMap(NutritionImageProcessor.jpegData))
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onImage(nil)
            parent.dismiss()
        }
    }
}

enum NutritionImageProcessor {
    static func jpegData(_ image: UIImage) -> Data? {
        let maximumDimension: CGFloat = 1_600
        let largest = max(image.size.width, image.size.height)
        let scale = largest > maximumDimension ? maximumDimension / largest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.82)
    }

    static func jpegData(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpegData(image)
    }
}
#endif
