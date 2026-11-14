import AVFoundation
import SwiftUI
import UIKit

// All session configuration and blocking start/stop calls share a serial queue.
final class MovieCamera: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    let output = AVCaptureMovieFileOutput()
    private let work = DispatchQueue(label: "studio.camera")
    var didStart: (() -> Void)?
    var didFinish: ((Error?) -> Void)?

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            work.async {
                do {
                    try self.configure()
                    self.session.startRunning()
                    guard self.session.isRunning else { throw StudioError.message("Камера недоступна.") }
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
    }
    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let mic = AVCaptureDevice.default(for: .audio) else {
            throw StudioError.message("Нужны фронтальная камера и микрофон iPhone.")
        }
        for device in [camera, mic] {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw StudioError.message("Не удалось подключить \(device.localizedName).") }
            session.addInput(input)
        }
        guard session.canAddOutput(output) else { throw StudioError.message("Не удалось настроить запись видео.") }
        session.addOutput(output)
        if let link = output.connection(with: .video) {
            if link.isVideoOrientationSupported { link.videoOrientation = .portrait }
            if link.isVideoMirroringSupported {
                link.automaticallyAdjustsVideoMirroring = false
                link.isVideoMirrored = true
            }
        }
    }
    func start(_ url: URL) { work.async { self.output.startRecording(to: url, recordingDelegate: self) } }
    func stopRecording() { work.async { if self.output.isRecording { self.output.stopRecording() } } }
    func shutdown() { work.async { if self.session.isRunning { self.session.stopRunning() } } }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.didStart?() }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let successful = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
        DispatchQueue.main.async { self.didFinish?(successful ? nil : error) }
    }
}

final class LensView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var lens: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
struct LiveLens: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> LensView {
        let view = LensView()
        view.lens.session = session
        view.lens.videoGravity = .resizeAspectFill
        if let conn = view.lens.connection {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if conn.isVideoMirroringSupported { conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = true }
        }
        return view
    }
    func updateUIView(_ view: LensView, context: Context) {}
}
