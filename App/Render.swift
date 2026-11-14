import AVFoundation
import CoreImage
import Foundation

enum Product { case movie, stems, monitor(excluding: Lane) }

enum Render {
    static let rate = 44100.0
    static let files = FileManager.default

    static func make(_ product: Product, take: Take, folder: URL) async throws -> URL {
        let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let suffix: String
        switch product {
        case .movie: suffix = "mp4"
        case .stems: suffix = "zip"
        case .monitor: suffix = "wav"
        }
        let result = files.temporaryDirectory
            .appendingPathComponent("Take-\(UUID().uuidString.prefix(8)).\(suffix)")
        var complete = false
        defer { if !complete { try? files.removeItem(at: result) } }
        let frames = Int64((take.duration * rate).rounded(.down))
        guard frames > 0 else { throw StudioError.message("Слишком короткий дубль.") }
        var gains = [Float](), sends = [Float]()
        for lane in Lane.allCases {
            try Task.checkCancellation()
            let strip = take.strips[lane] ?? Strip(gain: 1)
            let wav = scratch.appendingPathComponent(lane.wav)
            guard tr_blank_wave(wav.path, frames) == 0 else {
                throw StudioError.message("Не удалось создать WAV. Проверь свободное место.")
            }
            var audible = !strip.muted
            if case .monitor(let exclude) = product, lane == exclude { audible = false }
            // Trackout is dry, pre-fader and includes muted takes. The lead stays
            // locked to the picture. Beat and backing offsets use the same timeline.
            if let source = take.source(lane) {
                try await decode(folder.appendingPathComponent(source.file), to: wav,
                                 origin: source.origin,
                                 shift: lane == .lead ? 0 : Double(strip.shiftMS) / 1000,
                                 frames: frames)
            }
            gains.append(audible ? Float(strip.gain) : 0)
            sends.append(Float(strip.room))
        }
        try Task.checkCancellation()
        switch product {
        case .stems:
            try await movie(take, folder: folder, audio: nil, frames: frames,
                            to: scratch.appendingPathComponent("00-video.mp4"))
            guard tr_pack(scratch.path, result.path) == 0 else {
                throw StudioError.message("Не удалось собрать архив Stems.")
            }
        case .monitor, .movie:
            let mix = scratch.appendingPathComponent("mix.wav")
            guard tr_mix(scratch.path, mix.path, frames, gains, sends) == 0 else {
                throw StudioError.message("Не удалось свести дорожки.")
            }
            if case .movie = product {
                try await movie(take, folder: folder, audio: mix, frames: frames, to: result)
            } else { try files.moveItem(at: mix, to: result) }
        }
        complete = true
        return result
    }

    // The reader returns timestamped PCM blocks. Place each one at its actual
    // presentation time, preserving initial silence, discontinuities and offsets.
    static func decode(_ src: URL, to wav: URL, origin: Double, shift: Double, frames: Int64) async throws {
        let asset = AVURLAsset(url: src)
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw StudioError.message("В исходнике \(src.lastPathComponent) нет звука.")
        }
        let range = try await audio.load(.timeRange)
        let zero = origin - shift
        let a = max(origin, zero, range.start.seconds)
        let span = Double(frames) / rate
        let b = min(origin + span, zero + span, range.end.seconds)
        if b <= a { return }
        let reader = try AVAssetReader(asset: asset)
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let out = AVAssetReaderAudioMixOutput(audioTracks: [audio], audioSettings: pcm)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw StudioError.message("Формат аудио недоступен.") }
        reader.add(out)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 44100),
                                       end: CMTime(seconds: b, preferredTimescale: 44100))
        guard reader.startReading() else { throw reader.error ?? StudioError.message("Ошибка чтения аудио.") }
        let handle = try FileHandle(forWritingTo: wav)
        defer { reader.cancelReading(); try? handle.close() }
        while let sample = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let buffer = CMSampleBufferGetDataBuffer(sample) else {
                    throw StudioError.message("Нет блока PCM в декодированном аудио.")
                }
                let first = Int64(((CMSampleBufferGetPresentationTimeStamp(sample).seconds - zero) * rate).rounded())
                let bounds = tr_window(first, Int64(CMBlockBufferGetDataLength(buffer) / 4), frames)
                guard bounds.count > 0 else { return }
                let size = Int(bounds.count) * 4
                var data = Data(count: size)
                let status = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                    CMBlockBufferCopyDataBytes(buffer, atOffset: Int(bounds.skip) * 4,
                                               dataLength: size, destination: bytes.baseAddress!)
                }
                guard status == noErr else { throw StudioError.message("Ошибка декодирования PCM.") }
                try handle.seek(toOffset: UInt64(44 + bounds.start * 4))
                try handle.write(contentsOf: data)
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? StudioError.message("Декодирование прервано.")
        }
    }

    static func movie(_ take: Take, folder: URL, audio: URL?, frames: Int64, to url: URL) async throws {
        let asset = AVURLAsset(url: folder.appendingPathComponent(take.video.file))
        let comp = AVMutableComposition()
        guard let source = try await asset.loadTracks(withMediaType: .video).first,
              let picture = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw StudioError.message("В дубле нет видео.") }
        let duration = CMTime(value: frames, timescale: 44100)
        let trim = CMTime(seconds: take.video.origin, preferredTimescale: 44100)
        try picture.insertTimeRange(CMTimeRange(start: trim, duration: duration), of: source, at: .zero)
        picture.preferredTransform = try await source.load(.preferredTransform)
        if let audio {
            let mix = AVURLAsset(url: audio)
            guard let src = try await mix.loadTracks(withMediaType: .audio).first,
                  let dest = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw StudioError.message("Не удалось добавить микс к видео.") }
            try dest.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: src, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw StudioError.message("Экспорт видео недоступен.")
        }
        if take.look != .natural {
            let look = take.look
            export.videoComposition = AVVideoComposition(asset: comp) { request in
                let input = request.sourceImage
                let output = look == .mono
                    ? input.applyingFilter("CIPhotoEffectMono")
                    : input.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.25])
                request.finish(with: output.cropped(to: input.extent), context: nil)
            }
        }
        export.outputURL = url
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { done.resume() }
        }
        guard export.status == .completed else {
            throw export.error ?? StudioError.message("Ошибка экспорта MP4.")
        }
    }
}
