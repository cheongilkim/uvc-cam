import SwiftUI
import AVFoundation
import AVKit
import CoreMedia
import UIKit

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

struct AudioInputItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isExternal: Bool
}

final class CameraController: NSObject, ObservableObject {
    static let micOffId = "off"

    @Published var cameras: [CameraItem] = []
    @Published var activeCameraId: String?
    @Published var audioInputs: [AudioInputItem] = []
    @Published var selectedMicId: String = CameraController.micOffId
    @Published var currentOutputName: String = "스피커"
    @Published var statusLevel: StatusLevel = .warn
    @Published var statusText: String = "UVC 카메라 검색 중..."
    @Published var metaText: String = "대기"
    @Published var needsPermissionSettings: Bool = false
    @Published var toastMessage: String?

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
    private let audioEngine = AVAudioEngine()
    private var isMonitoringAudio = false
    private var hasActivatedAudioSession = false
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
        deactivateAudioSessionForGemini()
    }

    func start() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        // Keep audio session completely idle so Gemini Live never gets interrupted
        deactivateAudioSessionForGemini()
        refreshAudioRoutes()
        checkPermissionAndStart()
    }

    func stop() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        deactivateAudioSessionForGemini()
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
        refreshAudioRoutes()
        configureAndStart(preferredId: nil)
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Audio Input / Output (Gemini Live Safe)

    func selectMicrophone(id: String) {
        if id == Self.micOffId {
            selectedMicId = Self.micOffId
            deactivateAudioSessionForGemini()
            refreshAudioRoutes()
            showToast("마이크 끔 (Gemini Live 호환 모드)")
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        switch audioSession.recordPermission {
        case .granted:
            applySelectedMicrophone(id: id)
        case .undetermined:
            audioSession.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.applySelectedMicrophone(id: id)
                    } else {
                        self.selectedMicId = Self.micOffId
                        self.deactivateAudioSessionForGemini()
                        self.showToast("마이크 권한이 필요합니다 (설정에서 허용)")
                    }
                }
            }
        default:
            selectedMicId = Self.micOffId
            deactivateAudioSessionForGemini()
            showToast("마이크 권한 거부됨 · 설정에서 허용해 주세요")
        }
    }

    func refreshAudioRoutes() {
        let audioSession = AVAudioSession.sharedInstance()
        var items: [AudioInputItem] = []

        if let ports = audioSession.availableInputs, !ports.isEmpty {
            items = ports.map { port in
                let isExt = port.portType == .usbAudio
                    || port.portType == .bluetoothHFP
                    || port.portType == .headsetMic
                    || port.portType == .lineIn
                return AudioInputItem(id: port.uid, name: port.portName, isExternal: isExt)
            }
        } else {
            // Passive discovery without activating AVAudioSession (.playAndRecord)
            let audioDiscovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            items = audioDiscovery.devices.map { dev in
                AudioInputItem(
                    id: dev.uniqueID,
                    name: dev.localizedName,
                    isExternal: dev.deviceType == .external
                )
            }
        }

        let outPort = audioSession.currentRoute.outputs.first
        let outName = outPort?.portName ?? "스피커"

        DispatchQueue.main.async {
            self.audioInputs = items
            self.currentOutputName = outName
            if self.selectedMicId != Self.micOffId && !items.contains(where: { $0.id == self.selectedMicId }) {
                self.selectedMicId = Self.micOffId
                self.deactivateAudioSessionForGemini()
            }
        }
    }

    private func deactivateAudioSessionForGemini() {
        stopAudioMonitor()
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.ambient, options: [.mixWithOthers])
            if hasActivatedAudioSession {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                hasActivatedAudioSession = false
            }
        } catch {
            hasActivatedAudioSession = false
        }
    }

    private func applySelectedMicrophone(id: String) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
            )
            try audioSession.setActive(true)
            hasActivatedAudioSession = true

            let desiredName = audioInputs.first(where: { $0.id == id })?.name
            let targetPort = audioSession.availableInputs?.first(where: { $0.uid == id })
                ?? audioSession.availableInputs?.first(where: { $0.portName == desiredName })

            if let port = targetPort {
                try audioSession.setPreferredInput(port)
                selectedMicId = port.uid
                startAudioMonitor()
                refreshAudioRoutes()
                showToast("마이크 모니터링: \(port.portName)")
            } else {
                selectedMicId = Self.micOffId
                deactivateAudioSessionForGemini()
                refreshAudioRoutes()
                showToast("선택한 마이크를 찾을 수 없습니다")
            }
        } catch {
            selectedMicId = Self.micOffId
            deactivateAudioSessionForGemini()
            showToast("마이크 연결 실패: \(error.localizedDescription)")
        }
    }

    private func startAudioMonitor() {
        stopAudioMonitor()
        let input = audioEngine.inputNode
        let mixer = audioEngine.mainMixerNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            showToast("마이크 오디오 포맷을 열 수 없습니다")
            return
        }

        audioEngine.connect(input, to: mixer, format: format)
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isMonitoringAudio = true
        } catch {
            isMonitoringAudio = false
            showToast("오디오 모니터링 시작 실패")
        }
    }

    private func stopAudioMonitor() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.disconnectNodeInput(audioEngine.mainMixerNode)
        audioEngine.reset()
        isMonitoringAudio = false
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
            self.refreshAudioRoutes()
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
            self.refreshAudioRoutes()
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
            guard let self = self else { return }
            self.refreshAudioRoutes()
            if self.isMonitoringAudio && self.selectedMicId != Self.micOffId && !self.audioEngine.isRunning {
                self.startAudioMonitor()
            }
        })

        observers.append(nc.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.isMonitoringAudio && self.selectedMicId != Self.micOffId {
                self.startAudioMonitor()
            }
        })

        observers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            UIApplication.shared.isIdleTimerDisabled = true
            self.refreshAudioRoutes()
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
            // Never allow AVCaptureSession to touch AVAudioSession (protects Gemini Live)
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
                self.refreshAudioRoutes()
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

                Menu {
                    Button {
                        controller.selectMicrophone(id: CameraController.micOffId)
                    } label: {
                        if controller.selectedMicId == CameraController.micOffId {
                            Label("마이크 끔 (Gemini Live 사용 시 필수)", systemImage: "checkmark")
                        } else {
                            Text("마이크 끔 (Gemini Live 사용 시 필수)")
                        }
                    }

                    if !controller.audioInputs.isEmpty {
                        Divider()
                        Section("단독 테스트용 모니터링 (켜면 Gemini 음성 중단됨)") {
                            ForEach(controller.audioInputs) { mic in
                                Button {
                                    controller.selectMicrophone(id: mic.id)
                                } label: {
                                    let prefix = mic.isExternal ? "[USB/외장] " : "[내장] "
                                    if mic.id == controller.selectedMicId {
                                        Label(prefix + mic.name, systemImage: "checkmark")
                                    } else {
                                        Text(prefix + mic.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    let activeMicName = controller.selectedMicId == CameraController.micOffId
                        ? "마이크 끔"
                        : (controller.audioInputs.first(where: { $0.id == controller.selectedMicId })?.name ?? "마이크")
                    HudChipLabel(
                        text: activeMicName,
                        systemImage: controller.selectedMicId == CameraController.micOffId ? "mic.slash" : "mic.fill",
                        active: controller.selectedMicId != CameraController.micOffId
                    )
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
    var active: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 130, alignment: .leading)
        }
        .foregroundColor(active ? Color(red: 0.85, green: 1.0, blue: 0.88) : .white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            active ? Color.green.opacity(0.32) : Color.white.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(active ? Color.green.opacity(0.7) : Color.white.opacity(0.18), lineWidth: 1)
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
