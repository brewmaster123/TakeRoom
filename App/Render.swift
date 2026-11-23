import AVFoundation
import CoreImage
import Foundation

enum Product { case movie, stems, audioMix, monitor(excluding: Lane) }

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
        case .audioMix, .monitor: suffix = "wav"
        }
        let result = files.temporaryDirectory
            .appendingPathComponent("Take-\(UUID().uuidString.prefix(8)).\(suffix)")
        var complete = false
        defer { if !complete { try? files.removeItem(at: result) } }
        let frames = Int64((take.duration * rate).rounded(.down))
        guard frames > 0 else { throw StudioError.message("Слишком короткий дубль.") }
        guard Lane.allCases.count == Int(TR_LANE_COUNT) else {
            throw StudioError.message("Не совпадает число дорожек в микшере.")
        }
        var effects = [TREffect]()
        for lane in Lane.allCases {
            try Task.checkCancellation()
            let strip = take.strips[lane] ?? lane.defaultStrip
            let wav = scratch.appendingPathComponent(lane.wav)
            guard tr_blank_wave(wav.path, frames) == 0 else {
                throw StudioError.message("Не удалось создать WAV. Проверь свободное место.")
            }
            var audible = !strip.muted
            if case .monitor(let exclude) = product, lane == exclude { audible = false }
            if let source = take.source(lane) {
                try await decode(folder.appendingPathComponent(source.file), to: wav,
                                 origin: source.origin,
                                 shift: Double(strip.shiftMS) / 1000,
                                 frames: frames)
            }
            let fx = strip.effects ?? VoiceFX()
            func amplitude(_ db: Double) -> Float { Float(pow(10, db / 20)) }
            effects.append(TREffect(gain: audible ? Float(strip.gain) : 0, room: Float(strip.room),
                                    compression: Float(fx.compression), low: amplitude(fx.low), mid: amplitude(fx.mid),
                                    high: amplitude(fx.high), drive: Float(fx.drive), blend: Float(fx.blend)))
        }
        try Task.checkCancellation()
        let exportStems: Bool
        if case .stems = product { exportStems = true } else { exportStems = false }
        let cuts = (take.cuts ?? []).sorted { $0.start < $1.start }.map {
            TRCut(start: Int64($0.start * rate), end: Int64($0.end * rate))
        }
        guard tr_produce(scratch.path, frames, effects, Float(take.duck ?? 0), Float(take.density ?? 0),
                         cuts, Int32(cuts.count), exportStems ? 1 : 0) == 0 else {
            throw StudioError.message("Не удалось обработать звук. Проверь свободное место.")
        }
        let mix = scratch.appendingPathComponent("Master.wav")
        switch product {
        case .stems:
            for lane in Lane.allCases {
                let dry = scratch.appendingPathComponent(lane.wav)
                try files.removeItem(at: dry)
                try files.moveItem(at: scratch.appendingPathComponent("processed-" + lane.wav), to: dry)
            }
            try await movie(take, folder: folder, audio: nil, frames: frames,
                            to: scratch.appendingPathComponent("00-video.mp4"))
            let extras = try stageExtraVideos(take, folder: folder, scratch: scratch)
            guard tr_pack_processed(scratch.path, result.path, extras) == 0 else {
                throw StudioError.message("Не удалось собрать архив Stems.")
            }
        case .audioMix, .monitor, .movie:
            if case .movie = product {
                try await movie(take, folder: folder, audio: mix, frames: frames, to: result)
            } else { try files.moveItem(at: mix, to: result) }
        }
        complete = true
        return result
    }

    private static func stageExtraVideos(_ take: Take, folder: URL, scratch: URL) throws -> UInt32 {
        var slots: UInt32 = 0
        for slot in Take.extraVideoSlots {
            guard let video = take.extraVideos?[slot], let relative = tr_extra_movie_path(Int32(slot)) else { continue }
            try Task.checkCancellation()
            let destination = scratch.appendingPathComponent(String(cString: relative))
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(at: destination, withDestinationURL: folder.appendingPathComponent(video.file))
            slots |= 1 << slot
        }
        return slots
    }

    static func effects(_ take: Take) -> [TREffect] {
        Lane.allCases.map { lane in
            let strip = take.strips[lane] ?? lane.defaultStrip
            let fx = strip.effects ?? VoiceFX()
            func db(_ value: Double) -> Float { Float(pow(10,value/20)) }
            return TREffect(gain: strip.muted ? 0 : Float(strip.gain), room: Float(strip.room),
                            compression: Float(fx.compression), low: db(fx.low), mid: db(fx.mid), high: db(fx.high),
                            drive: Float(fx.drive), blend: Float(fx.blend))
        }
    }
    static func cuts(_ take: Take) -> [TRCut] {
        (take.cuts ?? []).map { TRCut(start: Int64(max(0,$0.start)*rate),end: Int64(min(take.duration,$0.end)*rate)) }
            .filter { $0.end > $0.start }
    }
    static func previewSources(_ take: Take, folder: URL) async throws -> URL {
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory,withIntermediateDirectories: true)
        do {
            let frames = Int64(take.duration*rate)
            for lane in Lane.allCases {
                try Task.checkCancellation()
                let url = directory.appendingPathComponent(lane.wav)
                guard tr_blank_wave(url.path,frames) == 0 else { throw StudioError.message("Недостаточно места для предпросмотра.") }
                if let source = take.source(lane) {
                    try await decode(folder.appendingPathComponent(source.file),to: url,origin: source.origin,shift: 0,frames: frames)
                }
            }
            return directory
        } catch { try? files.removeItem(at: directory); throw error }
    }
    static func previewWaves(directory: URL) async throws -> [Lane:[Float]] {
        var waves = [Lane:[Float]]()
        for lane in Lane.allCases {
            let file = try AVAudioFile(forReading: directory.appendingPathComponent(lane.wav))
            guard let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat,frameCapacity: 8192) else { continue }
            var peaks = [Float](repeating: 0,count: 6000)
            while file.framePosition < file.length {
                try Task.checkCancellation()
                let offset = file.framePosition
                try file.read(into: block)
                guard block.frameLength > 0, let channel = block.floatChannelData?[0] else { break }
                for i in stride(from: 0,to: Int(block.frameLength),by: 8) {
                    let bin = min(peaks.count-1,Int((offset+Int64(i))*Int64(peaks.count)/max(1,file.length)))
                    peaks[bin] = max(peaks[bin],abs(channel[i]))
                }
            }
            waves[lane] = peaks
        }
        return waves
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
