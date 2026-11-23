import SwiftUI

enum Night {
    static let lime = Color(red: 0.78, green: 1, blue: 0.08)
    static let canvas = Color(red: 0.034, green: 0.036, blue: 0.043)
    static let panel = Color(red: 0.105, green: 0.109, blue: 0.122)

    static func time(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

extension View {
    func studioPanel(highlight: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return self.background(LinearGradient(colors: [Night.panel, Night.canvas],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
            .overlay(shape.strokeBorder(highlight ? Night.lime.opacity(0.60) : .white.opacity(0.13)))
    }
}

struct StudioAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline.bold())
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.black).background(Night.lime, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension Beat {
    var displayName: String {
        let parts = name.components(separatedBy: "\"")
        if parts.count >= 3, !parts[1].isEmpty { return parts[1] }
        return (name as NSString).deletingPathExtension
    }
    var musicalDetails: String {
        [bpm.map { String(format: "%g BPM", $0) }, keyName].compactMap { $0 }.joined(separator: " · ")
    }
}

// Beat imports get unique filenames and are immutable. Reuse the envelope across screens.
@MainActor
private final class WaveCache {
    static let shared = WaveCache()
    private final class Entry {
        let peaks: [Float]
        init(_ peaks: [Float]) { self.peaks = peaks }
    }
    private let values = NSCache<NSURL, Entry>()
    private init() { values.countLimit = 128 }

    func peaks(for url: URL) async throws -> [Float] {
        if let cached = values.object(forKey: url as NSURL) { return cached.peaks }
        let result = try await FragmentEditor.envelope(url)
        try Task.checkCancellation()
        values.setObject(Entry(result), forKey: url as NSURL)
        return result
    }
}

struct BeatWave: View {
    let beat: Beat
    let folder: URL
    var color = Night.lime
    var start = 0.0
    var length: Double? = nil
    var position: Double? = nil
    @State private var peaks = [Float]()

    var body: some View {
        WaveShape(peaks: peaks, duration: beat.duration, start: start,
                  span: max(0.001, length ?? beat.duration), position: position, color: color)
            .accessibilityHidden(true)
            .task(id: beat.file) {
                peaks = []
                let result = try? await WaveCache.shared.peaks(for: folder.appendingPathComponent(beat.file))
                if !Task.isCancelled { peaks = result ?? [] }
            }
    }
}

struct ProjectCard: View {
    let song: Song
    let folder: URL
    let featured: Bool

    var body: some View {
        Group {
            if featured {
                VStack(alignment: .leading, spacing: 14) {
                    details
                    wave.frame(height: 78)
                    HStack {
                        Text("Продолжить").font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }.padding(16)
            } else {
                HStack(spacing: 14) {
                    wave.frame(width: 76, height: 38)
                    Divider()
                    details
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption)
                }.padding(14)
            }
        }.foregroundStyle(.white).studioPanel(highlight: featured)
    }

    @ViewBuilder private var wave: some View {
        if let beat = song.beat {
            BeatWave(beat: beat, folder: folder, color: featured ? Night.lime : .gray)
        } else {
            Image(systemName: "music.note").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title).font(featured ? .title.bold() : .headline).lineLimit(2)
            if let beat = song.beat {
                Text([beat.displayName, beat.musicalDetails].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            } else { Text("Бит не выбран").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}
