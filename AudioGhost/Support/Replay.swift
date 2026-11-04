import Foundation

/// Re-runs an exported field CSV through the whole pipeline (spec §11.2). Every field bug becomes
/// a desk-reproducible case; the CSV column order is `SessionLogger.header`.
final class ReplayLocationProvider: LocationProviding {

    struct Row {
        var t: Double
        var lat: Double
        var lon: Double
        var accuracy: Double
        var course: Double
    }

    private(set) var rows: [Row]

    private let queue: DispatchQueue
    private let pipeline: FixPipeline
    private var timer: DispatchSourceTimer?
    private var index = 0
    private var startTime: TimeInterval = 0

    init(rows: [Row], queue: DispatchQueue, pipeline: FixPipeline = FixPipeline()) {
        self.rows = rows
        self.queue = queue
        self.pipeline = pipeline
    }

    /// Parses a CSV exported by `SessionLogger`. Rows without a usable raw fix are skipped.
    convenience init?(csv: String, queue: DispatchQueue, pipeline: FixPipeline = FixPipeline()) {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        guard let headerLine = lines.first else { return nil }
        let columns = headerLine.split(separator: ",").map(String.init)
        guard let iT = columns.firstIndex(of: "t"),
              let iLat = columns.firstIndex(of: "rawLat"),
              let iLon = columns.firstIndex(of: "rawLon"),
              let iAcc = columns.firstIndex(of: "rawAcc") else { return nil }
        let iCourse = columns.firstIndex(of: "course")

        var parsed: [Row] = []
        for line in lines.dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count > max(iT, iLat, iLon, iAcc) else { continue }
            guard let t = Double(f[iT]), let lat = Double(f[iLat]), let lon = Double(f[iLon]),
                  let acc = Double(f[iAcc]), lat != 0 || lon != 0, acc > 0 else { continue }
            // One row per fix: consecutive ticks repeat the same raw fix, so de-duplicate.
            if let last = parsed.last, last.lat == lat, last.lon == lon { continue }
            let course = iCourse.flatMap { $0 < f.count ? Double(f[$0]) : nil } ?? -1
            parsed.append(Row(t: t, lat: lat, lon: lon, accuracy: acc, course: course))
        }
        guard !parsed.isEmpty else { return nil }
        self.init(rows: parsed, queue: queue, pipeline: pipeline)
    }

    func start() async throws {
        index = 0
        startTime = AppClock.now
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.1)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard index < rows.count else { stop(); return }
        let now = AppClock.now
        let elapsed = now - startTime

        while index < rows.count, rows[index].t <= elapsed {
            let row = rows[index]
            index += 1
            pipeline.ingest(RawFix(coordinate: Geo.Coordinate(latitude: row.lat, longitude: row.lon),
                                   horizontalAccuracy: row.accuracy,
                                   speed: 1.4,
                                   course: row.course,
                                   courseAccuracy: row.course >= 0 ? 10 : -1,
                                   timestamp: now),
                            now: now)
        }
    }
}
