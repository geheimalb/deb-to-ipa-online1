import Foundation
import Combine
import MapKit

/// Liefert Vorschläge schon während der Eingabe (München und Umgebung).
final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755),
            latitudinalMeters: 100_000,
            longitudinalMeters: 100_000)
    }

    func update(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            completer.cancel()
            suggestions = []
        } else {
            completer.queryFragment = text
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = Array(completer.results.prefix(6))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }
}
