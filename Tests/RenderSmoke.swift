// macOS CI exercises the same AVFoundation reader, composition and exporter as the app.
import AVFoundation
import Foundation

@main
enum RenderSmoke {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw StudioError.message(message) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        try fm.copyItem(at: fixture, to: work.appendingPathComponent("pulse.mov"))
        let source = Recording(file: "pulse.mov", origin: 0.20)
        let beat = Beat(file: "pulse.mov", name: "Pulse", duration: 2)
        var take = Take(video: source, beat: beat, beatStart: 0.20, duration: 1)
        take.back1 = source
        take.look = .mono
        take.strips[.beat]?.shiftMS = -100
        take.strips[.back1]?.shiftMS = 100
        take.strips[.back1]?.gain = 1
        let zip = try await Render.make(.stems, take: take, folder: work)
        defer { try? fm.removeItem(at: zip) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zip.path, "-d", work.path]
        try unzip.run(); unzip.waitUntilExit()
        try require(unzip.terminationStatus == 0, "ZIP could not be unpacked")
        let expected: [Lane:Double] = [.beat:0.30, .lead:0.40, .back1:0.50]
        for lane in Lane.allCases {
            let file = try AVAudioFile(forReading: work.appendingPathComponent(lane.wav))
            try require(file.length == 44100, "\(lane) frame count")
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100) else {
                throw StudioError.message("No PCM buffer")
            }
            try file.read(into: buffer)
            guard let data = buffer.floatChannelData else { throw StudioError.message("Expected float buffer") }
            let onset = (0..<Int(buffer.frameLength)).first { abs(data[0][$0]) > 0.05 }
            if let time = expected[lane] {
                guard let onset else { throw StudioError.message("Missing \(lane)") }
                try require(abs(Double(onset)/44100 - time) < 0.005, "\(lane) incorrect onset \(onset)")
            } else { try require(onset == nil, "Empty backing is not silent") }
        }
        for name in ["Master.wav","Acapella.wav"] {
            let wav = try AVAudioFile(forReading: work.appendingPathComponent(name))
            try require(wav.length == 44100,"Wrong duration in \(name)")
        }
        let json = try JSONEncoder().encode(take)
        var legacy = try JSONSerialization.jsonObject(with: json) as! [String:Any]
        for field in ["duck","density","cuts"] { legacy.removeValue(forKey: field) }
        var strips = legacy["strips"] as? [Any] ?? []
        // Enum-keyed dictionaries use an alternating key/value array in Codable.
        for i in strips.indices where i % 2 == 1 {
            if var value = strips[i] as? [String:Any] { value.removeValue(forKey: "effects"); strips[i] = value }
        }
        legacy["strips"] = strips
        let oldTake = try JSONDecoder().decode(Take.self,from: JSONSerialization.data(withJSONObject: legacy))
        try require(oldTake.video.file == take.video.file,"Legacy project did not decode")
        let oldSong: [String:Any] = ["id": UUID().uuidString,"title":"Old song","lyrics":"text",
                                     "start":0,"target":60,"font":27,"speed":32,"promptY":16,"takes":[legacy]]
        let decodedSong = try JSONDecoder().decode(Song.self,from: JSONSerialization.data(withJSONObject: oldSong))
        try require(decodedSong.guide == nil && decodedSong.takes.count == 1,"Old song migration failed")
        let silent = AVURLAsset(url: work.appendingPathComponent("00-video.mp4"))
        try require(try await silent.loadTracks(withMediaType: .audio).isEmpty, "Video contains audio")
        try require(try await silent.loadTracks(withMediaType: .video).count == 1, "No picture")
        let clipLength = try await silent.load(.duration).seconds
        try require(abs(clipLength - 1) < 0.05, "Video duration differs from stems")
        let movie = try await Render.make(.movie, take: take, folder: work)
        defer { try? fm.removeItem(at: movie) }
        let mixed = AVURLAsset(url: movie)
        try require(try await mixed.loadTracks(withMediaType: .audio).count == 1, "MP4 is missing mix")
        print("AVFoundation: MP4, muted video, aligned processed stems and empty backing passed")
    }
    static func main() async throws { try await run() }
}
