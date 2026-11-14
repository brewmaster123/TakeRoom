import Foundation
import SwiftUI

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum Lane: String, CaseIterable, Codable, Identifiable {
    case beat, lead, back1, back2
    var id: Self { self }
    var title: String {
        switch self {
        case .beat: return "Бит"
        case .lead: return "Основной голос"
        case .back1: return "Бэк 1"
        case .back2: return "Бэк 2"
        }
    }
    var wav: String {
        switch self {
        case .beat: return "01-beat.wav"
        case .lead: return "02-lead.wav"
        case .back1: return "03-back-1.wav"
        case .back2: return "04-back-2.wav"
        }
    }
}

enum Look: String, Codable, CaseIterable {
    case natural = "Оригинал", mono = "Чёрно-белый", warm = "Тёплый"
}

struct Strip: Codable, Equatable {
    var gain: Double
    var muted = false
    var shiftMS = 0
    var room = 0.0
}

struct Beat: Codable, Equatable {
    var file: String
    var name: String
    var duration: Double
}

struct Recording: Codable, Equatable {
    var file: String
    // Seconds inside the original file corresponding to zero on the song timeline.
    var routeDelayMS: Int? = nil
    var origin: Double
}

struct Take: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var video: Recording
    var beat: Beat
    var beatStart: Double
    var duration: Double
    var back1: Recording?
    var back2: Recording?
    var look = Look.natural
    var strips = [Lane.beat: Strip(gain: 0.65), .lead: Strip(gain: 1),
                  .back1: Strip(gain: 0.45), .back2: Strip(gain: 0.45)]

    func source(_ lane: Lane) -> Recording? {
        switch lane {
        case .beat: return Recording(file: beat.file, origin: beatStart)
        case .lead: return video
        case .back1: return back1
        case .back2: return back2
        }
    }
}

struct Song: Identifiable, Codable {
    var id = UUID()
    var title = "Новый проект"
    var lyrics = ""
    var beat: Beat?
    var start = 0.0
    var target = 60.0
    var font = 27.0
    var speed = 32.0
    var promptY = 16.0
    var takes = [Take]()
    var selected: UUID?
    var current: Take? { takes.first { $0.id == selected } }
    var length: Double { min(target, max(0, (beat?.duration ?? 0) - start)) }
}

@MainActor
final class Shelf: ObservableObject {
    @Published var songs = [Song]() { didSet { save() } }
    @Published var error: String?
    private var ready = false
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TakeRoom", isDirectory: true)
    init() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let index = root.appendingPathComponent("songs.json")
            if FileManager.default.fileExists(atPath: index.path) {
                songs = try JSONDecoder().decode([Song].self, from: Data(contentsOf: index))
            }
            ready = true
        } catch {
            self.error = "Не удалось открыть проекты. \(error.localizedDescription)"
        }
    }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func create() -> UUID? {
        guard ready else { error = "Хранилище проектов недоступно."; return nil }
        do {
            var song = Song()
            song.title = "Куплет \(songs.count + 1)"
            try FileManager.default.createDirectory(at: folder(song.id), withIntermediateDirectories: true)
            songs.insert(song, at: 0)
            return song.id
        } catch { self.error = error.localizedDescription; return nil }
    }
    private func save() {
        guard ready else { return }
        do {
            try JSONEncoder().encode(songs).write(to: root.appendingPathComponent("songs.json"), options: .atomic)
        } catch { self.error = "Не удалось сохранить изменения. \(error.localizedDescription)" }
    }
}
