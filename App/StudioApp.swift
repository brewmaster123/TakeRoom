import SwiftUI
import AVFoundation
import AVKit
import Photos
import UniformTypeIdentifiers

@main
struct StudioApp: App {
    @StateObject private var shelf = Shelf()
    @StateObject private var routes = Routes()
    var body: some Scene {
        WindowGroup { Projects().environmentObject(shelf).environmentObject(routes).tint(.mint).preferredColorScheme(.dark) }
    }
}

struct Projects: View {
    @EnvironmentObject var shelf: Shelf
    @State private var path = [UUID]()
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button { if let id = shelf.create() { path.append(id) } } label: {
                        Label("Новый проект", systemImage: "plus.circle.fill").font(.headline)
                    }
                }
                Section("Мои проекты") {
                    ForEach(shelf.songs) { song in
                        NavigationLink(value: song.id) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(song.title).font(.headline)
                                Text(song.beat?.name ?? "Выбрать бит").foregroundStyle(.secondary).font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("TakeRoom")
            .navigationDestination(for: UUID.self) { id in
                if let index = shelf.songs.firstIndex(where: { $0.id == id }) {
                    Editor(song: $shelf.songs[index], folder: shelf.folder(id))
                }
            }
        }
        .alert("Проекты", isPresented: Binding(get: { shelf.error != nil }, set: { if !$0 { shelf.error = nil } })) {
            Button("ОК") { shelf.error = nil }
        } message: { Text(shelf.error ?? "") }
    }
}

@MainActor
final class LoopPlayer: ObservableObject {
    @Published var playing = false
    @Published var position = 0.0
    private var player: AVAudioPlayer?
    private var tick: Timer?
    func start(_ url: URL, from start: Double, length: Double, loop: Bool) throws {
        stop()
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.currentTime = start
        guard audio.play() else { throw StudioError.message("Не удалось включить бит.") }
        player = audio; playing = true
        tick = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing else { return }
                self.position = max(0, audio.currentTime - start)
                if !audio.isPlaying || audio.currentTime >= start + length {
                    if loop { audio.currentTime = start; audio.play() }
                    else { self.stop() }
                }
            }
        }
    }
    func stop() { tick?.invalidate(); tick = nil; player?.stop(); player = nil; playing = false; position = 0 }
}

private enum Page: String, CaseIterable { case write = "Текст", record = "Запись", mix = "Микс" }
private enum Delivery: Equatable { case preview, shareMovie, photos, stems }
private struct OutputFile: Identifiable { let id = UUID(); let url: URL }

private struct BeatPicker: UIViewControllerRepresentable {
    let finish: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: (URL?) -> Void
        init(finish: @escaping (URL?) -> Void) { self.finish = finish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(nil)
        }
    }
}

