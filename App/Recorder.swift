import AVFoundation
import SwiftUI
import UIKit

struct Pass: Identifiable {
    let id = UUID()
    let lane: Lane
    let song: Song
    let folder: URL
    var main: Bool { lane == .lead }
    var limit: Double { main ? song.length : song.current?.duration ?? 0 }
}

@MainActor
final class Recorder: ObservableObject {
    enum Phase: Equatable { case loading, ready, counting(Int), starting, live, saving, ended, failed }
    @Published var phase = Phase.loading
    @Published var message = ""
    @Published var seconds = 0.0
    @Published var level = 0.0
    let camera = MovieCamera()
    let pass: Pass
    private let file: URL
    private var monitor: AVAudioPlayer?
    private var mic: AVAudioRecorder?
    private var preparedMonitor: URL?
    private var timer: Timer?
    private var countdown: Task<Void, Never>?
    private var recordingStart = 0.0
    private var origin = 0.0
    private var active = true
    private var routeDelayMS = 0
    private var startedWith: [String] = []
    private var committed = false
    private var finish: ((Recording, Double) -> Void)?

    init(_ pass: Pass) {
        self.pass = pass
        file = pass.folder.appendingPathComponent(UUID().uuidString + (pass.main ? ".mov" : ".caf"))
    }
    func prepare(routes: Routes, finish: @escaping (Recording, Double) -> Void) async {
        self.finish = finish
        do {
            guard pass.limit >= 0.5 else { throw StudioError.message("Выбери более длинный фрагмент бита.") }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw StudioError.message("Разреши доступ к микрофону в настройках iPhone.")
            }
            if pass.main {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    throw StudioError.message("Разреши доступ к камере в настройках iPhone.")
                }
            }
            guard active, !Task.isCancelled else { return }
            try routes.activate()
            let url: URL
            if pass.main, let beat = pass.song.beat {
                try await camera.prepare()
                guard active, !Task.isCancelled else { camera.shutdown(); return }
                url = pass.folder.appendingPathComponent(beat.file)
                camera.didStart = { [weak self] in self?.beginPlayback() }
                camera.didFinish = { [weak self] error in
                    guard let self else { return }
                    Task { await self.complete(error) }
                }
            } else if let take = pass.song.current {
                url = try await Render.make(.monitor(excluding: pass.lane), take: take, folder: pass.folder)
                preparedMonitor = url
                guard active, !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false]
                let rec = try AVAudioRecorder(url: file, settings: settings)
                rec.isMeteringEnabled = true
                guard rec.prepareToRecord() else { throw StudioError.message("Не удалось подготовить микрофон.") }
                mic = rec
            } else { throw StudioError.message("Сначала выбери бит и запиши основной дубль.") }
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else { throw StudioError.message("Не удалось подготовить дорожки.") }
            player.currentTime = pass.main ? pass.song.start : 0
            player.volume = pass.main ? 0.65 : 1
            monitor = player
            routes.refresh()
            phase = .ready
            timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch { fail(error) }
    }
    func start() {
        guard phase == .ready else { return }
        phase = .counting(3)
        countdown = Task {
            for n in (1...3).reversed() {
                phase = .counting(n)
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            guard active else { return }
            phase = .starting
            startedWith = routeIDs()
            routeDelayMS = UserDefaults.standard.integer(forKey: "BeatDelay:" + startedWith.joined(separator: "|"))
            if pass.main { camera.start(file) }
            else if mic?.record() == true { beginPlayback() }
            else { fail(StudioError.message("Микрофон не начал запись.")) }
        }
    }
    private func beginPlayback() {
        guard active, phase == .starting, let monitor else {
            camera.stopRecording(); return
        }
        // Once capture is running, put song zero on its timeline. Both audio and
        // video are trimmed by the same amount; route latency is adjusted in Mix.
        let position = pass.main ? camera.output.recordedDuration.seconds : mic?.currentTime ?? 0
        origin = position.isFinite ? max(0, position) : 0
        guard monitor.play() else {
            fail(StudioError.message("Устройство не начало воспроизведение."))
            camera.stopRecording(); mic?.stop(); return
        }
        recordingStart = ProcessInfo.processInfo.systemUptime
        phase = .live
    }
    private func routeIDs() -> [String] {
        let route = AVAudioSession.sharedInstance().currentRoute
        return (route.inputs + route.outputs).map(\.uid)
    }
    func routeChanged() {
        if phase == .live, routeIDs() != startedWith { stop() }
    }
    func interrupted() {
        if phase == .live { stop() }
        else if case .counting = phase { countdown?.cancel(); phase = .ready }
        else if phase == .starting {
            fail(StudioError.message("Запись прервана. Открой новый дубль."))
            camera.stopRecording(); mic?.stop()
        }
    }
    private func tick() {
        if pass.main {
            let db = camera.output.connection(with: .audio)?.audioChannels.first?.averagePowerLevel ?? -160
            level = max(0, min(1, (Double(db) + 54) / 54))
        } else {
            mic?.updateMeters()
            level = max(0, min(1, (Double(mic?.averagePower(forChannel: 0) ?? -160) + 54) / 54))
        }
        guard phase == .live else { return }
        seconds = min(pass.limit, ProcessInfo.processInfo.systemUptime - recordingStart)
        if seconds >= pass.limit { stop() }
    }
    func stop() {
        guard phase == .live else { return }
        seconds = min(pass.limit, ProcessInfo.processInfo.systemUptime - recordingStart)
        phase = .saving
        monitor?.stop()
        if pass.main { camera.stopRecording() }
        else { mic?.stop(); Task { await complete(nil) } }
    }
    private func complete(_ error: Error?) async {
        guard active, phase == .saving || phase == .live || phase == .starting else { return }
        if phase == .live { seconds = min(pass.limit, ProcessInfo.processInfo.systemUptime - recordingStart) }
        phase = .saving
        monitor?.stop()
        do {
            if let error { throw error }
            let asset = AVURLAsset(url: file)
            let kind: AVMediaType = pass.main ? .video : .audio
            guard let track = try await asset.loadTracks(withMediaType: kind).first else {
                throw StudioError.message("В записи отсутствует нужная дорожка.")
            }
            if pass.main, try await asset.loadTracks(withMediaType: .audio).isEmpty {
                throw StudioError.message("В видео отсутствует звук микрофона.")
            }
            let range = try await track.load(.timeRange)
            let trim = max(origin, range.start.seconds)
            let length = min(seconds, range.end.seconds - trim, pass.limit)
            guard length >= 0.25 else { throw StudioError.message("Дубль слишком короткий.") }
            guard active else { return }
            committed = true
            phase = .ended
            finish?(Recording(file: file.lastPathComponent, routeDelayMS: routeDelayMS, origin: trim), length)
        } catch { fail(error) }
    }
    func close() {
        active = false
        timer?.invalidate(); countdown?.cancel()
        monitor?.stop(); mic?.stop()
        camera.stopRecording(); camera.shutdown()
        if !committed { try? FileManager.default.removeItem(at: file) }
        if let preparedMonitor { try? FileManager.default.removeItem(at: preparedMonitor) }
    }
    private func fail(_ error: Error) { message = error.localizedDescription; phase = .failed }
}

