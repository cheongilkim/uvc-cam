import SwiftUI
import AVFoundation
import AVKit
import CoreImage
import CoreMedia
import ImageIO
import PDFKit
import Photos
import UIKit
import Vision

enum CameraPreset: String, CaseIterable, Identifiable {
    case reading1080p10 = "reading_1080p_10fps"
    case uhd4k          = "uhd_4k"
    case fhd1080p30     = "fhd_1080p_30fps"
    case hd720p30       = "hd_720p_30fps"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reading1080p10: return "1080p 독서·저발열 (10fps)"
        case .uhd4k:          return "4K 초고화질 (2160p)"
        case .fhd1080p30:     return "1080p 부드럽게 (30fps)"
        case .hd720p30:       return "720p 초저발열 (30fps)"
        }
    }

    var shortTitle: String {
        switch self {
        case .reading1080p10: return "1080p 10fps"
        case .uhd4k:          return "4K 2160p"
        case .fhd1080p30:     return "1080p 30fps"
        case .hd720p30:       return "720p 30fps"
        }
    }

    var targetWidth: Int32 {
        switch self {
        case .reading1080p10, .fhd1080p30: return 1920
        case .uhd4k:                       return 3840
        case .hd720p30:                    return 1280
        }
    }

    var targetHeight: Int32 {
        switch self {
        case .reading1080p10, .fhd1080p30: return 1080
        case .uhd4k:                       return 2160
        case .hd720p30:                    return 720
        }
    }

    var targetFPS: Double {
        switch self {
        case .reading1080p10: return 10
        case .uhd4k, .fhd1080p30, .hd720p30: return 30
        }
    }
}

enum ScanFilter: String, CaseIterable, Identifiable {
    case enhancedColor = "선명한 컬러"
    case blackAndWhite = "흑백 스캔"
    case original      = "원본"

    var id: String { rawValue }
}

enum StatusLevel {
    case live
    case warn
    case error

    var color: Color {
        switch self {
        case .live:  return Color(red: 0.20, green: 0.84, blue: 0.29)
        case .warn:  return Color(red: 1.00, green: 0.84, blue: 0.04)
        case .error: return Color(red: 1.00, green: 0.27, blue: 0.23)
        }
    }
}

struct CameraItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isExternal: Bool
}

struct ScanDraft {
    let fullCI: CIImage
    let croppedCI: CIImage?
    var hasDetectedQuad: Bool { croppedCI != nil }
}