struct Editor: View {
    @Binding var song: Song
    let folder: URL
    @EnvironmentObject var routes: Routes
    @StateObject private var loopPlayer = LoopPlayer()
    @State private var section = Page.write
    @State private var looping = true
    @State private var importer = false
    @State private var selectingFragment = false
    @State private var pickedBeat: URL?
    @State private var sound = false
    @State private var syncing = false
    @State private var pass: Pass?
    @State private var busy: String?
    @State private var error: String?
    @State private var info: String?
    @State private var preview: OutputFile?
    @State private var sharing: OutputFile?
    @State private var cache: (Take, URL)?
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел", selection: $section) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            Form {
                switch section {
                case .write: writingPanel
                case .record: recordPanel
                case .mix: mixPanel
                }
            }
        }
        .navigationTitle(song.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { loopPlayer.stop(); sound = true } label: { Image(systemName: "headphones") }
                    .accessibilityLabel("Настройки звука")
            }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { writing = false } }
        }
        .disabled(busy != nil)
        .navigationBarBackButtonHidden(busy != nil)
        .overlay {
            if let busy {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    ProgressView(busy).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .sheet(isPresented: $importer, onDismiss: {
            guard let url = pickedBeat else { return }
            pickedBeat = nil
            Task { await importBeat(url) }
        }) {
            BeatPicker { url in
                pickedBeat = url
                importer = false
            }
        }
        .sheet(isPresented: $sound) { SoundSettings() }
        .sheet(item: $sharing) { file in ShareFile(url: file.url) }
        .sheet(item: $preview) { file in MoviePreview(url: file.url) }
        .fullScreenCover(item: $pass) { job in
            CaptureScreen(pass: job) { media, seconds in accept(media, seconds: seconds, job: job) }
        }
        .alert(error == nil ? "TakeRoom" : "Не удалось выполнить", isPresented: Binding(
            get: { error != nil || info != nil }, set: { if !$0 { error = nil; info = nil } })) {
            Button("ОК") { error = nil; info = nil }
        } message: { Text(error ?? info ?? "") }
        .onChange(of: section) { _, _ in loopPlayer.stop(); writing = false }
        .onChange(of: song.start) { _, _ in loopPlayer.stop() }
        .onChange(of: song.target) { _, _ in loopPlayer.stop() }
        .onChange(of: looping) { _, _ in loopPlayer.stop() }
        .onDisappear { loopPlayer.stop() }
    }

    @ViewBuilder private var writingPanel: some View {
        Section("Проект") { TextField("Название", text: $song.title) }
        Section("Бит") {
            Button { loopPlayer.stop(); importer = true } label: {
                Label(song.beat?.name ?? "Загрузить из Файлов", systemImage: "waveform.badge.plus")
            }
            if let beat = song.beat {
                Button("Выбрать фрагмент на волне") { loopPlayer.stop(); selectingFragment = true }
                    .sheet(isPresented: $selectingFragment) {
                        FragmentEditor(beat: beat, url: folder.appendingPathComponent(beat.file),
                                       start: song.start, length: song.length) { start, length in
                            song.start = start
                            song.target = length
                        }
                    }
                Toggle("Повтор фрагмента", isOn: $looping)
                Button {
                    if loopPlayer.playing { loopPlayer.stop(); return }
                    do {
                        try routes.activate()
                        try loopPlayer.start(folder.appendingPathComponent(beat.file),
                                             from: song.start, length: song.length, loop: looping)
                    } catch { self.error = error.localizedDescription }
                } label: {
                    Label(loopPlayer.playing ? "Стоп · \(Int(loopPlayer.position)) с" : "Слушать · \(Int(song.length)) с",
                          systemImage: loopPlayer.playing ? "stop.fill" : "play.fill")
                }
            }
        }
        Section("Текст куплета") {
            TextEditor(text: $song.lyrics).font(.title3).frame(minHeight: 210).focused($writing)
                .accessibilityLabel("Текст для суфлёра")
        }
    }
    @ViewBuilder private var recordPanel: some View {
        Section("Суфлёр") {
            Stepper("Шрифт · \(Int(song.font)) пт", value: $song.font, in: 16...48, step: 1)
            Stepper("Прокрутка · \(Int(song.speed)) пт/с", value: $song.speed, in: 0...100, step: 2)
            Stepper("Отступ сверху · \(Int(song.promptY)) пт", value: $song.promptY, in: 0...120, step: 4)
        }
        Section("Селфи и основной голос") {
            Button { openPass(.lead) } label: { Label("Снять новый дубль", systemImage: "video.fill") }
                .disabled(song.beat == nil)
            if song.beat == nil { Text("Сначала добавь бит на вкладке «Текст».").font(.footnote) }
        }
        takePicker
        if let take = song.current {
            Section("Бэки выбранного дубля") {
                ForEach([Lane.back1, .back2]) { lane in
                    Button { openPass(lane) } label: {
                        Label((take.source(lane) == nil ? "Записать · " : "Перезаписать · ") + lane.title, systemImage: "mic.fill")
                    }
                }
            }
        }
    }
    @ViewBuilder private var takePicker: some View {
        if !song.takes.isEmpty {
            Section {
                Picker("Дубль", selection: $song.selected) {
                    ForEach(Array(song.takes.enumerated()), id: \.element.id) { entry in
                        Text("№ \(entry.offset + 1) · \(Int(entry.element.duration.rounded())) с")
                            .tag(Optional(entry.element.id))
                    }
                }
            }
        }
    }
    @ViewBuilder private var mixPanel: some View {
        takePicker
        if let index = song.takes.firstIndex(where: { $0.id == song.selected }) {
            Button("Совместить с битом") { syncing = true }
                .sheet(isPresented: $syncing) {
                    let id = song.takes[index].id
                    BeatSyncView(take: song.takes[index], folder: folder, savedShift: Binding(
                        get: { song.current?.strips[.beat]?.shiftMS ?? 0 },
                        set: { value in
                            if let i = song.takes.firstIndex(where: { $0.id == id }) {
                                song.takes[i].strips[.beat, default: Strip(gain: 0.65)].shiftMS = value
                            }
                        }), saveVoice: { value in
                            if let i = song.takes.firstIndex(where: { $0.id == id }) {
                                song.takes[i].strips[.lead, default: Strip(gain: 1)].shiftMS = value
                            }
                        })
                }
            ForEach(Lane.allCases) { lane in
                let settings = Binding<Strip>(get: { song.takes[index].strips[lane] ?? Strip(gain: 1) },
                                              set: { song.takes[index].strips[lane] = $0 })
                ChannelStrip(lane: lane, strip: settings, recorded: song.takes[index].source(lane) != nil)
            }
            Section("Изображение") {
                Picker("Фильтр", selection: $song.takes[index].look) {
                    ForEach(Look.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Результат") {
                Button("Посмотреть и послушать") { deliver(.preview) }
                Button("Сохранить видео в Фото") { deliver(.photos) }
                Button("Поделиться видео") { deliver(.shareMovie) }
                Button { deliver(.stems) } label: { Label("Stems · экспорт ZIP", systemImage: "archivebox") }
                Text("Видео без звука и четыре WAV от одного начала. Громкость и реверберацию можно выставить заново в редакторе.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else { Text("Запиши основной дубль, чтобы открыть микшер.") }
    }

    private func openPass(_ lane: Lane) {
        loopPlayer.stop(); writing = false
        pass = Pass(lane: lane, song: song, folder: folder)
    }
    private func accept(_ recording: Recording, seconds: Double, job: Pass) {
        if job.main, let beat = job.song.beat {
            var take = Take(video: recording, beat: beat, beatStart: job.song.start, duration: seconds)
            take.strips[.beat]?.shiftMS = recording.routeDelayMS ?? 0
            song.takes.append(take); song.selected = take.id
        } else if let i = song.takes.firstIndex(where: { $0.id == job.song.selected }) {
            song.takes[i].strips[job.lane]?.shiftMS = -(recording.routeDelayMS ?? 0)
            if job.lane == .back1 { song.takes[i].back1 = recording }
            if job.lane == .back2 { song.takes[i].back2 = recording }
        }
    }
    @MainActor private func importBeat(_ url: URL) async {
        busy = "Импорт бита…"
        defer { busy = nil }
        do {
            song.beat = try await Self.copyBeat(url, folder: folder)
            song.start = 0
            song.target = song.beat?.duration ?? 60
            selectingFragment = true
        } catch { self.error = "Не удалось импортировать «\(url.lastPathComponent)». \(error.localizedDescription)" }
    }
    nonisolated private static func copyBeat(_ source: URL, folder: URL) async throws -> Beat {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let dst = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: dst)
            let asset = AVURLAsset(url: dst)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration >= 1, !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw StudioError.message("Нужен доступный аудиофайл длиной от одной секунды.")
            }
            _ = try AVAudioPlayer(contentsOf: dst)
            return Beat(file: dst.lastPathComponent, name: source.lastPathComponent, duration: duration)
        } catch { try? FileManager.default.removeItem(at: dst); throw error }
    }

    private func deliver(_ kind: Delivery) {
        guard let take = song.current, busy == nil else { return }
        busy = kind == .stems ? "Сборка Stems… " : "Подготовка видео…"
        Task { @MainActor in
            defer { busy = nil }
            do {
                let url: URL
                if kind == .stems {
                    url = try await Render.make(.stems, take: take, folder: folder)
                } else if let cache, cache.0 == take, FileManager.default.fileExists(atPath: cache.1.path) {
                    url = cache.1
                } else {
                    url = try await Render.make(.movie, take: take, folder: folder)
                    if let old = cache { try? FileManager.default.removeItem(at: old.1) }
                    cache = (take, url)
                }
                switch kind {
                case .preview: preview = OutputFile(url: url)
                case .shareMovie, .stems: sharing = OutputFile(url: url)
                case .photos:
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard status == .authorized || status == .limited else {
                        throw StudioError.message("Разреши добавление в Фото или выбери «Поделиться видео».")
                    }
                    try await PHPhotoLibrary.shared().performChanges {
                        _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }
                    info = "Ролик сохранён в Фото."
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct BeatSyncView: View {
    let take: Take
    let folder: URL
    let saveVoice: (Int) -> Void
    @State private var adjustingVoice = false
    @State private var voice: Double
    @Binding var savedShift: Int
    @Environment(\.dismiss) private var dismiss
    @State private var shift: Double
    @State private var start = 0.0
    @State private var player = AVPlayer()
    @State private var problem: String?

    init(take: Take, folder: URL, savedShift: Binding<Int>, saveVoice: @escaping (Int) -> Void) {
        self.saveVoice = saveVoice
        _voice = State(initialValue: Double(take.strips[.lead]?.shiftMS ?? 0))
        self.take = take
        self.folder = folder
        _savedShift = savedShift
        _shift = State(initialValue: Double(savedShift.wrappedValue))
    }

    private func nudge(_ step: Double) {
        if adjustingVoice { voice = min(1000, max(-1000, voice + step)) }
        else { shift = min(1000, max(-1000, shift + step)) }
    }
    @State private var repeating = false
    private var span: Double { repeating ? min(4, take.duration) : take.duration }
    private var beginning: Double { repeating ? start : 0 }
    private var position: Double { max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                if let problem { Text(problem).foregroundStyle(.red) }
                Toggle("Повтор фразы · 4 секунды", isOn: $repeating)
                if take.duration > span {
                    Slider(value: $start, in: 0...(take.duration - span))
                        .accessibilityLabel("Начало повтора")
                    Text("Начало фрагмента · " + String(format: "%.1f с", start))
                }
                Picker("Двигать", selection: $adjustingVoice) {
                    Text("Бит").tag(false)
                    Text("Голос").tag(true)
                }.pickerStyle(.segmented)
                Slider(value: adjustingVoice ? $voice : $shift, in: -1000...1000, step: 5)
                    .accessibilityLabel(adjustingVoice ? "Сдвиг голоса" : "Сдвиг бита")
                HStack {
                    Button("Раньше") { nudge(-5) }
                    Spacer()
                    Button("Сброс") { if adjustingVoice { voice = 0 } else { shift = 0 } }
                    Spacer()
                    Button("Позже") { nudge(5) }
                }
                Button("Применить") { savedShift = Int(shift); saveVoice(Int(voice)); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Совместить с битом")
            .toolbar { Button("Закрыть") { dismiss() } }
        }
        .task(id: [beginning, shift, span, voice]) {
            do {
                try await Task.sleep(nanoseconds: 40_000_000)
                let composition = AVMutableComposition()
                let video = AVURLAsset(url: folder.appendingPathComponent(take.video.file))
                let beat = AVURLAsset(url: folder.appendingPathComponent(take.beat.file))
                func time(_ seconds: Double) -> CMTime {
                    CMTime(seconds: seconds, preferredTimescale: 44100)
                }
                composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: time(span)))
                var levels = [AVAudioMixInputParameters]()
                func insert(_ asset: AVAsset, type: AVMediaType, origin: Double,
                            offset: Double, lane: Lane) async throws {
                    guard let source = try await asset.loadTracks(withMediaType: type).first else {
                        throw StudioError.message("В файле нет нужной дорожки.")
                    }
                    let valid = try await source.load(.timeRange)
                    let zero = origin - offset
                    let first = max(origin, zero + beginning, valid.start.seconds)
                    let last = min(origin + take.duration, zero + beginning + span, valid.end.seconds)
                    guard last > first else { return }
                    guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw StudioError.message("Не удалось открыть дорожку.")
                    }
                    try track.insertTimeRange(CMTimeRange(start: time(first), duration: time(last - first)),
                                              of: source, at: time(max(0, first - zero - beginning)))
                    if type == .video {
                        track.preferredTransform = try await source.load(.preferredTransform)
                    } else {
                        let strip = take.strips[lane] ?? Strip(gain: 1)
                        let params = AVMutableAudioMixInputParameters(track: track)
                        params.setVolume(strip.muted ? 0 : Float(strip.gain), at: .zero)
                        levels.append(params)
                    }
                }
                try await insert(video, type: .video, origin: take.video.origin, offset: 0, lane: .lead)
                try await insert(video, type: .audio, origin: take.video.origin, offset: voice / 1000, lane: .lead)
                try await insert(beat, type: .audio, origin: take.beatStart, offset: shift / 1000, lane: .beat)
                for lane in [Lane.back1, .back2] {
                    if let source = take.source(lane) {
                        try await insert(AVURLAsset(url: folder.appendingPathComponent(source.file)), type: .audio,
                                         origin: source.origin, offset: Double(take.strips[lane]?.shiftMS ?? 0) / 1000, lane: lane)
                    }
                }
                try Task.checkCancellation()
                let resume = position.truncatingRemainder(dividingBy: span)
                let item = AVPlayerItem(asset: composition)
                let mix = AVMutableAudioMix()
                mix.inputParameters = levels
                item.audioMix = mix
                problem = nil
                player.replaceCurrentItem(with: item)
                await player.seek(to: time(resume), toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation()
                player.play()
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard repeating, let item = note.object as? AVPlayerItem, item === player.currentItem else { return }
            player.seek(to: .zero)
            player.play()
        }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }
}

private struct ChannelStrip: View {
    let lane: Lane
    @Binding var strip: Strip
    let recorded: Bool
    var body: some View {
        Section(lane.title) {
            if recorded {
                Toggle("Звук", isOn: Binding(get: { !strip.muted }, set: { strip.muted = !$0 }))
                LabeledContent("Громкость", value: "\(Int((strip.gain * 100).rounded())) %")
                Slider(value: $strip.gain, in: 0...1).accessibilityLabel("Громкость \(lane.title)")
                Group {
                    Stepper("Сдвиг · \(strip.shiftMS) мс", value: $strip.shiftMS, in: -1000...1000, step: 5)
                    Slider(value: Binding(get: { Double(strip.shiftMS) }, set: { strip.shiftMS = Int($0.rounded()) }),
                           in: -1000...1000, step: 5).accessibilityLabel("Сдвиг по времени")
                }
                if lane != .beat {
                    LabeledContent("Реверберация", value: "\(Int((strip.room * 100).rounded())) %")
                    Slider(value: $strip.room, in: 0...0.6).accessibilityLabel("Реверберация \(lane.title)")
                }
            } else { Text("Пока не записан").foregroundStyle(.secondary) }
        }
    }
}
private struct ShareFile: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            if url.pathExtension == "zip" { try? FileManager.default.removeItem(at: url) }
        }
        return sheet
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
private struct MoviePreview: View {
    @Environment(\.dismiss) var dismiss
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View {
        NavigationStack {
            VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() }
                .navigationTitle("Дубль").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Готово") { dismiss() } }
        }
    }
}

private struct FragmentEditor: View {
    let beat: Beat
    let url: URL
    let apply: (Double, Double) -> Void
    @Environment(\.dismiss) var dismiss
    @StateObject private var sound = LoopPlayer()
    @State private var left: Double
    @State private var right: Double
    @State private var cursor: Double
    @State private var peaks = [Float]()
    @State private var message: String?

    init(beat: Beat, url: URL, start: Double, length: Double, apply: @escaping (Double, Double) -> Void) {
        self.beat = beat
        self.url = url
        self.apply = apply
        _left = State(initialValue: start)
        _right = State(initialValue: min(beat.duration, start + length))
        _cursor = State(initialValue: start)
    }
    private func clock(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
    private func play(_ t: Double, until end: Double, repeatPart: Bool) {
        guard end > t else { return }
        do {
            cursor = t
            try sound.start(url, from: t, length: end - t, loop: repeatPart)
        } catch { message = error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(beat.name) {
                    GeometryReader { geo in
                        Canvas { context, size in
                            let width = size.width
                            let mid = size.height / 2
                            let l = width * left / beat.duration
                            let r = width * right / beat.duration
                            context.fill(Path(CGRect(x: l, y: 0, width: r-l, height: size.height)), with: .color(.mint.opacity(0.22)))
                            var path = Path()
                            for (i, peak) in peaks.enumerated() {
                                let x = width * CGFloat(i) / CGFloat(peaks.count)
                                let h = max(1, CGFloat(peak) * mid)
                                path.move(to: CGPoint(x: x, y: mid-h))
                                path.addLine(to: CGPoint(x: x, y: mid+h))
                            }
                            context.stroke(path, with: .color(.mint))
                            for t in [left, right, min(beat.duration, cursor + sound.position)] {
                                context.fill(Path(CGRect(x: width*t/beat.duration, y: 0, width: 2, height: size.height)), with: .color(.primary))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { point in
                            play(max(0, min(beat.duration, point.x / geo.size.width * beat.duration)), until: beat.duration, repeatPart: false)
                        }
                    }.frame(height: 92)
                    Text("Коснись волны, чтобы послушать с этого места.")
                    Text("Начало · " + clock(left))
                    Slider(value: Binding(get: { left }, set: { sound.stop(); left = min($0, right - 0.5) }), in: 0...beat.duration)
                    Text("Конец · " + clock(right))
                    Slider(value: Binding(get: { right }, set: { sound.stop(); right = max($0, left + 0.5) }), in: 0...beat.duration)
                    Button(sound.playing ? "Стоп" : "Слушать фрагмент по кругу") {
                        if sound.playing { sound.stop() } else { play(left, until: right, repeatPart: true) }
                    }
                    Button("Использовать фрагмент · " + clock(right-left)) { apply(left, right-left); dismiss() }
                    if let message { Text(message) }
                }
            }.navigationTitle("Фрагмент бита")
            .toolbar { Button("Закрыть") { dismiss() } }
        }.task(id: url) {
            do { peaks = try await Self.envelope(url) }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }.onDisappear { sound.stop() }
    }
    nonisolated private static func envelope(_ url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { throw StudioError.message("Не удалось прочитать волну.") }
        var result = [Float](repeating: 0, count: 720)
        let total = max(1, file.length)
        while file.framePosition < total {
            try Task.checkCancellation()
            let offset = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for i in stride(from: 0, to: Int(buffer.frameLength), by: 8) {
                let bin = min(719, Int((offset + Int64(i)) * 720 / total))
                result[bin] = max(result[bin], abs(channels[0][i]))
            }
        }
        return result
    }
}