struct Prompt: View {
    let lyrics: String
    let seconds: Double
    let font: Double
    let speed: Double
    @State private var textHeight: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            Text(lyrics)
                .font(.system(size: CGFloat(font), weight: .semibold))
                .lineSpacing(4).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { size in
                    Color.clear.onAppear { textHeight = size.size.height }
                        .onChange(of: size.size.height) { _, new in textHeight = new }
                })
                .offset(y: -min(CGFloat(seconds * speed), max(0, textHeight - geo.size.height)))
        }
        .padding(12).frame(height: 180)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14)).clipped()
        .accessibilityLabel(lyrics)
    }
}

struct CaptureScreen: View {
    let pass: Pass
    let saved: (Recording, Double) -> Void
    @StateObject private var recorder: Recorder
    @EnvironmentObject var routes: Routes
    @Environment(\.dismiss) var dismiss
    init(pass: Pass, saved: @escaping (Recording, Double) -> Void) {
        self.pass = pass; self.saved = saved
        _recorder = StateObject(wrappedValue: Recorder(pass))
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if pass.main && recorder.phase != .loading {
                LiveLens(session: recorder.camera.session).ignoresSafeArea()
            }
            VStack(spacing: 12) {
                if !pass.song.lyrics.isEmpty {
                    Prompt(lyrics: pass.song.lyrics, seconds: recorder.seconds, font: pass.song.font, speed: pass.song.speed)
                        .padding(.top, pass.song.promptY)
                }
                Spacer()
                if case .counting(let n) = recorder.phase {
                    Text("\(n)").font(.system(size: 80, weight: .bold, design: .rounded))
                }
                VStack(spacing: 10) {
                    Text(pass.lane.title).font(.headline)
                    Text("Вход · \(routes.inputName)\nВыход · \(routes.outputName)")
                        .font(.caption).multilineTextAlignment(.center)
                    ProgressView(value: recorder.level).tint(.green).accessibilityLabel("Уровень микрофона")
                    switch recorder.phase {
                    case .loading: ProgressView("Подготовка…")
                    case .ready: Button("Начать запись") { recorder.start() }.buttonStyle(.borderedProminent)
                    case .live:
                        Text(String(format: "%.1f с", recorder.seconds)).monospacedDigit()
                        Button("Завершить дубль") { recorder.stop() }.buttonStyle(.borderedProminent).tint(.red)
                    case .saving, .starting: ProgressView()
                    case .failed: Text(recorder.message)
                    default: EmptyView()
                    }
                    if [.ready, .failed, .loading].contains(recorder.phase) { Button("Закрыть") { dismiss() } }
                }.padding().background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 20))
            }.padding()
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .task { await recorder.prepare(routes: routes) { file, duration in saved(file, duration); dismiss() } }
        .onDisappear { recorder.close(); UIApplication.shared.isIdleTimerDisabled = false }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in recorder.routeChanged() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                recorder.interrupted()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in recorder.interrupted() }
    }
}