final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var cameras: [CameraItem] = []
    @Published var activeCameraId: String?
    @Published var currentOutputName: String = "스피커"
    @Published var statusLevel: StatusLevel = .warn
    @Published var statusText: String = "UVC 카메라 검색 중..."
    @Published var metaText: String = "대기"
    @Published var needsPermissionSettings: Bool = false
    @Published var toastMessage: String?
    @Published var shutterFlash: Bool = false

    // Document scan state
    @Published var showScanSheet: Bool = false
    @Published var scanImage: UIImage?
    @Published var scanHasQuad: Bool = false
    @Published var scanUseCrop: Bool = true {
        didSet { updateRenderedScanImage() }
    }
    @Published var scanFilter: ScanFilter = .enhancedColor {
        didSet { updateRenderedScanImage() }
    }
    @Published var pdfPages: [UIImage] = []

    @Published var preset: CameraPreset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: Keys.preset)
            if oldValue != preset {
                showToast("화질 설정: \(preset.shortTitle)")
                restartActiveCamera(reason: "preset")
            }
        }
    }

    @Published var rotationDegrees: Int {
        didSet {
            UserDefaults.standard.set(rotationDegrees, forKey: Keys.rotation)
            updateMetaText()
        }
    }

    @Published var mirrored: Bool {
        didSet {
            UserDefaults.standard.set(mirrored, forKey: Keys.mirrored)
        }
    }

    @Published var fillScreen: Bool {
        didSet {
            UserDefaults.standard.set(fillScreen, forKey: Keys.fillScreen)
        }
    }

    let session = AVCaptureSession()

    private enum Keys {
        static let preset = "uvccam_preset"
        static let rotation = "uvccam_rotation"
        static let mirrored = "uvccam_mirrored"
        static let fillScreen = "uvccam_fill"
    }

    private let sessionQueue = DispatchQueue(label: "com.cheongilkim.uvccam.session")
    private let videoOutputQueue = DispatchQueue(label: "com.cheongilkim.uvccam.videooutput")
    private let frameLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoOutputAdded = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var currentScanDraft: ScanDraft?

    private var currentInput: AVCaptureDeviceInput?
    private var manualOverride = false
    private var isExternalActive = false
    private var activeDimensions: (Int32, Int32) = (0, 0)
    private var activeFps: Int = 0
    private var toastWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    override init() {
        let defaults = UserDefaults.standard
        let savedPreset = defaults.string(forKey: Keys.preset).flatMap(CameraPreset.init(rawValue:)) ?? .reading1080p10
        let savedRot = defaults.integer(forKey: Keys.rotation)
        let validRot = [0, 90, 180, 270].contains(savedRot) ? savedRot : 0

        self.preset = savedPreset
        self.rotationDegrees = validRot
        self.mirrored = defaults.bool(forKey: Keys.mirrored)
        self.fillScreen = defaults.bool(forKey: Keys.fillScreen)

        super.init()
        setupObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        refreshOutputRouteName()
        checkPermissionAndStart()
    }

    func stop() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func rotateStep() {
        rotationDegrees = (rotationDegrees + 90) % 360
        showToast("화면 회전 \(rotationDegrees)°")
    }

    func toggleMirror() {
        mirrored.toggle()
        showToast(mirrored ? "좌우 반전 켜짐" : "좌우 반전 꺼짐")
    }

    func toggleFit() {
        fillScreen.toggle()
        showToast(fillScreen ? "꽉 채우기 (Cover)" : "전체 보기 (Contain)")
    }

    func selectCamera(id: String) {
        manualOverride = true
        configureAndStart(preferredId: id)
    }

    func reconnect() {
        manualOverride = false
        showToast("UVC 카메라 재검색 중...")
        refreshOutputRouteName()
        configureAndStart(preferredId: nil)
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func refreshOutputRouteName() {
        let outPort = AVAudioSession.sharedInstance().currentRoute.outputs.first
        let outName = outPort?.portName ?? "스피커"
        DispatchQueue.main.async {
            self.currentOutputName = outName
        }
    }

    // MARK: - Frame Capture, Photo & Document Scan

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        latestPixelBuffer = pb
        frameLock.unlock()
    }

    private func orientedSnapshotCIImage() -> CIImage? {
        frameLock.lock()
        let pb = latestPixelBuffer
        frameLock.unlock()
        guard let pixelBuffer = pb else { return nil }

        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        let rotOrientation: CGImagePropertyOrientation
        switch rotationDegrees {
        case 90:  rotOrientation = .right
        case 180: rotOrientation = .down
        case 270: rotOrientation = .left
        default:  rotOrientation = .up
        }
        if rotOrientation != .up {
            ci = ci.oriented(rotOrientation)
        }
        if mirrored {
            ci = ci.oriented(.upMirrored)
        }
        return ci
    }

    private func triggerShutterFlash() {
        DispatchQueue.main.async {
            self.shutterFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                self.shutterFlash = false
            }
        }
    }

    func capturePhoto() {
        guard let ci = orientedSnapshotCIImage(),
              let cg = ciContext.createCGImage(ci, from: ci.extent) else {
            showToast("카메라 프레임 대기 중입니다")
            return
        }
        triggerShutterFlash()
        let uiImage = UIImage(cgImage: cg)
        saveImageToPhotos(uiImage, successToast: "📸 사진이 사진첩에 저장되었습니다")
    }

    func scanDocument() {
        guard let ci = orientedSnapshotCIImage() else {
            showToast("카메라 프레임 대기 중입니다")
            return
        }
        triggerShutterFlash()
        showToast("문서 테두리 인식 중...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let cropped = self.detectAndWarpDocument(in: ci)
            let draft = ScanDraft(fullCI: ci, croppedCI: cropped)
            DispatchQueue.main.async {
                self.currentScanDraft = draft
                self.scanHasQuad = draft.hasDetectedQuad
                self.scanUseCrop = draft.hasDetectedQuad
                self.scanFilter = .enhancedColor
                self.updateRenderedScanImage()
                self.showScanSheet = true
            }
        }
    }

    private func detectAndWarpDocument(in ci: CIImage) -> CIImage? {
        let req = VNDetectRectanglesRequest()
        req.maximumObservations = 1
        req.minimumAspectRatio = 0.25
        req.maximumAspectRatio = 1.0
        req.minimumSize = 0.2
        req.quadratureTolerance = 35.0
        req.minimumConfidence = 0.55

        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        try? handler.perform([req])
        guard let obs = req.results?.first else { return nil }

        let ext = ci.extent
        func toPixel(_ pt: CGPoint) -> CIVector {
            CIVector(x: ext.origin.x + pt.x * ext.width, y: ext.origin.y + pt.y * ext.height)
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(toPixel(obs.topLeft), forKey: "inputTopLeft")
        filter.setValue(toPixel(obs.topRight), forKey: "inputTopRight")
        filter.setValue(toPixel(obs.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(toPixel(obs.bottomRight), forKey: "inputBottomRight")
        return filter.outputImage
    }

    private func applyFilter(_ filterKind: ScanFilter, to input: CIImage) -> CIImage {
        switch filterKind {
        case .original:
            return input
        case .enhancedColor:
            var out = input
            if let cc = CIFilter(name: "CIColorControls") {
                cc.setValue(out, forKey: kCIInputImageKey)
                cc.setValue(1.12, forKey: kCIInputSaturationKey)
                cc.setValue(1.25, forKey: kCIInputContrastKey)
                cc.setValue(0.04, forKey: kCIInputBrightnessKey)
                if let img = cc.outputImage { out = img }
            }
            if let sh = CIFilter(name: "CISharpenLuminance") {
                sh.setValue(out, forKey: kCIInputImageKey)
                sh.setValue(0.65, forKey: kCIInputSharpnessKey)
                if let img = sh.outputImage { out = img }
            }
            return out
        case .blackAndWhite:
            var out = input
            if let cc = CIFilter(name: "CIColorControls") {
                cc.setValue(out, forKey: kCIInputImageKey)
                cc.setValue(0.0, forKey: kCIInputSaturationKey)
                cc.setValue(1.55, forKey: kCIInputContrastKey)
                cc.setValue(0.06, forKey: kCIInputBrightnessKey)
                if let img = cc.outputImage { out = img }
            }
            if let sh = CIFilter(name: "CISharpenLuminance") {
                sh.setValue(out, forKey: kCIInputImageKey)
                sh.setValue(0.8, forKey: kCIInputSharpnessKey)
                if let img = sh.outputImage { out = img }
            }
            return out
        }
    }

    private func updateRenderedScanImage() {
        guard let draft = currentScanDraft else { return }
        let baseCI = (scanUseCrop && draft.croppedCI != nil) ? draft.croppedCI! : draft.fullCI
        let filtered = applyFilter(scanFilter, to: baseCI)
        if let cg = ciContext.createCGImage(filtered, from: filtered.extent) {
            scanImage = UIImage(cgImage: cg)
        }
    }

    func saveCurrentScanToPhotos() {
        guard let img = scanImage else { return }
        saveImageToPhotos(img, successToast: "📄 스캔 이미지가 사진첩에 저장되었습니다")
    }

    func addCurrentScanToPdfBatch() {
        guard let img = scanImage else { return }
        pdfPages.append(img)
        showScanSheet = false
        showToast("📄 PDF 묶음에 추가됨 (총 \(pdfPages.count)장)")
    }

    func clearPdfBatch() {
        pdfPages.removeAll()
        showToast("PDF 묶음이 초기화되었습니다")
    }

    func exportPdfBatch(includingCurrentScan: Bool) {
        var pages = pdfPages
        if includingCurrentScan, let current = scanImage {
            pages.append(current)
        }
        guard !pages.isEmpty else {
            showToast("PDF로 만들 스캔 페이지가 없습니다")
            return
        }

        let pdfDoc = PDFDocument()
        for (idx, pageImg) in pages.enumerated() {
            if let pdfPage = PDFPage(image: pageImg) {
                pdfDoc.insert(pdfPage, at: idx)
            }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "UVC_Scan_\(fmt.string(from: Date())).pdf"
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        guard pdfDoc.write(to: outURL) else {
            showToast("PDF 파일 생성에 실패했습니다")
            return
        }

        showScanSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.presentShareSheet(items: [outURL])
        }
    }

    private func presentShareSheet(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController else {
            return
        }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        topVC.present(activityVC, animated: true)
    }

    private func saveImageToPhotos(_ image: UIImage, successToast: String) {
        let performSave = {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { [weak self] success, error in
                DispatchQueue.main.async {
                    if success {
                        self?.showToast(successToast)
                    } else {
                        self?.showToast("저장 실패: \(error?.localizedDescription ?? "권한 확인 필요")")
                    }
                }
            }
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            performSave()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    performSave()
                } else {
                    self.showToast("사진첩 저장 권한이 거부되었습니다")
                }
            }
        default:
            showToast("iPad 설정에서 UVC Cam의 사진첩 권한을 허용해 주세요")
        }
    }

    // MARK: - Observers & Camera

    private func showToast(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.toastWorkItem?.cancel()
            self.toastMessage = text
            let work = DispatchWorkItem { [weak self] in
                self?.toastMessage = nil
            }
            self.toastWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
        }
    }

    private func setupObservers() {
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.refreshCameraList()
            self.refreshOutputRouteName()
            if !self.manualOverride {
                self.showToast("새 카메라 감지됨")
                self.configureAndStart(preferredId: nil)
            }
        })

        observers.append(nc.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            self.refreshCameraList()
            self.refreshOutputRouteName()
            if let dev = note.object as? AVCaptureDevice, dev.uniqueID == self.activeCameraId {
                self.manualOverride = false
                self.setStatus(.warn, "카메라 연결 해제 · 재검색 중...")
                self.configureAndStart(preferredId: nil)
            }
        })

        observers.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshOutputRouteName()
        })

        observers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            UIApplication.shared.isIdleTimerDisabled = true
            self.refreshOutputRouteName()
            self.ensureRunningOrRecover()
        })

        observers.append(nc.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.setStatus(.error, "카메라 세션 오류 · 복구 중...")
            self?.restartActiveCamera(reason: "error")
        })

        observers.append(nc.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.ensureRunningOrRecover()
        })
    }

    private func checkPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.needsPermissionSettings = false }
            configureAndStart(preferredId: nil)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.needsPermissionSettings = !granted
                    if granted {
                        self.configureAndStart(preferredId: nil)
                    } else {
                        self.setStatus(.error, "카메라 권한 필요")
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.needsPermissionSettings = true
                self.setStatus(.error, "카메라 권한이 거부됨")
            }
        }
    }

    private func discoverDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    @discardableResult
    private func refreshCameraList() -> [AVCaptureDevice] {
        let devices = discoverDevices()
        let items = devices.map { dev in
            CameraItem(
                id: dev.uniqueID,
                name: dev.localizedName,
                isExternal: dev.deviceType == .external
            )
        }
        DispatchQueue.main.async {
            self.cameras = items
        }
        return devices
    }

    private func pickBestDevice(from devices: [AVCaptureDevice], preferredId: String?) -> AVCaptureDevice? {
        if let preferredId = preferredId,
           let matched = devices.first(where: { $0.uniqueID == preferredId }) {
            return matched
        }
        if let external = devices.first(where: { $0.deviceType == .external }) {
            return external
        }
        if let back = devices.first(where: { $0.position == .back }) {
            return back
        }
        return devices.first
    }

    private func restartActiveCamera(reason: String) {
        configureAndStart(preferredId: manualOverride ? activeCameraId : nil)
    }

    private func ensureRunningOrRecover() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning {
                if self.currentInput == nil {
                    self.configureAndStart(preferredId: self.manualOverride ? self.activeCameraId : nil)
                } else {
                    self.session.startRunning()
                }
            }
        }
    }

    private func configureAndStart(preferredId: String?) {
        let targetPreset = self.preset
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            let devices = self.refreshCameraList()
            guard let device = self.pickBestDevice(from: devices, preferredId: preferredId) else {
                self.setStatus(.error, "연결된 카메라 없음")
                return
            }

            let isExt = device.deviceType == .external
            self.isExternalActive = isExt
            self.setStatus(.warn, isExt ? "UVC 연결 중 · \(device.localizedName)" : "카메라 연결 중...")

            self.session.beginConfiguration()
            self.session.automaticallyConfiguresApplicationAudioSession = false
            if self.session.canSetSessionPreset(.inputPriority) {
                self.session.sessionPreset = .inputPriority
            }

            if self.session.isMultitaskingCameraAccessSupported {
                self.session.isMultitaskingCameraAccessEnabled = true
            }

            if let existing = self.currentInput {
                self.session.removeInput(existing)
                self.currentInput = nil
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.currentInput = input
                } else {
                    self.session.commitConfiguration()
                    self.setStatus(.error, "카메라 입력 추가 실패")
                    return
                }
            } catch {
                self.session.commitConfiguration()
                self.setStatus(.error, "카메라 열기 실패: \(error.localizedDescription)")
                return
            }

            if !self.videoOutputAdded {
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                    self.videoOutputAdded = true
                }
            }

            self.applyFormatAndFps(device: device, preset: targetPreset)
            self.session.commitConfiguration()

            if !self.session.isRunning {
                self.session.startRunning()
            }

            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let fpsVal = self.currentConfiguredFps(for: device)

            DispatchQueue.main.async {
                self.activeDimensions = (dims.width, dims.height)
                self.activeFps = fpsVal
                self.activeCameraId = device.uniqueID
                self.updateMetaText()
                self.refreshOutputRouteName()
                if isExt {
                    self.setStatus(.live, "UVC 연결됨 · \(device.localizedName)")
                } else {
                    self.setStatus(.warn, "UVC 미감지(내장: \(device.localizedName))")
                }
            }
        }
    }

    private func applyFormatAndFps(device: AVCaptureDevice, preset: CameraPreset) {
        let formats = device.formats
        guard !formats.isEmpty else { return }

        let targetW = Int(preset.targetWidth)
        let targetH = Int(preset.targetHeight)
        let targetFPS = preset.targetFPS

        let bestFormat = formats.min { a, b in
            scoreFormat(a, targetW: targetW, targetH: targetH, targetFPS: targetFPS)
                < scoreFormat(b, targetW: targetW, targetH: targetH, targetFPS: targetFPS)
        }

        guard let chosen = bestFormat else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            device.activeFormat = chosen

            let ranges = chosen.videoSupportedFrameRateRanges
            if let _ = ranges.first(where: { $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate }) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            } else if let closestRange = ranges.min(by: {
                abs($0.maxFrameRate - targetFPS) < abs($1.maxFrameRate - targetFPS)
            }) {
                let clamped = min(max(targetFPS, closestRange.minFrameRate), closestRange.maxFrameRate)
                let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(clamped.rounded()))))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
        } catch {
            // Fall back to default device format if configuration is locked or unsupported
        }
    }

    private func scoreFormat(_ format: AVCaptureDevice.Format, targetW: Int, targetH: Int, targetFPS: Double) -> Double {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let w = Int(dims.width)
        let h = Int(dims.height)
        let dist = Double(abs(w - targetW) * 2 + abs(h - targetH) * 2)
        let supportsFPS = format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
        }
        let fpsPenalty = supportsFPS ? 0.0 : 5000.0
        return dist + fpsPenalty
    }

    private func currentConfiguredFps(for device: AVCaptureDevice) -> Int {
        let dur = device.activeVideoMaxFrameDuration
        if dur.isValid && !dur.isIndefinite && dur.seconds > 0 {
            return max(1, Int((1.0 / dur.seconds).rounded()))
        }
        if let maxRange = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() {
            return Int(maxRange.rounded())
        }
        return 0
    }

    private func setStatus(_ level: StatusLevel, _ text: String) {
        DispatchQueue.main.async {
            self.statusLevel = level
            self.statusText = text
        }
    }

    private func updateMetaText() {
        let (w, h) = activeDimensions
        DispatchQueue.main.async {
            if w > 0 && h > 0 {
                let fpsPart = self.activeFps > 0 ? " · \(self.activeFps)fps" : ""
                self.metaText = "\(w)×\(h)\(fpsPart) · \(self.rotationDegrees)°"
            } else {
                self.metaText = "회전 \(self.rotationDegrees)°"
            }
        }
    }
}

