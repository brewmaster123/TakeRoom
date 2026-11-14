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
                if let message = routes.error { Text(message).foregroundStyle(.red) }
            }
            .navigationTitle("Звук")
            .toolbar { Button("Готово") { dismiss() } }
            .task { do { try routes.activate() } catch { routes.error = error.localizedDescription } }
        }
    }
}
