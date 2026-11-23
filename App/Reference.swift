import SwiftUI
import AVFoundation

struct ReferenceAlignment: View {
    let guide: Guide
    let take: Take
    let folder: URL
    let apply: (Int,Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var referenceWave = [Float]()
    @State private var cleanWave = [Float]()
    @State private var referenceMark = 0.0
    @State private var cleanMark = 0.0
    @State private var beatDelay: Double?
    @State private var suggestion: AlignmentSuggestion?
    @State private var busy = true
    @State private var message: String?
    @State private var audio: AVAudioPlayer?
    @State private var rangeStart = 0.0
    @State private var width = 4.0
    init(guide: Guide,take: Take,folder: URL,apply: @escaping (Int,Double?) -> Void) {
        self.guide = guide
        self.take = take
        self.folder = folder
        self.apply = apply
    }
    private var duration: Double { min(guide.duration,take.duration) }
    private var span: Double { min(width,duration) }
    private var value: Int { Int(((cleanMark-referenceMark+(beatDelay ?? 0))*1000).rounded()) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Поиск совпадения") {
                    if busy { ProgressView("Анализ первой строки…") }
                    if let message { Text(message) }
                    if let suggestion {
                        Text("Предложенный сдвиг бита · \(suggestion.milliseconds) мс")
                        Button("Проверить предложенное положение") { apply(suggestion.milliseconds+(take.strips[.lead]?.shiftMS ?? 0),beatDelay); dismiss() }
                    }
                }
                if beatDelay != nil {
                    wordAlignment
                }
            }.navigationTitle("Опорная строка")
                .toolbar { Button("Закрыть") { dismiss() } }
        }
        .task { await analyze() }
        .onDisappear { audio?.stop() }
    }
    private var wordAlignment: some View {
        Section("Отметить одно и то же слово") {
            Text("Выбери начало одного слова на обеих волнах. Прослушивание начнётся с отмеченного места.")
            Slider(value: $rangeStart,in: 0...max(0.001,duration-span))
            Slider(value: $width,in: min(0.5,duration)...max(0.5,duration))
            Text("Опорная строка")
            marker(reference: true)
            Text("Основной дубль")
            marker(reference: false)
            Button("Послушать опорную строку") { listen(reference: true,at: referenceMark) }
            Button("Послушать основной дубль") { listen(reference: false,at: cleanMark) }
            Button("Применить сдвиг · \(value) мс") { apply(value+(take.strips[.lead]?.shiftMS ?? 0),beatDelay); dismiss() }.disabled(beatDelay == nil || busy)
        }
    }
    private func analyze() async {
        defer { busy = false }
        do {
            let ref = try await ReferenceAnalysis.samples(folder.appendingPathComponent(guide.recording.file),origin: guide.recording.origin,duration: duration)
            let main = try await ReferenceAnalysis.samples(folder.appendingPathComponent(take.video.file),origin: take.video.origin,duration: duration)
            referenceWave = peaks(ref); cleanWave = peaks(main)
            beatDelay = guide.beatDelay
            var measured = guide
            if beatDelay == nil {
                measured.beatDelay = try await ReferenceAnalysis.locateBeat(guide,beat: take.beat,folder: folder)
                beatDelay = measured.beatDelay
            }
            suggestion = try await ReferenceAnalysis.suggestion(measured,take: take,folder: folder)
            if beatDelay == nil {
                message = "Бит на опорной записи не распознан. Подгони дорожки на слух в секвенсоре."
            } else if suggestion == nil {
                message = "Отметь начало одного слова на обеих записях или подгони дорожки на слух в секвенсоре."
            }
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
    private func peaks(_ samples: [Float]) -> [Float] {
        stride(from: 0,to: samples.count,by: 80).map { i in samples[i..<min(samples.count,i+80)].map { abs($0) }.max() ?? 0 }
    }
    private func marker(reference: Bool) -> some View {
        GeometryReader { geometry in
            WaveShape(peaks: reference ? referenceWave : cleanWave,duration: duration,start: rangeStart,span: span,
                      position: reference ? referenceMark : cleanMark,color: reference ? .orange : .mint)
                .contentShape(Rectangle()).onTapGesture { point in
                    let time = min(duration,max(0,rangeStart+point.x/geometry.size.width*span))
                    if reference { referenceMark = time } else { cleanMark = time }
                    listen(reference: reference,at: time)
                }
        }.frame(height: 90)
    }
    private func listen(reference: Bool,at time: Double) {
        do {
            audio?.stop()
            let recording = reference ? guide.recording : take.video
            let player = try AVAudioPlayer(contentsOf: folder.appendingPathComponent(recording.file))
            player.currentTime = recording.origin+time
            audio = player
            player.play()
        } catch { message = error.localizedDescription }
    }
}