final class PreviewUIView: UIView {
    private let mirrorContainer = UIView()
    private let previewLayer = AVCaptureVideoPreviewLayer()

    var rotationDegrees: Int = 0 {
        didSet { if oldValue != rotationDegrees { setNeedsLayout() } }
    }

    var mirrored: Bool = false {
        didSet { if oldValue != mirrored { setNeedsLayout() } }
    }

    var fillScreen: Bool = false {
        didSet { if oldValue != fillScreen { setNeedsLayout() } }
    }

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true

        mirrorContainer.backgroundColor = .black
        mirrorContainer.clipsToBounds = true
        addSubview(mirrorContainer)

        previewLayer.session = session
        previewLayer.backgroundColor = UIColor.black.cgColor
        mirrorContainer.layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        mirrorContainer.frame = bounds
        mirrorContainer.transform = mirrored
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity

        previewLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect

        let isQuarterTurn = (rotationDegrees == 90 || rotationDegrees == 270)
        let targetSize = isQuarterTurn
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size

        previewLayer.bounds = CGRect(origin: .zero, size: targetSize)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let angle = CGFloat(rotationDegrees) * .pi / 180.0
        previewLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))

        CATransaction.commit()
    }
}

struct CameraPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession
    let rotationDegrees: Int
    let mirrored: Bool
    let fillScreen: Bool

    func makeUIView(context: Context) -> PreviewUIView {
        PreviewUIView(session: session)
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.rotationDegrees = rotationDegrees
        uiView.mirrored = mirrored
        uiView.fillScreen = fillScreen
    }
}

