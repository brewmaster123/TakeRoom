import SwiftUI
import AVFoundation

struct ReferenceAlignment: View {
    let guide: Guide
    let take: Take
    let folder: URL
    let apply: (Int,Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var referenceWave = [Float]()
    @State private var beatWave = [Float]()
    @State private var beatMark = 0.0
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
                    DisclosureGroup("Уточнить положение бита в опорной записи") {
                        Text("На верхней опорной волне отметь узнаваемый удар бита. На волне ниже отметь тот же удар оригинала.")
                        GeometryReader { geo in
                            WaveShape(peaks: beatWave,duration: duration,start: rangeStart,span: span,position: beatMark,color: .yellow)
                                .contentShape(Rectangle()).onTapGesture { point in
                                    beatMark = min(duration,max(0,rangeStart+point.x/geo.size.width*span))
                                }
                        }.frame(height: 80)
                        Button("Сопоставить этот удар") { beatDelay = referenceMark-beatMark }
                    }
                    if beatDelay == nil { Text("Для ручной привязки сначала сопоставь удар бита в разделе выше.") }
                    Button("Применить сдвиг · \(value) мс") { apply(value+(take.strips[.lead]?.shiftMS ?? 0),beatDelay); dismiss() }.disabled(beatDelay == nil || busy)
                }
            }.navigationTitle("Опорная строка")
                .toolbar { Button("Закрыть") { dismiss() } }
        }
        .task {
            defer { busy = false }
            do {
                let ref = try await ReferenceAnalysis.samples(folder.appendingPathComponent(guide.recording.file),origin: guide.recording.origin,duration: duration)
                let main = try await ReferenceAnalysis.samples(folder.appendingPathComponent(take.video.file),origin: take.video.origin,duration: duration)
                let instrumental = try await ReferenceAnalysis.samples(folder.appendingPathComponent(take.beat.file),origin: guide.beatStart,duration: duration)
                beatWave = peaks(instrumental)
                referenceWave = peaks(ref); cleanWave = peaks(main)
                beatDelay = guide.beatDelay
                var measured = guide
                if beatDelay == nil {
                    measured.beatDelay = try await ReferenceAnalysis.locateBeat(guide,beat: take.beat,folder: folder)
                    beatDelay = measured.beatDelay
                }
                suggestion = try await ReferenceAnalysis.suggestion(measured,take: take,folder: folder)
                if suggestion == nil { message = "Выбери начало одного слова на обеих записях для точной привязки." }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }.onDisappear { audio?.stop() }
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
