import Foundation
import AVFAudio

enum AudioImportError: LocalizedError {
    case unreadable(String)
    case tooShort(Double)
    case tooLong(Double)
    case empty
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let m): return "That file couldn't be read (\(m)). DRM-protected files won't work."
        case .tooShort(let d): return String(format: "That file is only %.2f s long — use something longer than 0.5 s.", d)
        case .tooLong(let d): return String(format: "That file is %.0f minutes long; the limit is 20 minutes.", d / 60)
        case .empty: return "That file is empty."
        case .writeFailed(let m): return "Couldn't save the converted audio (\(m))."
        }
    }
}

struct ImportedAudio {
    var fileName: String        // relative to Documents/Audio/
    var duration: Double
    var note: String            // "Converted to mono, normalized"
    var sampleRate: Double
    var originalChannels: Int
}

/// Import pipeline (spec §4.1): copy out of the security scope, validate, downmix to mono,
/// peak-normalize to −1 dBFS, write a Float32 Linear PCM .caf into Documents/Audio/.
enum AudioImport {

    static let minDuration: Double = 0.5
    static let maxDuration: Double = 20 * 60
    static let targetPeak: Float = 0.891_25      // −1 dBFS

    /// - Parameter pickedURL: the security-scoped URL handed over by `.fileImporter`.
    static func importFile(from pickedURL: URL, into audioDirectory: URL) throws -> ImportedAudio {
        // 1. Copy out of the security scope immediately; never retain scoped URLs.
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "audio" : pickedURL.pathExtension)
        do {
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: pickedURL, to: temp)
        } catch {
            if scoped { pickedURL.stopAccessingSecurityScopedResource() }
            throw AudioImportError.unreadable(error.localizedDescription)
        }
        if scoped { pickedURL.stopAccessingSecurityScopedResource() }
        defer { try? FileManager.default.removeItem(at: temp) }

        let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw AudioImportError.empty }

        // 2. Open and validate.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: temp)
        } catch {
            throw AudioImportError.unreadable(error.localizedDescription)
        }
        let sampleRate = file.processingFormat.sampleRate
        let frames = file.length
        let duration = Double(frames) / sampleRate
        guard duration > minDuration else { throw AudioImportError.tooShort(duration) }
        guard duration <= maxDuration else { throw AudioImportError.tooLong(duration) }

        let channels = Int(file.processingFormat.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(frames)) else {
            throw AudioImportError.unreadable("couldn't allocate a buffer")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw AudioImportError.unreadable(error.localizedDescription)
        }
        guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else {
            throw AudioImportError.empty
        }

        // 3. Downmix to mono: plain sample-wise mean across channels.
        let count = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channels {
            let src = channelData[c]
            for i in 0..<count { mono[i] += src[i] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for i in 0..<count { mono[i] *= scale }
        }

        // 4. Peak-normalize to −1 dBFS so per-ghost level trims mean the same thing across files.
        var peak: Float = 0
        for v in mono { peak = max(peak, abs(v)) }
        if peak > 0 {
            let gain = targetPeak / peak
            for i in 0..<count { mono[i] *= gain }
        }

        // 5. Write Linear PCM Float32 .caf at the source sample rate.
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat,
                                               frameCapacity: AVAudioFrameCount(count)) else {
            throw AudioImportError.writeFailed("unsupported output format")
        }
        outBuffer.frameLength = AVAudioFrameCount(count)
        if let dst = outBuffer.floatChannelData?[0] {
            mono.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: count)
            }
        }

        let fileName = "\(UUID().uuidString).caf"
        let outURL = audioDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let outFile = try AVAudioFile(forWriting: outURL,
                                          settings: outFormat.settings,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false)
            try outFile.write(from: outBuffer)
        } catch {
            throw AudioImportError.writeFailed(error.localizedDescription)
        }

        var notes: [String] = []
        if channels > 1 { notes.append("converted to mono") }
        if peak > 0, abs(peak - targetPeak) > 0.01 { notes.append("normalized") }
        let note = notes.isEmpty ? "Imported" : "Imported, " + notes.joined(separator: ", ")

        Log.info("Imported audio: \(fileName) \(String(format: "%.1f s", duration)) @ \(Int(sampleRate)) Hz")
        return ImportedAudio(fileName: fileName, duration: duration, note: note,
                             sampleRate: sampleRate, originalChannels: channels)
    }
}
