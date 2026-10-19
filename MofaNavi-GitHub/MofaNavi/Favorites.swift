import Foundation
import SwiftUI
import Combine
import MapKit
import CoreLocation

struct Favorite: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

/// Speichert Favoriten dauerhaft auf dem iPhone.
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var items: [Favorite] = []
    private let key = "favorites.v1"

    init() { load() }

    func isFavorite(_ item: MKMapItem) -> Bool {
        items.contains { matches($0, item) }
    }

    func toggle(_ item: MKMapItem) {
        if let idx = items.firstIndex(where: { matches($0, item) }) {
            items.remove(at: idx)
        } else {
            let c = item.placemark.coordinate
            items.append(Favorite(
                name: item.name ?? "Ziel",
                subtitle: item.placemark.title ?? "",
                latitude: c.latitude,
                longitude: c.longitude))
        }
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func rename(_ fav: Favorite, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let idx = items.firstIndex(where: { $0.id == fav.id }) else { return }
        items[idx].name = trimmed
        save()
    }

    // MARK: intern

    /// Gleicher Ort = weniger als ca. 20 m Unterschied
    private func matches(_ f: Favorite, _ m: MKMapItem) -> Bool {
        let c = m.placemark.coordinate
        return abs(f.latitude - c.latitude) < 0.0002 && abs(f.longitude - c.longitude) < 0.0002
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
