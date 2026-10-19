import SwiftUI
import MapKit
import CoreLocation
import AVFoundation
import UIKit

/// Gemeinsamer Zustand für iPhone-Oberfläche und CarPlay.
final class Navi: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Navi()

    // Suche und Route
    @Published var results: [MKMapItem] = []
    @Published var destination: MKMapItem?
    @Published var route: MKRoute?
    @Published var violations: [Violation] = []
    @Published var checkNote: String?
    @Published var error: String?
    @Published var isChecking = false

    // Führung
    @Published var isGuiding = false
    @Published var currentStepIndex = 0
    @Published var distanceToManeuver: Double = 0
    @Published var location: CLLocation?

    // Echtzeit-Prüfung
    @Published var liveCheckEnabled = false
    @Published var liveRoad: LiveRoad?
    @Published var liveOffline = false
    @Published var alertText: String?

    // Sprachausgabe (ein/aus, wird gespeichert)
    @Published var voiceEnabled = true {
        didSet {
            UserDefaults.standard.set(voiceEnabled, forKey: "voiceEnabled")
            if !voiceEnabled { synth.stopSpeaking(at: .immediate) }
        }
    }

    private(set) var routeCoords: [CLLocationCoordinate2D] = []

    // München und Umgebung (Suche bis 50 km um den Marienplatz)
    let center = CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755)
    let maxDistanceFromMunich: CLLocationDistance = 50_000
    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: 100_000, longitudinalMeters: 100_000)
    }

    // Durchschnittstempo Moped (ca. 40 km/h bei erlaubten 45 km/h)
    let avgSpeed: Double = 40.0 / 3.6

    private let locationManager = CLLocationManager()
    private let synth = AVSpeechSynthesizer()
    private var announcedNear = false
    private var lastReroute = Date.distantPast

    // Echtzeit-Prüfung intern
    private var liveQueryRunning = false
    private var lastLiveQuery = Date.distantPast
    private var lastLiveLocation: CLLocation?
    private var forbiddenStreak: [Int: Int] = [:]
    private var lastWarnedWay: Int?
    private var warnedViolations = Set<UUID>()

    override init() {
        super.init()
        voiceEnabled = UserDefaults.standard.object(forKey: "voiceEnabled") as? Bool ?? true
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
           modes.contains("location") {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
    }

    // MARK: Suche

    func searchItems(_ text: String) async -> [MKMapItem] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = text
        req.region = region
        guard let items = try? await MKLocalSearch(request: req).start().mapItems else { return [] }
        return items.filter { isNearMunich($0) }
    }

    func search(_ text: String) async {
        let items = await searchItems(text)
        await MainActor.run {
            results = items
            error = items.isEmpty ? "Nichts im Umkreis von 50 km um München gefunden." : nil
        }
    }

    /// Wandelt einen Vorschlag aus der Eingabe in ein echtes Ziel um
    func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let req = MKLocalSearch.Request(completion: completion)
        req.region = region
        guard let item = try? await MKLocalSearch(request: req).start().mapItems.first else {
            await MainActor.run { error = "Ziel nicht gefunden." }
            return nil
        }
        if !isNearMunich(item) {
            await MainActor.run { error = "Das Ziel liegt außerhalb von München und Umgebung (50 km)." }
            return nil
        }
        return item
    }

    private func isNearMunich(_ item: MKMapItem) -> Bool {
        let p = item.placemark.coordinate
        let c = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return CLLocation(latitude: p.latitude, longitude: p.longitude).distance(from: c) <= maxDistanceFromMunich
    }

    // MARK: Routing

    @discardableResult
    func calculate(to item: MKMapItem) async -> MKRoute? {
        await MainActor.run {
            stopGuidance()
            isChecking = true
            error = nil
            checkNote = nil
            results = []
            route = nil
            violations = []
            destination = item
        }

        // Alle Straßen sind erlaubt, auf denen ein Moped fahren darf (nicht nur Tempo-45-Straßen).
        // Wir holen Routen mit und ohne "Autobahn meiden", damit auch erlaubte Bundes- und
        // Landstraßen in Frage kommen, und prüfen jede Route selbst gegen OpenStreetMap.
        func makeRequest(avoidHighways: Bool) -> MKDirections.Request {
            let req = MKDirections.Request()
            req.source = MKMapItem.forCurrentLocation()
            req.destination = item
            req.transportType = .automobile
            req.requestsAlternateRoutes = true
            if avoidHighways { req.highwayPreference = .avoid }
            return req
        }

        do {
            let anyRoutes = (try? await MKDirections(request: makeRequest(avoidHighways: false)).calculate().routes) ?? []
            let avoidRoutes = (try? await MKDirections(request: makeRequest(avoidHighways: true)).calculate().routes) ?? []

            // Doppelte Routen entfernen, kürzeste zuerst, höchstens 6 prüfen
            var unique: [MKRoute] = []
            for r in anyRoutes + avoidRoutes {
                let duplicate = unique.contains {
                    abs($0.distance - r.distance) < 30 && abs($0.expectedTravelTime - r.expectedTravelTime) < 30
                }
                if !duplicate { unique.append(r) }
            }
            let routes = Array(unique.sorted { $0.distance < $1.distance }.prefix(6))
            guard !routes.isEmpty else { throw URLError(.resourceUnavailable) }

            // Routen der Reihe nach prüfen, die erste ohne Verstoß gewinnt
            var checked: [(MKRoute, [Violation])] = []
            var offline = false
            for r in routes {
                do {
                    let v = try await LegalityChecker.check(route: r)
                    checked.append((r, v))
                    if v.isEmpty { break }
                } catch {
                    offline = true
                    break
                }
            }

            var note: String?
            let pick: (MKRoute, [Violation])
            if offline {
                pick = (routes[0], LegalityChecker.heuristic(route: routes[0]))
                note = "Online-Prüfung nicht möglich, nur grobe Prüfung der Straßennamen. Bitte Route selbst kontrollieren."
            } else {
                pick = checked.first(where: { $0.1.isEmpty }) ?? checked[0]
                if !pick.1.isEmpty {
                    note = "Keine komplett legale Route gefunden. Die rot markierten Stellen musst du umfahren."
                }
            }

            await MainActor.run {
                route = pick.0
                routeCoords = LegalityChecker.coordinates(of: pick.0)
                violations = pick.1
                checkNote = note
                isChecking = false
            }
            return pick.0
        } catch {
            await MainActor.run {
                self.error = "Keine Route gefunden."
                self.isChecking = false
            }
            return nil
        }
    }

    func clearRoute() {
        stopGuidance()
        route = nil
        destination = nil
        violations = []
        checkNote = nil
        error = nil
        results = []
        routeCoords = []
    }

    func minutes(for meters: Double) -> Int {
        Int((meters / avgSpeed / 60).rounded())
    }

    var remainingMeters: Double {
        guard let r = route, currentStepIndex < r.steps.count else { return 0 }
        return distanceToManeuver + r.steps[currentStepIndex...].reduce(0) { $0 + $1.distance }
    }

    // MARK: Tempo-Anzeige

    /// Aktuelle Geschwindigkeit in km/h (nil, solange das GPS keine Fahrt meldet)
    var speedKmh: Int? {
        guard let s = location?.speed, s >= 0 else { return nil }
        return Int((s * 3.6).rounded())
    }

    /// Erlaubtes Tempo für dich: Limit der Straße, aber nie mehr als 45
    var effectiveLimit: Int { min(liveRoad?.speedLimit ?? 45, 45) }

    var isTooFast: Bool {
        guard let v = speedKmh else { return false }
        return v > effectiveLimit + 2   // 2 km/h Toleranz wegen GPS
    }

    // MARK: Führung

    var currentInstruction: String? {
        guard let r = route, currentStepIndex < r.steps.count else { return nil }
        return r.steps[currentStepIndex].instructions
    }

    func startGuidance() {
        guard let route else { return }
        currentStepIndex = route.steps.firstIndex(where: { !$0.instructions.isEmpty }) ?? 0
        announcedNear = false
        warnedViolations.removeAll()
        forbiddenStreak.removeAll()
        lastWarnedWay = nil
        isGuiding = true
        refreshTracking()
        if let ins = currentInstruction { speak(ins) }
    }

    func stopGuidance() {
        isGuiding = false
        refreshTracking()
        synth.stopSpeaking(at: .immediate)
    }

    // MARK: Echtzeit-Prüfung ein- und ausschalten

    func setLiveCheck(_ on: Bool) {
        liveCheckEnabled = on
        if !on {
            liveRoad = nil
            liveOffline = false
            forbiddenStreak.removeAll()
            lastWarnedWay = nil
        }
        refreshTracking()
    }

    private func refreshTracking() {
        if isGuiding || liveCheckEnabled {
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            locationManager.startUpdatingLocation()
        } else {
            locationManager.stopUpdatingLocation()
        }
    }

    // MARK: Ansagen und Warnungen

    private func speak(_ text: String) {
        guard voiceEnabled else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "de-DE")
        synth.speak(u)
    }

    /// Warnung: Banner, Vibration und Sprachansage (unterbricht andere Ansagen)
    private func warn(_ text: String) {
        alertText = text
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        synth.stopSpeaking(at: .immediate)
        speak(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.alertText == text { self?.alertText = nil }
        }
    }

    // MARK: Standort-Updates

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        location = loc

        if liveCheckEnabled || isGuiding { runLiveCheck(loc) }

        guard isGuiding, let route else { return }
        let steps = route.steps
        guard currentStepIndex < steps.count else { return }

        // Abstand zum nächsten Manöver
        let target = Geo.start(of: steps[currentStepIndex])
        let d = loc.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        distanceToManeuver = d

        if d < 150 && !announcedNear {
            announcedNear = true
            speak("In \(Int(d / 10) * 10) Metern: \(steps[currentStepIndex].instructions)")
        }
        if d < 30 {
            currentStepIndex += 1
            announcedNear = false
            if currentStepIndex >= steps.count {
                speak("Sie haben Ihr Ziel erreicht.")
                stopGuidance()
                return
            }
        }

        // Verbotene Stelle voraus (nur wenn keine komplett legale Route existiert)
        for v in violations where !warnedViolations.contains(v.id) {
            let vd = loc.distance(from: CLLocation(latitude: v.coordinate.latitude, longitude: v.coordinate.longitude))
            if vd < 400 {
                warnedViolations.insert(v.id)
                warn("Achtung, in 400 Metern: \(v.reason)")
            }
        }

        // Neuberechnung, wenn mehr als 80 m von der Route entfernt
        if Geo.distance(loc.coordinate, toPath: routeCoords) > 80,
           Date().timeIntervalSince(lastReroute) > 20,
           !isChecking,
           let dest = destination {
            lastReroute = Date()
            speak("Route wird neu berechnet.")
            Task {
                if await calculate(to: dest) != nil {
                    await MainActor.run { startGuidance() }
                }
            }
        }
    }

    // MARK: Echtzeit-Prüfung intern

    private func runLiveCheck(_ loc: CLLocation) {
        // Bei schlechtem GPS lieber nichts behaupten
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 40 else { return }
        guard !liveQueryRunning else { return }

        let now = Date()
        let moved = lastLiveLocation.map { loc.distance(from: $0) } ?? .infinity
        guard now.timeIntervalSince(lastLiveQuery) > 6, moved > 25 else { return }

        lastLiveQuery = now
        lastLiveLocation = loc
        liveQueryRunning = true

        let coord = loc.coordinate
        let onRoute = routeCoords.isEmpty ? false : Geo.distance(coord, toPath: routeCoords) < 25

        Task {
            do {
                let road = try await LiveRoadChecker.currentRoad(at: coord)
                await MainActor.run {
                    liveQueryRunning = false
                    liveOffline = false
                    handleLive(road, onRoute: onRoute)
                }
            } catch {
                await MainActor.run {
                    liveQueryRunning = false
                    liveOffline = true
                }
            }
        }
    }

    private func handleLive(_ road: LiveRoad?, onRoute: Bool) {
        guard var r = road else {
            liveRoad = nil
            return
        }
        // Auf der geprüften Route und auf einer Brücke/im Tunnel: vermutlich nur eine Straße darunter/darüber
        if !r.allowed && onRoute && r.isBridgeOrTunnel { r.allowed = true }
        liveRoad = r

        if !r.allowed {
            forbiddenStreak[r.wayID, default: 0] += 1
            // Erst nach zwei Messungen in Folge warnen, damit ein GPS-Ausreißer keinen Fehlalarm auslöst
            if forbiddenStreak[r.wayID, default: 0] >= 2 && lastWarnedWay != r.wayID {
                lastWarnedWay = r.wayID
                warn("Achtung! Hier sind Mopeds nicht erlaubt: \(r.title)")
            }
        } else {
            forbiddenStreak.removeAll()
            lastWarnedWay = nil
        }
    }

    // MARK: Symbole

    static func symbolName(for instruction: String) -> String {
        let t = instruction.lowercased()
        if t.contains("ziel") { return "flag.checkered" }
        if t.contains("kreisverkehr") || t.contains("kreisel") { return "arrow.triangle.turn.up.right.circle" }
        if t.contains("wenden") { return "arrow.uturn.down" }
        if t.contains("links") { return "arrow.turn.up.left" }
        if t.contains("rechts") { return "arrow.turn.up.right" }
        return "arrow.up"
    }
}
