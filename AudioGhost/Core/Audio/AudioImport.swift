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
    var note: String            // "Imported, converted to mono, normalized"
}

/// Import pipeline (spec §4.1): copy out of the security scope, validate, downmix to mono,
/// peak-normalize to −1 dBFS, write a Float32 Linear PCM .caf into Documents/Audio/.
enum AudioImport {

    static let minDuration: Double = 0.5
    static let maxDuration: Double = 20 * 60
    static let targetPeak: Float = 0.891_25      // −1 dBFS

    /// - Parameter pickedURL: the security-scoped URL handed over by `.fileImporter`.
    static func importFile(from pickedURL: URL, into audioDirectory: URL) throws -> ImportedAudio {
        let temp = try copyOutOfSecurityScope(pickedURL)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = try readValidatedBuffer(at: temp)
        let channels = Int(source.format.channelCount)
        let sampleRate = source.format.sampleRate
        let duration = Double(source.frameLength) / sampleRate

        var mono = downmixToMono(source)
        let originalPeak = normalizePeak(&mono)
        let fileName = try writeCAF(mono, sampleRate: sampleRate, into: audioDirectory)

        var notes: [String] = []
        if channels > 1 { notes.append("converted to mono") }
        if originalPeak > 0, abs(originalPeak - targetPeak) > 0.01 { notes.append("normalized") }
        let note = notes.isEmpty ? "Imported" : "Imported, " + notes.joined(separator: ", ")

        Log.info("Imported audio: \(fileName) \(String(format: "%.1f s", duration)) @ \(Int(sampleRate)) Hz")
        return ImportedAudio(fileName: fileName, duration: duration, note: note)
    }

    // MARK: Steps

    /// Copies to a temp file immediately; scoped URLs are never retained.
    private static func copyOutOfSecurityScope(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "audio" : url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: temp)
        } catch {
            throw AudioImportError.unreadable(error.localizedDescription)
        }
        return temp
    }

    /// Opens the file, enforces the duration limits and reads it fully into memory.
    private static func readValidatedBuffer(at url: URL) throws -> AVAudioPCMBuffer {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? NSNumber, size.intValue > 0 else {
            throw AudioImportError.empty
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration > minDuration else { throw AudioImportError.tooShort(duration) }
            guard duration <= maxDuration else { throw AudioImportError.tooLong(duration) }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else {
                throw AudioImportError.unreadable("couldn't allocate a buffer")
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, buffer.floatChannelData != nil else { throw AudioImportError.empty }
            return buffer
        } catch let error as AudioImportError {
            throw error
        } catch {
            throw AudioImportError.unreadable(error.localizedDescription)
        }
    }

    /// Plain sample-wise mean across channels.
    private static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channels {
            let src = buffer.floatChannelData![c]        // checked in readValidatedBuffer
            for i in 0..<count { mono[i] += src[i] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for i in 0..<count { mono[i] *= scale }
        }
        return mono
    }

    /// Scales to −1 dBFS so per-ghost level trims mean the same thing across files.
    /// - Returns: the peak before scaling.
    private static func normalizePeak(_ samples: inout [Float]) -> Float {
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        if peak > 0 {
            let gain = targetPeak / peak
            for i in samples.indices { samples[i] *= gain }
        }
        return peak
    }

    /// Writes Linear PCM Float32 at the source sample rate. - Returns: the new file's name.
    private static func writeCAF(_ samples: [Float], sampleRate: Double, into directory: URL) throws -> String {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buffer.floatChannelData?[0] else {
            throw AudioImportError.writeFailed("unsupported output format")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: samples.count)
        }

        let fileName = "\(UUID().uuidString).caf"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent(fileName),
                                       settings: format.settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try file.write(from: buffer)
        } catch {
            throw AudioImportError.writeFailed(error.localizedDescription)
        }
        return fileName
    }
}
