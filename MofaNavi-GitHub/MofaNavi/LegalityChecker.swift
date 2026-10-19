import Foundation
import MapKit
import CoreLocation

struct Violation: Identifiable {
    let id = UUID()
    let reason: String
    let coordinate: CLLocationCoordinate2D
}

/// Ergebnis der Echtzeit-Prüfung: auf welcher Straße fährst du gerade?
struct LiveRoad: Equatable {
    let wayID: Int
    let title: String
    let speedLimit: Int?
    var allowed: Bool
    let reason: String?
    let isBridgeOrTunnel: Bool
}

// MARK: - Geometrie

enum Geo {
    /// Koordinate in Meter relativ zu einem Ursprung (gut genug für kurze Distanzen)
    private static func meters(_ a: CLLocationCoordinate2D, from o: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((a.longitude - o.longitude) * 111_320 * cos(o.latitude * .pi / 180),
         (a.latitude - o.latitude) * 110_540)
    }

    static func distance(_ p: CLLocationCoordinate2D,
                         toSegment a: CLLocationCoordinate2D,
                         _ b: CLLocationCoordinate2D) -> Double {
        let A = meters(a, from: p)
        let B = meters(b, from: p)
        let dx = B.x - A.x, dy = B.y - A.y
        let len2 = dx * dx + dy * dy
        var t = len2 == 0 ? 0 : (-A.x * dx - A.y * dy) / len2
        t = max(0, min(1, t))
        let cx = A.x + t * dx, cy = A.y + t * dy
        return (cx * cx + cy * cy).squareRoot()
    }

    static func distance(_ p: CLLocationCoordinate2D, toPath path: [CLLocationCoordinate2D]) -> Double {
        guard let first = path.first else { return .infinity }
        if path.count == 1 { return distance(p, toSegment: first, first) }
        var best = Double.infinity
        for i in 0..<(path.count - 1) {
            best = min(best, distance(p, toSegment: path[i], path[i + 1]))
        }
        return best
    }

    static func start(of step: MKRoute.Step) -> CLLocationCoordinate2D {
        let pl = step.polyline
        guard pl.pointCount > 0 else { return pl.coordinate }
        return pl.points()[0].coordinate
    }
}

// MARK: - Routen-Prüfung (vor der Fahrt)

enum LegalityChecker {
    // Zwei Overpass-Server: fällt einer aus oder ist überlastet, springt der zweite ein
    private static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!
    ]
    private static let tolerance = 7.0   // Meter Abstand zur Straße
    private static let minRun = 5        // 5 Punkte à 10 m = ca. 50 m, damit Brücken/Unterführungen nicht zählen

    private struct Response: Decodable { let elements: [Way] }
    private struct Way: Decodable {
        let id: Int
        let tags: [String: String]?
        let geometry: [Pt]?
    }
    private struct Pt: Decodable {
        let lat: Double
        let lon: Double
        var coord: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    }

    /// Merkt sich Abfrage-Ergebnisse, damit ähnliche Routen nicht doppelt geladen werden
    private actor WayCache {
        private var store: [String: [Way]] = [:]
        func get(_ key: String) -> [Way]? { store[key] }
        func set(_ key: String, _ value: [Way]) {
            if store.count > 80 { store.removeAll() }
            store[key] = value
        }
    }
    private static let cache = WayCache()

    /// Prüft die Route online gegen OpenStreetMap. Wirft einen Fehler, wenn kein Server erreichbar ist.
    static func check(route: MKRoute) async throws -> [Violation] {
        let dense = densify(coordinates(of: route), spacing: 10)
        guard dense.count > 1 else { return [] }

        let step = 12                                   // alle ca. 120 m ein Stützpunkt für die Abfrage
        let sampleIdx = Array(stride(from: 0, to: dense.count, by: step))
        var result: [Violation] = []
        var seen = Set<Int>()

        for group in sampleIdx.chunked(into: 50) {      // ca. 6 km pro Abfrage
            let start = group.first!
            let end = min(group.last! + step, dense.count - 1)
            var pts = group.map { dense[$0] }
            pts.append(dense[end])

            let ways = try await fetchForbiddenWays(along: pts)
            let slice = Array(dense[start...end])

            for w in ways where !seen.contains(w.id) {
                guard let geo = w.geometry?.map(\.coord), geo.count > 1 else { continue }
                if let hit = firstSustainedHit(slice, path: geo) {
                    seen.insert(w.id)
                    result.append(Violation(reason: describe(w.tags ?? [:]), coordinate: hit))
                }
            }
        }
        return result
    }

    /// Grobe Notlösung ohne Internet: Namen der Anweisungen prüfen
    static func heuristic(route: MKRoute) -> [Violation] {
        let pattern = "(?i)autobahn|schnellstra|kraftfahrstra|\\bA ?\\d{1,3}\\b"
        return route.steps
            .filter { $0.instructions.range(of: pattern, options: .regularExpression) != nil }
            .map { Violation(reason: $0.instructions, coordinate: Geo.start(of: $0)) }
    }

    // MARK: Overpass

    /// Schickt eine Abfrage an die Server, der Reihe nach, bis einer antwortet
    static func send(query: String, timeout: TimeInterval) async throws -> Data {
        var lastError: Error = URLError(.cannotConnectToHost)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        for url in endpoints {
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = timeout
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.setValue("MofaNavi/2.0", forHTTPHeaderField: "User-Agent")
                req.httpBody = "data=\(encoded)".data(using: .utf8)
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetchForbiddenWays(along pts: [CLLocationCoordinate2D]) async throws -> [Way] {
        let key = pts.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }.joined(separator: ";")
        if let hit = await cache.get(key) { return hit }

        let line = pts.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let query = """
        [out:json][timeout:25];
        way(around:20,\(line))["highway"]->.near;
        (
          way.near["highway"~"^(motorway|motorway_link)$"];
          way.near["motorroad"="yes"];
          way.near["moped"="no"];
          way.near["motor_vehicle"="no"];
          way.near["vehicle"="no"];
          way.near["access"="no"];
        );
        out tags geom;
        """
        let data = try await send(query: query, timeout: 25)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let ways = decoded.elements.filter { isForbidden($0.tags ?? [:]) }
        await cache.set(key, ways)
        return ways
    }

    /// Regeln für Mofa/Moped (Klasse AM): keine Autobahn, keine Kraftfahrstraße, keine für Kfz gesperrten Wege
    static func isForbidden(_ t: [String: String]) -> Bool {
        let allowed: Set<String> = ["yes", "designated", "permissive"]
        if let m = t["moped"] {
            if allowed.contains(m) { return false }
            if m == "no" { return true }
        }
        if t["highway"] == "motorway" || t["highway"] == "motorway_link" { return true }
        if t["motorroad"] == "yes" { return true }
        if let mv = t["motor_vehicle"], allowed.contains(mv) { return false }
        if t["motor_vehicle"] == "no" || t["vehicle"] == "no" || t["access"] == "no" { return true }
        return false
    }

    static func title(_ t: [String: String]) -> String {
        let label = [t["ref"], t["name"]].compactMap { $0 }.joined(separator: " ")
        return label.isEmpty ? "unbenannte Straße" : label
    }

    static func describe(_ t: [String: String]) -> String {
        let n = title(t)
        if t["highway"] == "motorway" || t["highway"] == "motorway_link" { return "Autobahn: \(n)" }
        if t["motorroad"] == "yes" { return "Kraftfahrstraße: \(n)" }
        return "Für Mopeds gesperrt: \(n)"
    }

    private static func firstSustainedHit(_ slice: [CLLocationCoordinate2D],
                                          path: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        var run = 0
        for (i, p) in slice.enumerated() {
            if Geo.distance(p, toPath: path) <= tolerance {
                run += 1
                if run >= minRun { return slice[i - minRun + 1] }
            } else {
                run = 0
            }
        }
        return nil
    }

    // MARK: Hilfsfunktionen

    static func coordinates(of route: MKRoute) -> [CLLocationCoordinate2D] {
        let n = route.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }

    private static func densify(_ c: [CLLocationCoordinate2D], spacing: Double) -> [CLLocationCoordinate2D] {
        guard var prev = c.first else { return [] }
        var out = [prev]
        for next in c.dropFirst() {
            let d = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
            let n = max(1, Int(d / spacing))
            for k in 1...n {
                let t = Double(k) / Double(n)
                out.append(CLLocationCoordinate2D(
                    latitude: prev.latitude + (next.latitude - prev.latitude) * t,
                    longitude: prev.longitude + (next.longitude - prev.longitude) * t))
            }
            prev = next
        }
        return out
    }
}

