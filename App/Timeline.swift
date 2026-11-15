import SwiftUI
import AVFoundation
import AVKit

private final class LiveAudio {
    let handle: OpaquePointer
    init(directory: URL, frames: Int64) throws {
        guard let handle = tr_live_open(directory.path, frames) else {
            throw StudioError.message("Не удалось открыть звуковые дорожки.")
        }
        self.handle = handle
    }
    deinit { tr_live_close(handle) }
}

@MainActor
final class TimelinePlayer: ObservableObject {
    @Published var ready = false
    @Published var playing = false
    @Published var position = 0.0
    @Published var message: String?
    @Published var waves = [Lane: [Float]]()
    let video = AVPlayer()
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var audio: LiveAudio?
    private var directory: URL?
    private var ticker: Timer?
    private var active = true
    private var duration = 0.0
    private var repeating = false
    private var loopStart = 0.0
    private var loopEnd = 0.0

    func prepare(_ take: Take, folder: URL) async {
        do {
            duration = take.duration
            let directory = try await Render.previewSources(take, folder: folder)
            guard active, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            self.directory = directory
            let audio = try LiveAudio(directory: directory, frames: Int64(take.duration * Render.rate))
            self.audio = audio
            let format = AVAudioFormat(standardFormatWithSampleRate: Render.rate, channels: 2)!
            let node = AVAudioSourceNode(format: format) { _, _, count, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                guard buffers.count == 2,
                      let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                tr_live_render(audio.handle, left, right, Int32(count))
                return noErr
            }
            source = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
            let asset = AVURLAsset(url: folder.appendingPathComponent(take.video.file))
            let composition = AVMutableComposition()
            guard let original = try await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw StudioError.message("В дубле нет видео.")
            }
            try track.insertTimeRange(CMTimeRange(start: CMTime(seconds: take.video.origin, preferredTimescale: 44100),
                                                  duration: CMTime(seconds: take.duration, preferredTimescale: 44100)),
                                      of: original, at: .zero)
            track.preferredTransform = try await original.load(.preferredTransform)
            let item = AVPlayerItem(asset: composition)
            if take.look != .natural {
                let look = take.look
                item.videoComposition = AVVideoComposition(asset: composition) { request in
                    let image = request.sourceImage
                    let filtered = look == .mono ? image.applyingFilter("CIPhotoEffectMono")
                        : image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.25])
                    request.finish(with: filtered.cropped(to: image.extent), context: nil)
                }
            }
            try Task.checkCancellation()
            guard active else { return }
            video.replaceCurrentItem(with: item)
            video.isMuted = true
            update(take)
            waves = try await Render.previewWaves(directory: directory)
            guard active, !Task.isCancelled else { return }
            ready = true
            ticker = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch { if active, !Task.isCancelled { message = error.localizedDescription } }
    }

    func update(_ take: Take) {
        guard let audio else { return }
        let effects = Render.effects(take)
        let shifts = Lane.allCases.map { Int64((Double(take.strips[$0]?.shiftMS ?? 0) * Render.rate / 1000).rounded()) }
        let cuts = Render.cuts(take)
        tr_live_update(audio.handle, effects, shifts, Float(take.duck ?? 0), Float(take.density ?? 0), cuts, Int32(cuts.count))
    }
    func transport(to time: Double? = nil, play: Bool? = nil, loop: ClosedRange<Double>? = nil) {
        guard let audio, ready else { return }
        if let loop { repeating = true; loopStart = loop.lowerBound; loopEnd = loop.upperBound }
        let value = min(duration, max(0, time ?? position))
        let shouldPlay = play ?? playing
        do {
            if shouldPlay, !engine.isRunning { try engine.start() }
            tr_live_transport(audio.handle, Int64(value * Render.rate), shouldPlay ? 1 : 0,
                              repeating ? 1 : 0, Int64(loopStart * Render.rate), Int64(loopEnd * Render.rate))
            if !shouldPlay { engine.pause() }
            position = value
            playing = shouldPlay
            video.seek(to: CMTime(seconds: value, preferredTimescale: 44100), toleranceBefore: .zero, toleranceAfter: .zero)
            if shouldPlay { video.play() } else { video.pause() }
        } catch { message = error.localizedDescription }
    }
    func clearLoop() { repeating = false; transport() }
    private func tick() {
        guard let audio, playing else { return }
        position = Double(tr_live_position(audio.handle)) / Render.rate
        if position >= duration { transport(to: duration, play: false); return }
        let latency = AVAudioSession.sharedInstance().outputLatency
        let picture = max(0, position - latency)
        let actual = video.currentTime().seconds
        if actual.isFinite, abs(actual-picture) > 0.15 {
            video.seek(to: CMTime(seconds: picture, preferredTimescale: 44100), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    func close() {
        active = false
        ticker?.invalidate(); ticker = nil
        engine.stop()
        video.pause(); video.replaceCurrentItem(with: nil)
        if let source { engine.detach(source) }
        source = nil
        audio = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

struct TimelineEditor: View {
    let folder: URL
    let save: (Take) -> Void
    @State private var take: Take
    @StateObject private var player = TimelinePlayer()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var routes: Routes
    @State private var windowStart = 0.0
    @State private var windowLength = 8.0
    @State private var selected = Lane.back1
    @State private var repeatPhrase = false
    @State private var dragStart: Int?
    @State private var history = [[Lane: Strip]]()

    init(take: Take, folder: URL, save: @escaping (Take) -> Void) {
        self.folder = folder
        self.save = save
        _take = State(initialValue: take)
    }
    private var span: Double { min(windowLength, take.duration) }
    private var end: Double { min(take.duration, windowStart + span) }
    private var shift: Int { take.strips[selected]?.shiftMS ?? 0 }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    VideoPlayer(player: player.video).frame(height: 230).allowsHitTesting(false)
                    if let message = player.message { Text(message).foregroundStyle(.red) }
                    if !player.ready { ProgressView("Подготавливаю дорожки…") }
                    HStack {
                        Button(player.playing ? "Пауза" : "Слушать") {
                            player.transport(to: player.position >= take.duration ? 0 : nil, play: !player.playing)
                        }.buttonStyle(.borderedProminent)
                        Text(String(format: "%.2f / %.2f с", player.position,take.duration)).monospacedDigit()
                    }.disabled(!player.ready)
                    Slider(value: Binding(get: { player.position }, set: { player.transport(to: $0) }), in: 0...max(0.01,take.duration))
                        .accessibilityLabel("Позиция воспроизведения")
                    Toggle("Повтор выбранного участка", isOn: $repeatPhrase)
                        .onChange(of: repeatPhrase) { _, value in
                            if value { player.transport(to: windowStart, loop: windowStart...end) } else { player.clearLoop() }
                        }
                    Text("Участок · \(String(format: "%.1f–%.1f с",windowStart,end))")
                    Slider(value: $windowStart, in: 0...max(0.001,take.duration-span))
                        .accessibilityLabel("Начало видимого участка")
                    Slider(value: $windowLength, in: min(1,take.duration)...max(1,min(60,take.duration)))
                        .accessibilityLabel("Масштаб волны")
                    ForEach(Lane.allCases) { lane in waveRow(lane) }
                    Text("Выбрано · \(selected.title) · \(shift) мс")
                    HStack {
                        Button("Раньше · 5 мс") { move(-5) }
                        Button("Позже · 5 мс") { move(5) }
                        Button("Отменить") {
                            if let previous = history.popLast() { take.strips = previous }
                        }.disabled(history.isEmpty)
                    }.buttonStyle(.bordered)
                    if selected == .lead { Text("Сдвиг голоса влияет на совпадение с губами.").font(.footnote) }
                    ChannelStrip(lane: selected,strip: Binding(get: { take.strips[selected] ?? Strip(gain: 1) },
                                                               set: { take.strips[selected] = $0 }),recorded: take.source(selected) != nil)
                    MixTools(take: $take,folder: folder,beforeCompare: { player.transport(play: false) })
                    Button("Применить") { save(take); dismiss() }.buttonStyle(.borderedProminent)
                }.padding().disabled(!player.ready)
            }
            .navigationTitle("Дорожки")
            .toolbar { Button("Закрыть") { dismiss() } }
        }
        .task {
            do { try routes.activate(); await player.prepare(take, folder: folder) }
            catch { player.message = error.localizedDescription }
        }
        .onChange(of: take) { _, value in player.update(value) }
        .onChange(of: windowStart) { _, _ in refreshLoop() }
        .onChange(of: windowLength) { _, _ in
            windowStart = min(windowStart, max(0,take.duration-span)); refreshLoop()
        }
        .onDisappear { player.close() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in player.transport(play: false) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in player.transport(play: false) }
    }
    private func refreshLoop() {
        if repeatPhrase { player.transport(to: windowStart, loop: windowStart...end) }
    }
    private func move(_ delta: Int) {
        history.append(take.strips)
        take.strips[selected, default: Strip(gain: 1)].shiftMS = shift + delta
    }
    private func waveRow(_ lane: Lane) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(lane.title).font(.system(.subheadline, design: .rounded).bold())
            GeometryReader { geometry in
                WaveShape(peaks: player.waves[lane] ?? [], duration: take.duration,
                          start: windowStart, span: span, shift: Double(take.strips[lane]?.shiftMS ?? 0)/1000,
                          position: player.position, color: lane.color, bpm: take.beat.bpm,
                          anchor: (take.beat.anchor ?? 0)-take.beatStart+Double(take.strips[.beat]?.shiftMS ?? 0)/1000)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = lane }
                    .gesture(DragGesture(minimumDistance: 6).onChanged { value in
                        selected = lane
                        if dragStart == nil { history.append(take.strips); dragStart = take.strips[lane]?.shiftMS ?? 0 }
                        let delta = Int((value.translation.width/geometry.size.width*span*1000).rounded())
                        take.strips[lane, default: Strip(gain: 1)].shiftMS = min(Int(take.duration*1000),max(-Int(take.duration*1000),(dragStart ?? 0)+delta))
                    }.onEnded { _ in dragStart = nil })
            }.frame(height: 65)
        }.padding(8)
            .background(lane.color.opacity(selected == lane ? 0.25 : 0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == lane ? lane.color : Color.clear,lineWidth: 2))
    }
}

