import Foundation
import AVFoundation

struct AlignmentSuggestion {
    let milliseconds: Int
    let confidence: Double
}

enum ReferenceAnalysis {
    // A bounded excerpt keeps analysis independent of the full video duration.
    static func samples(_ source: URL, origin: Double, duration: Double = 18) async throws -> [Float] {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw StudioError.message("В записи нет звука.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track],audioSettings: [
            AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:8000, AVNumberOfChannelsKey:1,
            AVLinearPCMBitDepthKey:32, AVLinearPCMIsFloatKey:true, AVLinearPCMIsNonInterleaved:false
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: origin,preferredTimescale: 8000),
                                       duration: CMTime(seconds: duration,preferredTimescale: 8000))
        guard reader.startReading() else { throw reader.error ?? StudioError.message("Ошибка чтения записи.") }
        defer { reader.cancelReading() }
        var result = [Float](repeating: 0,count: Int(duration*8000))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block)/4
            let position = Int(((CMSampleBufferGetPresentationTimeStamp(sample).seconds-origin)*8000).rounded())
            var values = [Float](repeating: 0,count: count)
            let status = values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block,atOffset: 0,dataLength: count*4,destination: bytes.baseAddress!)
            }
            guard status == noErr else { throw StudioError.message("Ошибка PCM.") }
            for i in 0..<count where result.indices.contains(position+i) { result[position+i] = values[i] }
        }
        guard reader.status == .completed else { throw reader.error ?? StudioError.message("Чтение прервано.") }
        return result
    }
    private static func match(_ a: [Float],_ b: [Float],minimum: Int,maximum: Int,separation: Int) -> TRMatch {
        tr_match(a,Int32(a.count),b,Int32(b.count),Int32(minimum),Int32(maximum),Int32(separation))
    }
    static func locateBeat(_ guide: Guide, beat: Beat, folder: URL) async throws -> Double? {
        let duration = min(guide.duration,12)
        let original = try await samples(folder.appendingPathComponent(beat.file),origin: guide.beatStart,duration: duration)
        let recording = try await samples(folder.appendingPathComponent(guide.recording.file),origin: guide.recording.origin,duration: duration)
        // Decimate to 2 kHz for the initial match, then refine at 8 kHz.
        let a = stride(from: 0,to: original.count,by: 4).map { original[$0] }
        let b = stride(from: 0,to: recording.count,by: 4).map { recording[$0] }
        let rough = match(a,b,minimum: -1000,maximum: 4000,separation: 120)
        guard rough.score > 0.28, rough.margin > 0.04 else { return nil }
        let fine = match(original,recording,minimum: Int(rough.lag)*4-8,maximum: Int(rough.lag)*4+8,separation: 8)
        return Double(fine.lag)/8000
    }
    static func suggestion(_ guide: Guide,take: Take,folder: URL) async throws -> AlignmentSuggestion? {
        guard let delay = guide.beatDelay, guide.beatFile == take.beat.file,
              abs(guide.beatStart-take.beatStart) < 0.001 else { return nil }
        let duration = min(guide.duration,take.duration,18)
        let reference = try await samples(folder.appendingPathComponent(guide.recording.file),origin: guide.recording.origin,duration: duration)
        let clean = try await samples(folder.appendingPathComponent(take.video.file),origin: take.video.origin,duration: duration)
        let beat = try await samples(folder.appendingPathComponent(take.beat.file),origin: take.beatStart,duration: duration)
        var xy = 0.0, xx = 0.0
        let offset = Int((delay*8000).rounded())
        for i in reference.indices where beat.indices.contains(i-offset) {
            xy += Double(reference[i])*Double(beat[i-offset]); xx += Double(beat[i-offset])*Double(beat[i-offset])
        }
        let scale = Float(xy/max(1e-12,xx))
        var residual = reference
        for i in residual.indices where beat.indices.contains(i-offset) { residual[i] -= scale*beat[i-offset] }
        func envelope(_ input: [Float]) -> [Float] {
            var output = [Float]()
            var previous: Float = 0
            for start in stride(from: 0,to: input.count-80,by: 80) {
                var energy: Float = 0
                for i in start..<start+80 { let delta = input[i]-previous; previous = input[i]; energy += delta*delta }
                output.append(log1p(sqrt(energy/80)*100))
            }
            return output
        }
        let result = match(envelope(residual),envelope(clean),minimum: -300,maximum: 300,separation: 15)
        guard result.score > 0.58, result.margin > 0.12 else { return nil }
        return AlignmentSuggestion(milliseconds: Int(((Double(result.lag)/100+delay)*1000).rounded()),confidence: result.score)
    }
}


enum GridAnalysis {
    nonisolated static func read(_ beat: Beat, url: URL) async throws -> Beat {
        var updated = beat
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let step = max(1, Int((rate / 8000).rounded()))
        guard let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return beat }
        let limit = min(file.length, Int64(rate * 60))
        var mono = [Float]()
        while file.framePosition < limit {
            try Task.checkCancellation()
            let offset = file.framePosition
            try file.read(into: block, frameCount: AVAudioFrameCount(min(8192,limit-offset)))
            guard block.frameLength > 0, let channels = block.floatChannelData else { break }
            let count = Int(file.processingFormat.channelCount)
            for i in stride(from: (step - Int(offset % Int64(step))) % step, to: Int(block.frameLength), by: step) {
                var sample: Float = 0
                for ch in 0..<count { sample += channels[ch][i] }
                mono.append(sample/Float(count))
            }
        }
        let grid = tr_analyze(mono, Int32(mono.count), rate / Double(step))
        if grid.bpm > 0 { updated.bpm = grid.bpm; updated.anchor = grid.anchor }
        if grid.root >= 0 {
            let names = ["До","До♯","Ре","Ми♭","Ми","Фа","Фа♯","Соль","Ля♭","Ля","Си♭","Си"]
            updated.keyName = names[Int(grid.root)] + (grid.minor == 1 ? " минор" : " мажор")
        }
        updated.analyzed = true
        return updated
    }
}

