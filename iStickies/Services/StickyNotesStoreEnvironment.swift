import SwiftUI

private struct StickyNotesStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: StickyNotesStore? = nil
}

extension EnvironmentValues {
    var stickyNotesStore: StickyNotesStore? {
        get { self[StickyNotesStoreEnvironmentKey.self] }
        set { self[StickyNotesStoreEnvironmentKey.self] = newValue }
    }
}

extension View {
    func stickyNotesStore(_ store: StickyNotesStore) -> some View {
        environment(\.stickyNotesStore, store)
    }
}
