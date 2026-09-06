import SwiftUI
#if os(iOS)
import AVFoundation

/// Сканер QR-кода промокода. Работает на iPhone и iPad; на Mac камеру
/// не используем — там код вводят с клавиатуры.
struct QRScannerView: View {
    /// Вызывается один раз при первом распознанном коде.
    var onFound: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var permission: PermissionState = .checking
    @State private var didFind = false

    private enum PermissionState { case checking, granted, denied }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                switch permission {
                case .checking:
                    ProgressView().tint(.white)
                case .denied:
                    deniedState
                case .granted:
                    CameraPreview(isPaused: didFind) { payload in
                        guard !didFind, let code = QRCode.promoCode(from: payload) else { return }
                        didFind = true
                        // Тактильный отклик подтверждает, что код поймали.
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        onFound(code)
                        dismiss()
                    }
                    .ignoresSafeArea()

                    scannerOverlay
                }
            }
            .navigationTitle("Сканирование кода")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .task { await requestAccess() }
    }

    private var scannerOverlay: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)
            Text("Наведите камеру на QR-код")
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.top, 20)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var deniedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.8))
            Text("Нет доступа к камере")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Разрешите доступ в «Настройках», чтобы сканировать промокоды, или введите код вручную.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Button("Открыть настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(32)
    }

    private func requestAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .granted
        case .notDetermined:
            permission = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default:
            permission = .denied
        }
    }
}

// MARK: - Слой камеры

private struct CameraPreview: UIViewControllerRepresentable {
    var isPaused: Bool
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onScan = onScan
        if isPaused { controller.stop() }
    }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    // Конфигурация и запуск сессии блокируют поток, поэтому уводим их с главного.
    private let sessionQueue = DispatchQueue(label: "qr.session")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Типы задаются только после добавления выхода в сессию.
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    func stop() {
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        MainActor.assumeIsolated {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            onScan?(value)
        }
    }
}
#endif
