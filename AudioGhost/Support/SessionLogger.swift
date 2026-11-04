import Foundation

/// One row per heartbeat tick, plus event rows with `note` set (spec §11.4).
struct LogRecord {
    var t: TimeInterval = 0
    var state: String = ""
    var rawLat: Double = 0
    var rawLon: Double = 0
    var rawAcc: Double = 0
    var smoothedE: Double = 0
    var smoothedN: Double = 0
    var fixAge: Double = 0
    var attYaw: Double = 0
    var yawOffset: Double = 0
    var trueYaw: Double = 0
    var course: Double = -1
    var courseErr: Double = .nan
    var calibQuality: String = ""
    var ghostDist: Double = 0
    var ghostBearing: Double = 0
    var clampActive: Bool = false
    var motionHz: Double = 0
    var note: String = ""
}

/// Ring buffer + CSV export. Every field CSV is also a replay fixture — this is the highest
/// leverage tool in the project (spec §11.2), so the schema and the reader must stay in step.
final class SessionLogger {

    static let header = "t,state,rawLat,rawLon,rawAcc,smoothedE,smoothedN,fixAge,attYaw,yawOffset,"
        + "trueYaw,course,courseErr,calibQuality,ghostDist,ghostBearing,clampActive,motionHz,note"

    /// ~30 min at 25 Hz.
    private let capacity: Int
    private var buffer: [LogRecord]
    private var writeIndex = 0
    private var filled = false
    private let lock = NSLock()
    private var startTime: TimeInterval = 0

    private(set) var isRecording = false

    init(capacity: Int = 45_000) {
        self.capacity = capacity
        buffer = []
        buffer.reserveCapacity(min(capacity, 4096))
    }

    func start() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        writeIndex = 0
        filled = false
        startTime = AppClock.now
        isRecording = true
        lock.unlock()
    }

    func stop() {
        lock.lock(); isRecording = false; lock.unlock()
    }

    func append(_ record: LogRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return }
        var r = record
        r.t = AppClock.now - startTime
        if buffer.count < capacity {
            buffer.append(r)
        } else {
            buffer[writeIndex] = r
            writeIndex = (writeIndex + 1) % capacity
            filled = true
        }
    }

    /// Event rows carry only the note plus whatever context the caller passes.
    func event(_ note: String, state: String = "", quality: String = "") {
        var r = LogRecord()
        r.state = state
        r.calibQuality = quality
        r.note = note
        append(r)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    /// Records in chronological order.
    func snapshot() -> [LogRecord] {
        lock.lock(); defer { lock.unlock() }
        guard filled else { return buffer }
        return Array(buffer[writeIndex...] + buffer[..<writeIndex])
    }

    func csv() -> String {
        var out = Self.header + "\n"
        for r in snapshot() {
            out += [
                fmt(r.t, 3), r.state,
                fmt(r.rawLat, 7), fmt(r.rawLon, 7), fmt(r.rawAcc, 1),
                fmt(r.smoothedE, 2), fmt(r.smoothedN, 2), fmt(r.fixAge, 2),
                fmt(r.attYaw.degrees, 2), fmt(r.yawOffset.degrees, 2), fmt(r.trueYaw.degrees, 2),
                fmt(r.course, 1), r.courseErr.isNaN ? "" : fmt(r.courseErr.degrees, 2),
                r.calibQuality,
                fmt(r.ghostDist, 2), fmt(r.ghostBearing.degrees, 2),
                r.clampActive ? "1" : "0", fmt(r.motionHz, 1),
                escape(r.note)
            ].joined(separator: ",") + "\n"
        }
        return out
    }

    /// Writes the CSV into Documents and returns its URL for the share sheet.
    func exportCSV(named name: String? = nil) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let fileName = name ?? "audioghost-\(formatter.string(from: Date())).csv"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        try csv().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fmt(_ v: Double, _ places: Int) -> String {
        guard v.isFinite else { return "" }
        return String(format: "%.\(places)f", v)
    }

    private func escape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
