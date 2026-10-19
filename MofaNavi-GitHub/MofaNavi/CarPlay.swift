// CarPlay ist standardmäßig AUS (Flag CARPLAY). Erst einschalten, wenn Apple die CarPlay-Berechtigung freigegeben hat.
#if CARPLAY
import CarPlay
import SwiftUI
import MapKit
import Combine

/// Karte, die im CarPlay-Display hinter den Templates angezeigt wird.
struct CarMapView: View {
    @ObservedObject private var navi = Navi.shared

    var body: some View {
        Map(initialPosition: .userLocation(followsHeading: true, fallback: .automatic)) {
            UserAnnotation()
            if let r = navi.route {
                MapPolyline(r)
                    .stroke(navi.violations.isEmpty ? Color.blue : Color.red, lineWidth: 8)
            }
        }
    }
}

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
                                  CPMapTemplateDelegate, CPSearchTemplateDelegate {

    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var rootTemplate: CPMapTemplate?
    private var session: CPNavigationSession?
    private var currentManeuver: CPManeuver?
    private var searchItems: [MKMapItem] = []
    private var cancellables = Set<AnyCancellable>()
    private var alertCancellables = Set<AnyCancellable>()

    // MARK: Verbindung

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        self.carWindow = window
        window.rootViewController = UIHostingController(rootView: CarMapView())

        let template = CPMapTemplate()
        template.mapDelegate = self
        template.leadingNavigationBarButtons = [
            CPBarButton(title: "Suche") { [weak self] _ in self?.showSearch() },
            CPBarButton(title: "Favoriten") { [weak self] _ in self?.showFavorites() }
        ]
        template.trailingNavigationBarButtons = [voiceButton()]
        rootTemplate = template
        interfaceController.setRootTemplate(template, animated: true, completion: nil)

        // Warnungen der Echtzeit-Prüfung auch im Auto-Display zeigen
        Navi.shared.$alertText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.presentAlert(text) }
            .store(in: &alertCancellables)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        Navi.shared.stopGuidance()
        cancellables.removeAll()
        alertCancellables.removeAll()
        self.interfaceController = nil
        self.carWindow = nil
        self.rootTemplate = nil
    }

    private func voiceButton() -> CPBarButton {
        CPBarButton(title: Navi.shared.voiceEnabled ? "Ton aus" : "Ton an") { [weak self] _ in
            Navi.shared.voiceEnabled.toggle()
            if let self { self.rootTemplate?.trailingNavigationBarButtons = [self.voiceButton()] }
        }
    }

    private func presentAlert(_ text: String?) {
        guard let text, let template = rootTemplate else { return }
        let ok = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPNavigationAlert(titleVariants: [text],
                                      subtitleVariants: [],
                                      image: UIImage(systemName: "exclamationmark.triangle.fill"),
                                      primaryAction: ok,
                                      secondaryAction: nil,
                                      duration: 8)
        template.present(navigationAlert: alert, animated: true)
    }

    // MARK: Suche

    private func showSearch() {
        let search = CPSearchTemplate()
        search.delegate = self
        interfaceController?.pushTemplate(search, animated: true, completion: nil)
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        Task {
            let items = Array((await Navi.shared.searchItems(searchText)).prefix(12))
            let list = items.enumerated().map { (i, m) -> CPListItem in
                let li = CPListItem(text: m.name ?? "Ziel", detailText: m.placemark.title)
                li.userInfo = i
                return li
            }
            await MainActor.run {
                self.searchItems = items
                completionHandler(list)
            }
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        guard let i = item.userInfo as? Int, i < searchItems.count else {
            completionHandler()
            return
        }
        let target = searchItems[i]
        Task {
            let route = await Navi.shared.calculate(to: target)
            await MainActor.run {
                interfaceController?.popTemplate(animated: true, completion: nil)
                if let route { showPreview(route: route, target: target) }
                completionHandler()
            }
        }
    }

    // MARK: Favoriten

    private func showFavorites() {
        let favs = FavoritesStore.shared.items
        let items: [CPListItem]
        if favs.isEmpty {
            items = [CPListItem(text: "Noch keine Favoriten",
                                detailText: "In der iPhone-App mit dem Stern speichern")]
        } else {
            items = favs.map { f in
                let li = CPListItem(text: f.name, detailText: f.subtitle)
                li.handler = { [weak self] _, completion in
                    Task {
                        let target = f.mapItem
                        let route = await Navi.shared.calculate(to: target)
                        await MainActor.run {
                            self?.interfaceController?.popTemplate(animated: true, completion: nil)
                            if let route { self?.showPreview(route: route, target: target) }
                            completion()
                        }
                    }
                }
                return li
            }
        }
        let list = CPListTemplate(title: "Favoriten", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    // MARK: Vorschau und Start

    private func showPreview(route: MKRoute, target: MKMapItem) {
        let navi = Navi.shared
        let summary = "\(formatDistance(route.distance)) · ca. \(navi.minutes(for: route.distance)) Min"
        let info = navi.violations.isEmpty
            ? "Keine Autobahn oder Kraftfahrstraße erkannt"
            : "ACHTUNG: Verbotene Straße auf der Route!"
        let choice = CPRouteChoice(summaryVariants: [summary],
                                   additionalInformationVariants: [info],
                                   selectionSummaryVariants: [summary])
        let trip = CPTrip(origin: MKMapItem.forCurrentLocation(),
                          destination: target,
                          routeChoices: [choice])
        rootTemplate?.showTripPreviews([trip], textConfiguration: nil)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        mapTemplate.hideTripPreviews()
        session = mapTemplate.startNavigationSession(for: trip)
        Navi.shared.startGuidance()
        updateManeuver()

        cancellables.removeAll()
        Navi.shared.$currentStepIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateManeuver() }
            .store(in: &cancellables)
        Navi.shared.$distanceToManeuver
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in
                guard let self, let m = self.currentManeuver else { return }
                self.session?.updateEstimates(
                    CPTravelEstimates(distanceRemaining: Measurement(value: d, unit: .meters),
                                      timeRemaining: d / 11),
                    for: m)
            }
            .store(in: &cancellables)
        Navi.shared.$isGuiding
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.session?.finishTrip()
                self?.session = nil
            }
            .store(in: &cancellables)
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        Navi.shared.stopGuidance()
        session?.cancelTrip()
        session = nil
        cancellables.removeAll()
    }

    private func updateManeuver() {
        guard let route = Navi.shared.route else { return }
        let i = Navi.shared.currentStepIndex
        guard i < route.steps.count else { return }
        let step = route.steps[i]

        let m = CPManeuver()
        m.instructionVariants = [step.instructions]
        m.symbolImage = UIImage(systemName: Navi.symbolName(for: step.instructions))
        m.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: Measurement(value: step.distance, unit: .meters),
            timeRemaining: step.distance / 11)
        currentManeuver = m
        session?.upcomingManeuvers = [m]
    }
}

#endif
