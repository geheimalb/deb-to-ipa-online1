import SwiftUI
import MapKit

struct SuggestionRow {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let action: () -> Void
}

struct ContentView: View {
    @ObservedObject private var navi = Navi.shared
    @ObservedObject private var favs = FavoritesStore.shared
    @StateObject private var completer = SearchCompleter()

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var showFavorites = false
    @State private var showSplash = true
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755),
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)))

    var body: some View {
        ZStack {
            mapLayer
            overlayLayer
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.5)) { showSplash = false }
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView { fav in
                Task { await navi.calculate(to: fav.mapItem) }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Karte

    private var mapLayer: some View {
        Map(position: $position) {
            UserAnnotation()
            ForEach(favs.items) { f in
                Marker(f.name, systemImage: "star.fill", coordinate: f.coordinate)
                    .tint(.yellow)
            }
            if let d = navi.destination {
                Marker(d.name ?? "Ziel", coordinate: d.placemark.coordinate)
                    .tint(.red)
            }
            if let r = navi.route {
                MapPolyline(r)
                    .stroke(navi.violations.isEmpty ? Color.blue : Color.red,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            ForEach(navi.violations) { v in
                Annotation(v.reason, coordinate: v.coordinate) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding(5)
                        .background(Color.white, in: Circle())
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls { MapCompass(); MapScaleView() }
        .ignoresSafeArea()
        .onReceive(navi.$route) { r in
            guard let r, !navi.isGuiding else { return }
            let rect = r.polyline.boundingMapRect
            position = .rect(rect.insetBy(dx: -rect.width * 0.3, dy: -rect.height * 0.5))
        }
        .onReceive(navi.$isGuiding) { g in
            if g { position = .userLocation(followsHeading: true, fallback: .automatic) }
        }
    }

    // MARK: Überlagerung

    private var overlayLayer: some View {
        VStack(spacing: 12) {
            if let alert = navi.alertText { alertBanner(alert) }
            if navi.isGuiding { guidanceBanner } else { searchArea }
            Spacer()
            HStack(alignment: .bottom) {
                speedWidget
                Spacer()
                floatingButtons
            }
            bottomArea
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.smooth, value: navi.isGuiding)
        .animation(.smooth, value: navi.alertText)
    }

    private func alertBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.subheadline.weight(.bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                     tint: Color.red.opacity(0.65))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Suche

    private var searchArea: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Ziel in München und Umgebung", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { Task { await navi.search(query) } }
                    .onChange(of: query) { _, new in completer.update(new) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        completer.update("")
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .liquidGlass(in: Capsule(), interactive: true)

            suggestionList
        }
    }

    private var suggestionRows: [SuggestionRow] {
        if !navi.results.isEmpty {
            return navi.results.map { item in
                SuggestionRow(icon: "mappin.circle.fill", color: .red,
                              title: item.name ?? "Unbekannt",
                              subtitle: item.placemark.title ?? "") { select(item) }
            }
        }
        if query.isEmpty {
            guard searchFocused else { return [] }
            return favs.items.prefix(5).map { f in
                SuggestionRow(icon: "star.fill", color: .yellow,
                              title: f.name, subtitle: f.subtitle) {
                    clearSearch()
                    Task { await navi.calculate(to: f.mapItem) }
                }
            }
        }
        return completer.suggestions.map { c in
            SuggestionRow(icon: "mappin.circle.fill", color: .red,
                          title: c.title, subtitle: c.subtitle) { select(c) }
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        let rows = suggestionRows
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    Button(action: row.action) { SuggestionRowView(row: row) }
                        .buttonStyle(.plain)
                    if i < rows.count - 1 { Divider().padding(.leading, 60) }
                }
            }
            .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private func clearSearch() {
        query = ""
        searchFocused = false
        completer.update("")
    }

    private func select(_ item: MKMapItem) {
        clearSearch()
        Task { await navi.calculate(to: item) }
    }

    private func select(_ c: MKLocalSearchCompletion) {
        clearSearch()
        Task {
            if let item = await navi.resolve(c) { await navi.calculate(to: item) }
        }
    }

    // MARK: Schwebende Knöpfe

    private var liveTint: Color? {
        navi.liveCheckEnabled ? Color.green.opacity(0.45) : nil
    }

    private var floatingButtons: some View {
        GlassGroup(spacing: 12) {
            VStack(spacing: 12) {
                GlassIconButton(systemName: "location.fill") {
                    position = .userLocation(fallback: .automatic)
                }
                GlassIconButton(systemName: navi.liveCheckEnabled ? "checkmark.shield.fill" : "shield",
                                tint: liveTint) {
                    navi.setLiveCheck(!navi.liveCheckEnabled)
                }
                GlassIconButton(systemName: navi.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                    navi.voiceEnabled.toggle()
                }
                GlassIconButton(systemName: "star.fill") { showFavorites = true }
            }
        }
    }

    // MARK: Tempo-Anzeige (wie bei Waze)

    @ViewBuilder
    private var speedWidget: some View {
        if navi.isGuiding || navi.liveCheckEnabled {
            HStack(spacing: 10) {
                SpeedGauge(speed: navi.speedKmh, tooFast: navi.isTooFast)
                SpeedSign(limit: navi.liveRoad?.speedLimit, size: 58)
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: Navigationsbanner

    private var guidanceBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: Navi.symbolName(for: navi.currentInstruction ?? ""))
                .font(.system(size: 34, weight: .bold))
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDistance(navi.distanceToManeuver)).font(.title2.bold())
                Text(navi.currentInstruction ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    // MARK: Unterer Bereich

    @ViewBuilder
    private var bottomArea: some View {
        VStack(spacing: 10) {
            if navi.isGuiding || navi.liveCheckEnabled { liveChip }
            if navi.isChecking {
                checkingPill
            } else if let r = navi.route {
                routePanel(r)
            } else if let e = navi.error {
                Text(e)
                    .font(.subheadline)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private var checkingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Prüfe Route auf erlaubte Straßen …").font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .liquidGlass(in: Capsule())
    }

    /// Echtzeit-Anzeige: auf welcher Straße bist du gerade und darfst du dort fahren?
    private var liveChip: some View {
        let road = navi.liveRoad
        let allowed = road?.allowed ?? true
        let tint: Color? = road == nil ? nil : (allowed ? Color.green.opacity(0.22) : Color.red.opacity(0.55))
        let title = road?.title ?? (navi.liveOffline ? "Keine Verbindung" : "Straße wird geprüft …")
        let status: String
        if let road {
            status = road.allowed ? "Für Moped erlaubt · Moped max. 45 km/h" : (road.reason ?? "Für Moped verboten")
        } else {
            status = navi.liveOffline ? "Echtzeit-Prüfung braucht Internet" : "Warte auf Standort"
        }

        return HStack(spacing: 12) {
            Image(systemName: "road.lanes")
                .font(.title2)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if road != nil {
                Image(systemName: allowed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(allowed ? Color.green : Color.red)
            }
        }
        .padding(12)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), tint: tint)
    }

    private func routePanel(_ r: MKRoute) -> some View {
        let meters = navi.isGuiding ? navi.remainingMeters : r.distance
        let mins = navi.minutes(for: meters)
        let arrival = Date().addingTimeInterval(Double(mins) * 60)
            .formatted(date: .omitted, time: .shortened)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(navi.destination?.name ?? "Ziel").font(.title3.bold()).lineLimit(1)
                    Text("\(formatDistance(meters)) · \(mins) Min · Ankunft \(arrival)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let d = navi.destination {
                    Button { favs.toggle(d) } label: {
                        Image(systemName: favs.isFavorite(d) ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(.yellow)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                }
                Button { navi.clearRoute() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }

            if navi.violations.isEmpty {
                Label("Keine Autobahn, Kraftfahrstraße oder gesperrte Straße erkannt",
                      systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Label("Achtung: Auf dieser Route sind Mopeds nicht erlaubt!",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                ForEach(navi.violations.prefix(3)) { v in
                    Text("• \(v.reason)").font(.caption)
                }
            }

            if let note = navi.checkNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            Button {
                if navi.isGuiding { navi.stopGuidance() } else { navi.startGuidance() }
            } label: {
                Text(buttonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .glassButton(prominent: true, tint: buttonTint)
        }
        .padding(18)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var buttonTitle: String {
        if navi.isGuiding { return "Navigation beenden" }
        return navi.violations.isEmpty ? "Navigation starten" : "Trotzdem starten (Route prüfen!)"
    }

    private var buttonTint: Color {
        (navi.isGuiding || !navi.violations.isEmpty) ? Color.red : Color.blue
    }
}

// MARK: - Zeile für Vorschläge

struct SuggestionRowView: View {
    let row: SuggestionRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.icon)
                .font(.title3)
                .foregroundStyle(row.color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Favoriten

struct FavoritesView: View {
    @ObservedObject private var store = FavoritesStore.shared
    let onSelect: (Favorite) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Favorite?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Favoriten",
                        systemImage: "star",
                        description: Text("Suche ein Ziel und tippe auf den Stern, um es hier zu speichern."))
                } else {
                    List {
                        ForEach(store.items) { f in
                            Button {
                                onSelect(f)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                        if !f.subtitle.isEmpty {
                                            Text(f.subtitle).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .contextMenu {
                                Button("Umbenennen", systemImage: "pencil") {
                                    newName = f.name
                                    renaming = f
                                }
                            }
                        }
                        .onDelete { store.remove(at: $0) }
                        .onMove { store.move(from: $0, to: $1) }
                    }
                }
            }
            .navigationTitle("Favoriten")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .alert("Favorit umbenennen",
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Speichern") {
                if let f = renaming { store.rename(f, to: newName) }
                renaming = nil
            }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
    }
}

// MARK: - Startbild

struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 190, height: 190)
                    .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
                Text("Mofa Navi")
                    .font(.largeTitle.bold())
                Text("München und Umgebung")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
