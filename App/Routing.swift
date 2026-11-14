import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class Routes: ObservableObject {
    @Published var inputs = [AVAudioSessionPortDescription]()
    @Published var inputName = "—"
    @Published var outputName = "—"
    @Published var preference = UserDefaults.standard.string(forKey: "preferredMic") ?? ""
    @Published var headsetMic = UserDefaults.standard.bool(forKey: "enableHFP")
    @Published var error: String?
    private var observer: NSObjectProtocol?
    private let audio = AVAudioSession.sharedInstance()

    init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func activate() throws {
        var flags: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if headsetMic { flags.insert(.allowBluetooth) }
        if audio.category != .playAndRecord || audio.mode != .default || audio.categoryOptions != flags {
            try audio.setCategory(.playAndRecord, mode: .default, options: flags)
        }
        try audio.setActive(true)
        if let port = audio.availableInputs?.first(where: { $0.uid == preference }),
           audio.preferredInput?.uid != port.uid {
            try audio.setPreferredInput(port)
        }
        refresh()
    }
    func select(_ uid: String) {
        do {
            let port = audio.availableInputs?.first { $0.uid == uid }
            if !uid.isEmpty && port == nil { throw StudioError.message("Микрофон отключён.") }
            try audio.setPreferredInput(port)
            preference = uid
            UserDefaults.standard.set(uid, forKey: "preferredMic")
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        inputs = audio.availableInputs ?? []
        inputName = audio.currentRoute.inputs.map(\.portName).joined(separator: ", ")
        outputName = audio.currentRoute.outputs.map(\.portName).joined(separator: ", ")
    }
}

struct OutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .label
        view.activeTintColor = .systemGreen
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

struct SoundSettings: View {
    @EnvironmentObject var routes: Routes
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Микрофон") {
                    Picker("Предпочтительный вход", selection: Binding(get: { routes.preference }, set: routes.select)) {
                        Text("Автоматически").tag("")
                        if !routes.preference.isEmpty && !routes.inputs.contains(where: { $0.uid == routes.preference }) {
                            Text("Сохранённый вход отключён").tag(routes.preference)
                        }
                        ForEach(routes.inputs, id: \.uid) { port in Text(port.portName).tag(port.uid) }
                    }
                    Toggle("Разрешить микрофон Bluetooth-гарнитуры", isOn: $routes.headsetMic)
                        .onChange(of: routes.headsetMic) { _, value in
                            UserDefaults.standard.set(value, forKey: "enableHFP")
                            do { try routes.activate() } catch { routes.error = error.localizedDescription }
                        }
                    Text("Для микрофона по кабелю и беспроводных наушников начни с выключенной опции.").font(.footnote)
                }
                Section("Фактически подключено") {
                    LabeledContent("Запись", value: routes.inputName)
                    HStack { Text("Прослушивание"); Spacer(); Text(routes.outputName); OutputPicker().frame(width: 44, height: 44) }
                }
                LatencyTest()
                if let message = routes.error { Text(message).foregroundStyle(.red) }
            }
            .navigationTitle("Звук")
            .toolbar { Button("Готово") { dismiss() } }
            .task { do { try routes.activate() } catch { routes.error = error.localizedDescription } }
        }
    }
}

private struct LatencyTest: View {
    @EnvironmentObject var routes: Routes
    @State private var testing = false
    @State private var message = ""
    @State private var run: Task<Void, Never>?
    @State private var candidate: Int?
    @State private var testedRoute = ""

    var body: some View {
        Section("Тест задержки") {
            Text("Надень наушники. Слушай первые четыре щелчка, затем восемь раз скажи «та» в ритм.")
            Button(testing ? "Остановить тест" : "Проверить задержку") {
                if testing { run?.cancel() }
                else {
                    testing = true
                    candidate = nil
                    run = Task { await test() }
                }
            }
            if !message.isEmpty { Text(message) }
            if let candidate, testedRoute == routes.routeKey {
                Button("Применить для новых дублей · " + String(candidate) + " мс") {
                    UserDefaults.standard.set(candidate, forKey: testedRoute)
                    message = "Поправка сохранена."
                    self.candidate = nil
                }
            }
        }.onDisappear { run?.cancel() }
    }

