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
    @State private var alignReference = false
    @State private var pendingAlignment = false
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
            HStack(spacing: 8) {
                ForEach(Page.allCases, id: \.self) { page in
                    Button { section = page } label: {
                        Text(page.rawValue).font(.system(.headline, design: .rounded).weight(.black))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(section == page ? Color.black : .white)
                            .background(section == page ? Color.yellow : Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black,lineWidth: 2))
                            .shadow(color: .black,radius: 0,x: 2,y: 3)
                    }.buttonStyle(.plain)
                }
            }.padding(10)
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
        .sheet(isPresented: $alignReference) {
            if let guide = song.guide, let take = song.current,
               guide.beatFile == take.beat.file, abs(guide.beatStart-take.beatStart) < 0.001 {
                ReferenceAlignment(guide: guide,take: take,folder: folder) { shift, beatDelay in
                    song.guide?.beatDelay = beatDelay
                    if let i = song.takes.firstIndex(where: { $0.id == take.id }) {
                        song.takes[i].strips[.beat,default: Strip(gain: 0.65)].shiftMS = shift
                    }
                }
            }
        }
        .sheet(isPresented: $sound) { SoundSettings() }
        .sheet(item: $sharing) { file in ShareFile(url: file.url) }
        .sheet(item: $preview) { file in MoviePreview(url: file.url) }
        .fullScreenCover(item: $pass, onDismiss: {
            if pendingAlignment { pendingAlignment = false; alignReference = true }
        }) { job in
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
                TextField("Тональность · например, Фа минор",text: Binding(get: { song.beat?.keyName ?? "" },set: { song.beat?.keyName = $0 }))
                    .task(id: beat.file) {
                        guard beat.analyzed != true,
                              let analyzed = try? await GridAnalysis.read(beat, url: folder.appendingPathComponent(beat.file)),
                              !Task.isCancelled, song.beat?.file == beat.file else { return }
                        if song.beat?.bpm == nil { song.beat?.bpm = analyzed.bpm }
                        if song.beat?.anchor == nil { song.beat?.anchor = analyzed.anchor }
                        if song.beat?.keyName == nil { song.beat?.keyName = analyzed.keyName }
                        song.beat?.analyzed = true
                    }
                Stepper(beat.bpm.map { String(format: "%.1f BPM", $0) } ?? "Задать темп",
                        value: Binding(get: { song.beat?.bpm ?? 100 }, set: { song.beat?.bpm = $0 }), in: 60...200, step: 1)
                if let bpm = beat.bpm {
                    HStack {
                        Button("×½") { song.beat?.bpm = max(60,bpm/2) }
                        Button("×2") { song.beat?.bpm = min(200,bpm*2) }
                    }.buttonStyle(.borderless)
                    Button("Здесь раз · начало фрагмента") { song.beat?.anchor = song.start }
                    Toggle("Метроном при записи", isOn: Binding(get: { song.metronome ?? false }, set: { song.metronome = $0 }))
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
        Section("Опорная строка") {
            Text("Включи вывод на динамик в настройках звука. Прочитай первую строку вместе с битом, затем верни наушники для основного дубля.")
            Button(song.guide == nil ? "Записать опорную строку" : "Перезаписать опорную строку") {
                loopPlayer.stop(); writing = false
                pass = Pass(lane: .lead,song: song,folder: folder,reference: true)
            }.disabled(song.beat == nil)
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
            if let guide = song.guide, guide.beatFile == song.takes[index].beat.file,
               abs(guide.beatStart-song.takes[index].beatStart) < 0.001 {
                Button("Выровнять по опорной строке") { alignReference = true }

            }
            Button("Дорожки · подгонка и предпросмотр") { syncing = true }
                .sheet(isPresented: $syncing) {
                    TimelineEditor(take: song.takes[index], folder: folder) { edited in
                        if let i = song.takes.firstIndex(where: { $0.id == edited.id }) { song.takes[i] = edited }
                    }
                }
            ForEach(Lane.allCases) { lane in
                let settings = Binding<Strip>(get: { song.takes[index].strips[lane] ?? Strip(gain: 1) },
                                              set: { song.takes[index].strips[lane] = $0 })
                ChannelStrip(lane: lane, strip: settings, recorded: song.takes[index].source(lane) != nil)
            }
            MixTools(take: $song.takes[index], folder: folder)
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
                Text("Видео, четыре обработанные дорожки, Master.wav и Acapella.wav с общим началом.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else { Text("Запиши основной дубль, чтобы открыть микшер.") }
    }

    private func openPass(_ lane: Lane) {
        loopPlayer.stop(); writing = false
        pass = Pass(lane: lane, song: song, folder: folder)
    }
    private func accept(_ recording: Recording, seconds: Double, job: Pass) {
        if job.reference, let beat = job.song.beat {
            song.guide = Guide(recording: recording,beatFile: beat.file,beatStart: job.song.start,duration: seconds)
        } else if job.main, let beat = job.song.beat {
            var take = Take(video: recording, beat: beat, beatStart: job.song.start, duration: seconds)
            take.strips[.beat]?.shiftMS = recording.routeDelayMS ?? 0
            song.takes.append(take); song.selected = take.id
            if let guide = song.guide, guide.beatFile == beat.file, abs(guide.beatStart-job.song.start) < 0.001 { pendingAlignment = true }
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
            song.guide = nil
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

struct ChannelStrip: View {
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
                    Stepper("Сдвиг · \(strip.shiftMS) мс", value: $strip.shiftMS, step: 5)
                    Slider(value: Binding(get: { Double(strip.shiftMS) }, set: { strip.shiftMS = Int($0.rounded()) }),
                           in: Double(min(-1000,strip.shiftMS))...Double(max(1000,strip.shiftMS)), step: 5).accessibilityLabel("Сдвиг по времени")
                }
                if lane != .beat {
                    VocalControls(settings: Binding(get: { strip.effects ?? VoiceFX() }, set: { strip.effects = $0 }))
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

struct FragmentEditor: View {
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
                        .overlay(alignment: .topLeading) {
                            fragmentHandle(start: true,width: geo.size.width)
                            fragmentHandle(start: false,width: geo.size.width)
                        }
                        .onTapGesture { point in
                            play(max(0, min(beat.duration, point.x / geo.size.width * beat.duration)), until: beat.duration, repeatPart: false)
                        }
                    }.frame(height: 92).coordinateSpace(name: "fragment-wave")
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
    private func fragmentHandle(start: Bool,width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(start ? Color.mint : Color.orange)
            .frame(width: 24,height: 92)
            .overlay(Image(systemName: "line.3.horizontal").rotationEffect(.degrees(90)).foregroundStyle(.black))
            .offset(x: max(0,min(width-24,width*(start ? left : right)/beat.duration-12)))
            .gesture(DragGesture(minimumDistance: 0,coordinateSpace: .named("fragment-wave")).onChanged { value in
                sound.stop()
                let time = max(0,min(beat.duration,value.location.x/width*beat.duration))
                if start { left = min(time,right-0.5) } else { right = max(time,left+0.5) }
            })
            .accessibilityLabel(start ? "Начало фрагмента" : "Конец фрагмента")
    }
    nonisolated static func envelope(_ url: URL) async throws -> [Float] {
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

private struct VocalControls: View {
    @Binding var settings: VoiceFX
    var body: some View {
        DisclosureGroup("Обработка голоса") {
            control("Компрессия", $settings.compression)
            control("Низ · дБ", $settings.low, -12...12)
            control("Середина · дБ", $settings.mid, -12...12)
            control("Верх · дБ", $settings.high, -12...12)
            control("Дисторшн · драйв", $settings.drive)
            control("Подмес дисторшна", $settings.blend)
        }
    }
    private func control(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double> = 0...1) -> some View {
        VStack(alignment: .leading) {
            Text(name)
            Slider(value: value, in: range)
        }
    }
}

struct MixTools: View {
    @Binding var take: Take
    let folder: URL
    var beforeCompare: () -> Void = {}
    @State private var compare = false
    @State private var restoreDensity = 0.4
    @State private var wave = [Float]()
    @State private var editing: UUID?
    @State private var from = 0.0
    @State private var length = 0.5
    init(take: Binding<Take>,folder: URL,beforeCompare: @escaping () -> Void = {}) {
        _take = take
        self.folder = folder
        self.beforeCompare = beforeCompare
    }
    var body: some View {
        Section("Общий микс") {
            Text("Бит тише под голосом")
            Slider(value: Binding(get: { take.duck ?? 0 }, set: { take.duck = $0 }), in: 0...1)
            Toggle("Мастер", isOn: Binding(get: { (take.density ?? 0) > 0 }, set: { enabled in
                if enabled { take.density = restoreDensity } else { restoreDensity = max(0.02,take.density ?? 0.4); take.density = 0 }
            }))
            Button("Сравнить с выравниванием громкости") { beforeCompare(); compare = true }
                .sheet(isPresented: $compare) { MasterCompare(take: take, folder: folder) }
            Text("Плотность мастера")
            Slider(value: Binding(get: { take.density ?? 0 }, set: { take.density = $0 }), in: 0...1)
        }
        Section("Ямы в бите") {
            GeometryReader { geo in
                Canvas { ctx,size in
                    let shift = Double(take.strips[.beat]?.shiftMS ?? 0)/1000
                    let center = size.height/2
                    var path = Path()
                    for k in 0..<320 {
                        let time = Double(k)/320 * take.duration - shift
                        let n = Int((take.beatStart + time)/take.beat.duration * Double(wave.count))
                        guard time >= 0, wave.indices.contains(n) else { continue }
                        let x = size.width * CGFloat(k)/320
                        let height = max(1,CGFloat(wave[n])*center)
                        path.move(to: CGPoint(x: x,y: center-height))
                        path.addLine(to: CGPoint(x: x,y: center+height))
                    }
                    ctx.stroke(path,with: .color(.mint))
                    for cut in (take.cuts ?? []) + [BeatCut(start: from,end: min(take.duration,from+length))] {
                        let rect = CGRect(x: cut.start/take.duration*size.width,y: 0,
                                          width: max(0,cut.end-cut.start)/take.duration*size.width,height: size.height)
                        ctx.fill(Path(rect),with: .color(.orange.opacity(0.28)))
                    }
                }.contentShape(Rectangle()).onTapGesture { point in
                    from = min(take.duration,max(0,point.x/geo.size.width*take.duration))
                }
            }.frame(height: 72).task(id: take.beat.file) {
                wave = (try? await FragmentEditor.envelope(folder.appendingPathComponent(take.beat.file))) ?? []
            }
            Text(String(format: "Начало %.2f с · длина %.2f с", from, min(length,max(0,take.duration-from))))
            Slider(value: $from, in: 0...max(0.01,take.duration))
            Slider(value: $length, in: 0.05...max(0.06,take.duration))
            if let bpm = take.beat.bpm, bpm > 0 {
                let period = 60 / bpm
                let offset = (take.beat.anchor ?? 0) - take.beatStart + Double(take.strips[.beat]?.shiftMS ?? 0)/1000
                Button("Привязать к доле") {
                    from = min(take.duration, max(0, offset + ((from-offset)/period).rounded()*period))
                    length = min(take.duration, period)
                }
                Button("Длина · 4 доли") { length = min(take.duration,4*period) }
            }
            Button(editing == nil ? "Добавить яму" : "Сохранить яму") {
                let end = min(take.duration, from + length)
                guard end > from else { return }
                var cuts = take.cuts ?? []
                cuts.removeAll { $0.id == editing }
                cuts.append(BeatCut(id: editing ?? UUID(),start: from, end: end))
                editing = nil
                take.cuts = cuts
            }
            ForEach(take.cuts ?? []) { cut in
                Button("Изменить границы") { editing = cut.id; from = cut.start; length = cut.end-cut.start }
                Button(String(format: "Убрать яму %.2f–%.2f с", cut.start, cut.end)) {
                    take.cuts?.removeAll { $0.id == cut.id }
                }
            }
        }
    }
}

private struct MasterCompare: View {
    let take: Take
    let folder: URL
    @State private var players = [AVAudioPlayer]()
    @State private var selected = 1
    @State private var message: String?
    @Environment(\.dismiss) var dismiss
    init(take: Take,folder: URL) {
        self.take = take
        self.folder = folder
    }
    var body: some View {
        VStack(spacing: 22) {
            Text("Сравнение мастера").font(.title2.bold())
            if players.count == 2 {
                Picker("Звучание", selection: $selected) {
                    Text("Без мастера").tag(0)
                    Text("С мастером").tag(1)
                }.pickerStyle(.segmented)
                    .onChange(of: selected) { old, new in
                        let position = players[old].currentTime
                        players[old].pause()
                        players[new].currentTime = position
                        players[new].play()
                    }
            } else if let message { Text(message) } else { ProgressView("Готовлю сравнение…") }
            Button("Закрыть") { dismiss() }
        }.padding()
        .task {
            do {
                var dry = take
                dry.density = 0
                var audio = [AVAudioPlayer]()
                var energy = [Double]()
                for version in [dry,take] {
                    let url = try await Render.make(.audioMix, take: version, folder: folder)
                    defer { try? FileManager.default.removeItem(at: url) }
                    try Task.checkCancellation()
                    energy.append(try await Self.rms(url))
                    let player = try AVAudioPlayer(data: Data(contentsOf: url))
                    player.numberOfLoops = -1
                    player.prepareToPlay()
                    audio.append(player)
                }
                try Task.checkCancellation()
                let target = energy.min() ?? 0
                for i in audio.indices { audio[i].volume = Float(min(1,target/max(0.000001,energy[i]))) }
                players = audio
                audio[selected].play()
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }.onDisappear { for player in players { player.stop() } }
    }
    nonisolated static func rms(_ url: URL) async throws -> Double {
        let file = try AVAudioFile(forReading: url)
        guard let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return 1 }
        var energy = 0.0
        var count = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: block)
            guard let channels = block.floatChannelData, block.frameLength > 0 else { break }
            for ch in 0..<Int(file.processingFormat.channelCount) {
                for i in stride(from: 0,to: Int(block.frameLength),by: 8) {
                    let x = Double(channels[ch][i]); energy += x*x; count += 1
                }
            }
        }
        return sqrt(energy/Double(max(1,count)))
    }
}