struct WaveShape: View {
    let peaks: [Float]
    let duration: Double
    var start = 0.0
    let span: Double
    var shift = 0.0
    var position: Double? = nil
    var color = Color.mint
    var bpm: Double? = nil
    var anchor = 0.0
    var body: some View {
        Canvas { context,size in
            guard duration > 0, span > 0 else { return }
            if let bpm, bpm > 0 {
                let period = 60/bpm
                let first = Int(floor((start-anchor)/period))
                let last = Int(ceil((start+span-anchor)/period))
                for beat in first...last {
                    let x = (anchor+Double(beat)*period-start)/span*size.width
                    guard x >= 0, x <= size.width else { continue }
                    let alpha = beat % 4 == 0 ? 0.35 : 0.15
                    context.fill(Path(CGRect(x: x,y: 0,width: 1,height: size.height)),with: .color(.white.opacity(alpha)))
                }
            }
            var path = Path()
            for i in 0..<max(1,Int(size.width)) {
                let t = start + Double(i)/size.width*span-shift
                let bin = Int(t/duration*Double(peaks.count))
                guard t >= 0, t <= duration, peaks.indices.contains(bin) else { continue }
                let height = max(1,CGFloat(peaks[bin])*size.height/2)
                path.move(to: CGPoint(x: CGFloat(i), y: size.height/2-height))
                path.addLine(to: CGPoint(x: CGFloat(i), y: size.height/2+height))
            }
            context.stroke(path,with: .color(color),lineWidth: 1)
            if let position, position >= start, position <= start+span {
                let x = (position-start)/span*size.width
                context.fill(Path(CGRect(x: x,y: 0,width: 2,height: size.height)),with: .color(.white))
            }
        }
    }
}

extension Lane {
    var color: Color {
        switch self { case .beat: return .yellow; case .lead: return .mint; case .back1: return .pink; case .back2: return .cyan }
    }
}
