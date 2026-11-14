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

struct Editor: View {
    @Binding var song: Song
    let folder: URL
    @EnvironmentObject var routes: Routes
    @StateObject private var loopPlayer = LoopPlayer()
    @State private var section = Page.write
    @State private var looping = true
    @State private var importer = false
    @State private var sound = false
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
        .fileImporter(isPresented: $importer, allowedContentTypes: [.audio]) { result in
            switch result {
            case .failure(let e):
                if (e as NSError).code != NSUserCancelledError { error = e.localizedDescription }
            case .success(let url): Task { await importBeat(url) }
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
                if beat.duration > 1.01 {
                    LabeledContent("Начало фрагмента", value: String(format: "%.1f с", song.start))
                    Slider(value: $song.start, in: 0...max(0.01, beat.duration - 1), step: 0.1)
                        .accessibilityLabel("Начало фрагмента")
                }
                Stepper("Длина · \(Int(song.target)) с", value: $song.target, in: 5...90, step: 5)
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
            let take = Take(video: recording, beat: beat, beatStart: job.song.start, duration: seconds)
            song.takes.append(take); song.selected = take.id
        } else if let i = song.takes.firstIndex(where: { $0.id == job.song.selected }) {
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
        } catch { self.error = error.localizedDescription }
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
                if lane != .lead {
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