    @MainActor private func test() async {
        defer { testing = false }
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw StudioError.message("Разреши доступ к микрофону.") }
            try Task.checkCancellation()
            try routes.activate()
            let key = routes.routeKey
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let rate = 24000.0
            let interval = 0.75
            let count = Int(rate * 12 * interval)
            let clickURL = scratch.appendingPathComponent("click.caf")
            let micURL = scratch.appendingPathComponent("voice.caf")
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let samples = buffer.floatChannelData?[0] else { throw StudioError.message("Не удалось создать метроном.") }
            buffer.frameLength = AVAudioFrameCount(count)
            for n in 0..<count {
                let phase = Double(n % Int(rate * interval)) / rate
                samples[n] = phase < 0.025 ? Float(0.45 * sin(phase * 7000) * exp(-phase * 180)) : 0
            }
            do {
                let out = try AVAudioFile(forWriting: clickURL, settings: format.settings)
                try out.write(from: buffer)
            }
            let player = try AVAudioPlayer(contentsOf: clickURL)
            let recorder = try AVAudioRecorder(url: micURL, settings: format.settings)
            defer { player.stop(); recorder.stop() }
            guard recorder.prepareToRecord(), player.prepareToPlay() else { throw StudioError.message("Не удалось подготовить звук.") }
            let begin = player.deviceCurrentTime + 0.35
            guard recorder.record(atTime: begin), player.play(atTime: begin) else { throw StudioError.message("Метроном или микрофон не запустился.") }
            message = "Слушай метроном…"
            try await Task.sleep(nanoseconds: 3_250_000_000)
            message = "Теперь «та» на каждый щелчок."
            try await Task.sleep(nanoseconds: 6_500_000_000)
            recorder.stop()
            guard routes.routeKey == key else { throw StudioError.message("Аудиоустройства изменились. Повтори тест.") }
            let value = try Self.analyze(micURL, interval: interval)
            testedRoute = key
            candidate = value
            message = "Предлагаемая поправка бита: " + String(value) + " мс."
        } catch { message = Task.isCancelled ? "Тест остановлен." : error.localizedDescription }
    }

    private static func analyze(_ url: URL, interval: Double) throws -> Int {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw StudioError.message("Пустая запись.") }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else { throw StudioError.message("Нет сигнала микрофона.") }
        let rate = file.processingFormat.sampleRate
        let hop = max(1, Int(rate / 200))
        var levels = [Double]()
        for start in stride(from: 0, to: Int(buffer.frameLength), by: hop) {
            let end = min(start + hop, Int(buffer.frameLength))
            var power = 0.0
            for i in start..<end { power += Double(samples[i]) * Double(samples[i]) }
            levels.append(sqrt(power / Double(end-start)))
        }
        let tick = Double(hop) / rate
        let baseline = Array(levels.prefix(Int(2.7 / tick))).sorted()
        guard !baseline.isEmpty else { throw StudioError.message("Пустая запись.") }
        let floorLevel = max(0.002, baseline[baseline.count * 99 / 100] * 2.3)
        var shifts = [Double]()
        for beat in 4..<12 {
            let expected = Double(beat) * interval
            let lo = max(1, Int((expected - 0.23) / tick))
            let hi = min(levels.count - 3, Int((expected + 0.48) / tick))
            guard hi > lo else { continue }
            let threshold = max(floorLevel, (levels[lo...hi].max() ?? 0) * 0.15)
            if let onset = (lo...hi).first(where: { levels[$0-1] < threshold && levels[$0] >= threshold && levels[$0+1] >= threshold && levels[$0+2] >= threshold }) {
                shifts.append(Double(onset) * tick - expected)
            }
        }
        shifts.sort()
        guard shifts.count >= 6 else { throw StudioError.message("Мало чётких слогов. Повтори тест ближе к микрофону.") }
        let median = shifts[shifts.count / 2]
        guard shifts.filter({ abs($0 - median) < 0.065 }).count >= 6 else { throw StudioError.message("Слоги сильно расходятся по времени. Повтори тест.") }
        return Int((median * 1000).rounded())
    }
}

extension Routes {
    var routeKey: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        return "BeatDelay:" + (route.inputs + route.outputs).map(\.uid).joined(separator: "|")
    }
}
