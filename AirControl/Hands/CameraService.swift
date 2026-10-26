import AVFoundation
import AppKit

/// The Mac's camera → Vision hand pose, head pose and lips, entirely on-device.
/// Frames are delivered on the main queue.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFrame: ((VisionFrame) -> Void)?
    /// Called on the main queue when the camera starts or fails.
    var onStatus: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "aircontrol.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let analyzer = HandPoseAnalyzer()
    private var input: AVCaptureDeviceInput?
    private var configured = false

    /// Cameras the user can pick from in Settings.
    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// Built-in camera first: Continuity Camera can grab the default slot when an iPhone is nearby.
    static func preferredCamera(id: String?) -> AVCaptureDevice? {
        let all = availableCameras()
        if let id, let chosen = all.first(where: { $0.uniqueID == id }) { return chosen }
        return all.first { $0.deviceType == .builtInWideAngleCamera } ?? all.first
    }

    func start(cameraID: String?) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run(cameraID: cameraID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.run(cameraID: cameraID)
                } else {
                    DispatchQueue.main.async { self?.onStatus?("Camera permission off") }
                }
            }
        default:
            onStatus?("Camera permission off")
        }
    }

    func stop() {
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    /// Switches cameras without tearing the session down.
    func switchCamera(to id: String?) {
        queue.async { [weak self] in
            guard let self, self.configured else { return }
            self.session.beginConfiguration()
            if let old = self.input { self.session.removeInput(old) }
            self.attachCamera(id: id)
            self.session.commitConfiguration()
            self.applyMirroring()
        }
    }

    private func run(cameraID: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure(cameraID: cameraID) }
            if !self.session.isRunning { self.session.startRunning() }
            let ok = self.input != nil
            DispatchQueue.main.async { self.onStatus?(ok ? nil : "No camera found") }
        }
    }

    private func configure(cameraID: String?) {
        configured = true
        session.beginConfiguration()
        // 720p is plenty at desk distance and keeps Vision fast.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

        // Center Stage reframes on its own, which would move a still hand in the frame and
        // make the pointer drift. Keep the framing fixed.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        attachCamera(id: cameraID)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        applyMirroring()
    }

    private func attachCamera(id: String?) {
        input = nil
        guard let device = Self.preferredCamera(id: id),
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else { return }
        session.addInput(newInput)
        input = newInput
    }

    /// Mirror in the capture connection when the hardware supports it; otherwise Vision results
    /// are flipped in software. Either way, frames read like a mirror.
    private func applyMirroring() {
        if let c = output.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
            analyzer.flipHorizontally = false
        } else {
            analyzer.flipHorizontally = true
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = analyzer.analyze(buffer)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
    }
}