// MARK: - Echtzeit-Prüfung (während der Fahrt)

enum LiveRoadChecker {
    private struct Response: Decodable { let elements: [Element] }
    private struct Element: Decodable {
        let id: Int
        let tags: [String: String]?
        let geometry: [Pt]?
    }
    private struct Pt: Decodable {
        let lat: Double
        let lon: Double
    }

    /// Nur Straßen, die ein Moped überhaupt befahren könnte (keine Fuß- oder Radwege, damit GPS-Ungenauigkeit nicht stört)
    private static let driveable: Set<String> = [
        "motorway", "motorway_link", "trunk", "trunk_link",
        "primary", "primary_link", "secondary", "secondary_link",
        "tertiary", "tertiary_link", "unclassified", "residential",
        "living_street", "service", "road", "track"
    ]

    /// Findet die Straße unter deinem Standort (nächste befahrbare Straße im Umkreis von 25 m).
    static func currentRoad(at c: CLLocationCoordinate2D) async throws -> LiveRoad? {
        let pos = String(format: "%.6f,%.6f", c.latitude, c.longitude)
        let query = """
        [out:json][timeout:10];
        way(around:25,\(pos))["highway"];
        out tags geom;
        """
        let data = try await LegalityChecker.send(query: query, timeout: 10)
        let decoded = try JSONDecoder().decode(Response.self, from: data)

        var best: (element: Element, dist: Double)?
        for el in decoded.elements {
            guard let tags = el.tags, let hw = tags["highway"], driveable.contains(hw),
                  let geo = el.geometry, geo.count > 1 else { continue }
            let path = geo.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let d = Geo.distance(c, toPath: path)
            if best == nil || d < best!.dist { best = (el, d) }
        }
        guard let best else { return nil }

        let tags = best.element.tags ?? [:]
        let forbidden = LegalityChecker.isForbidden(tags)
        let structure = (tags["bridge"] ?? "no") != "no" || (tags["tunnel"] ?? "no") != "no"
        return LiveRoad(
            wayID: best.element.id,
            title: LegalityChecker.title(tags),
            speedLimit: speed(from: tags),
            allowed: !forbidden,
            reason: forbidden ? LegalityChecker.describe(tags) : nil,
            isBridgeOrTunnel: structure)
    }

    private static func speed(from tags: [String: String]) -> Int? {
        guard let raw = tags["maxspeed"] else { return nil }
        if let v = Int(raw) { return v }
        let l = raw.lowercased()
        if l.contains("urban") { return 50 }
        if l.contains("rural") { return 100 }
        if l.contains("zone30") { return 30 }
        if l.contains("living_street") { return 7 }
        if let n = Int(l.filter(\.isNumber)), n > 0, n < 200 { return n }
        return nil
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