final class FullAreaRoutePickerContainer: UIView {
    let picker = AVRoutePickerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.prioritizesVideoDevices = false
        picker.alpha = 0.02
        addSubview(picker)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
        for subview in picker.subviews {
            subview.frame = picker.bounds
        }
    }
}

struct RoutePickerOverlayRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> FullAreaRoutePickerContainer {
        FullAreaRoutePickerContainer()
    }

    func updateUIView(_ uiView: FullAreaRoutePickerContainer, context: Context) {}
}

struct ScanReviewSheet: View {
    @ObservedObject var controller: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let img = controller.scanImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Spacer()
                    ProgressView("스캔 처리 중...")
                    Spacer()
                }

                Picker("필터", selection: $controller.scanFilter) {
                    ForEach(ScanFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                if controller.scanHasQuad {
                    Toggle("자동 테두리 원근 보정", isOn: $controller.scanUseCrop)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 4)
                }

                HStack(spacing: 10) {
                    Button {
                        controller.saveCurrentScanToPhotos()
                    } label: {
                        Label("사진첩 저장", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        controller.addCurrentScanToPdfBatch()
                    } label: {
                        Label("PDF 추가 (\(controller.pdfPages.count)장)", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Button {
                        controller.exportPdfBatch(includingCurrentScan: true)
                    } label: {
                        Label("PDF 내보내기 (\(controller.pdfPages.count + 1)장)", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if !controller.pdfPages.isEmpty {
                        Button(role: .destructive) {
                            controller.clearPdfBatch()
                        } label: {
                            Text("초기화")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(16)
            .navigationTitle("문서 스캔 미리보기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct ContentView: View {
    @StateObject private var controller = CameraController()
    @State private var hudHidden = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewRepresentable(
                session: controller.session,
                rotationDegrees: controller.rotationDegrees,
                mirrored: controller.mirrored,
                fillScreen: controller.fillScreen
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    hudHidden.toggle()
                }
            }

            if controller.shutterFlash {
                Color.white.opacity(0.65)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if !hudHidden {
                VStack {
                    topHud
                    Spacer()
                    bottomHud
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .transition(.opacity)
            }

            if controller.needsPermissionSettings {
                permissionOverlay
            }

            if let toast = controller.toastMessage {
                Text(toast)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .transition(.opacity)
            }
        }
        .statusBarHidden(hudHidden)
        .persistentSystemOverlays(hudHidden ? .hidden : .automatic)
        .sheet(isPresented: $controller.showScanSheet) {
            ScanReviewSheet(controller: controller)
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    private var topHud: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.statusLevel.color)
                    .frame(width: 9, height: 9)
                    .shadow(color: controller.statusLevel.color.opacity(0.8), radius: 5)
                Text(controller.statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))

            Spacer()

            if !controller.pdfPages.isEmpty {
                Button {
                    controller.exportPdfBatch(includingCurrentScan: false)
                } label: {
                    Text("PDF \(controller.pdfPages.count)장")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.65), in: Capsule())
                        .overlay(Capsule().stroke(Color.blue, lineWidth: 1))
                }
            }

            Text(controller.metaText)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.75))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
    }

    private var bottomHud: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { controller.capturePhoto() } label: {
                    HudChipLabel(text: "📸 사진", systemImage: "camera.shutter.button")
                }

                Button { controller.scanDocument() } label: {
                    HudChipLabel(text: "📄 문서스캔", systemImage: "doc.viewfinder")
                }

                Menu {
                    ForEach(controller.cameras) { cam in
                        Button {
                            controller.selectCamera(id: cam.id)
                        } label: {
                            let prefix = cam.isExternal ? "[UVC] " : "[내장] "
                            if cam.id == controller.activeCameraId {
                                Label(prefix + cam.name, systemImage: "checkmark")
                            } else {
                                Text(prefix + cam.name)
                            }
                        }
                    }
                } label: {
                    let activeName = controller.cameras.first(where: { $0.id == controller.activeCameraId })?.name ?? "카메라"
                    HudChipLabel(text: activeName, systemImage: "camera")
                }

                Menu {
                    ForEach(CameraPreset.allCases) { p in
                        Button {
                            controller.preset = p
                        } label: {
                            if p == controller.preset {
                                Label(p.title, systemImage: "checkmark")
                            } else {
                                Text(p.title)
                            }
                        }
                    }
                } label: {
                    HudChipLabel(text: controller.preset.shortTitle, systemImage: "slider.horizontal.3")
                }

                ZStack {
                    HudChipLabel(
                        text: controller.currentOutputName,
                        systemImage: "speaker.wave.2.fill"
                    )
                    RoutePickerOverlayRepresentable()
                }
                .fixedSize()

                Button { controller.rotateStep() } label: {
                    HudButtonLabel(
                        text: "회전 \(controller.rotationDegrees)°",
                        active: controller.rotationDegrees != 0
                    )
                }

                Button { controller.toggleMirror() } label: {
                    HudButtonLabel(text: "좌우반전", active: controller.mirrored)
                }

                Button { controller.toggleFit() } label: {
                    HudButtonLabel(
                        text: controller.fillScreen ? "꽉채우기" : "전체보기",
                        active: controller.fillScreen
                    )
                }

                Button { controller.reconnect() } label: {
                    Text("재연결")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.blue.opacity(0.8), lineWidth: 1)
                        )
                }
            }
            .padding(10)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    private var permissionOverlay: some View {
        ZStack {
            Color.black.opacity(0.84).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("카메라 접근 권한이 필요합니다")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                Text("iPad 설정에서 UVC Cam 앱의 카메라 권한을 허용해 주세요.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                Button("설정 열기") {
                    controller.openAppSettings()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(24)
            .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(24)
        }
    }
}

private struct HudChipLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 130, alignment: .leading)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct HudButtonLabel: View {
    let text: String
    let active: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(active ? Color(red: 0.85, green: 1.0, blue: 0.88) : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                active ? Color.green.opacity(0.32) : Color.white.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        active ? Color.green.opacity(0.7) : Color.white.opacity(0.18),
                        lineWidth: 1
                    )
            )
    }
}

@main
struct UVCCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
