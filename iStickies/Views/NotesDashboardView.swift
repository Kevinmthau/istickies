import SwiftUI

enum StickyNoteCardLayout {
    static let gridSpacing: CGFloat = 16
    static let outerPadding: CGFloat = 16
    static let contentPadding: CGFloat = 16
    static let cornerRadius: CGFloat = 20
    static let height: CGFloat = 180

    static func cardWidth(for availableWidth: CGFloat) -> CGFloat {
        let horizontalChrome = (outerPadding * 2) + gridSpacing
        return max((availableWidth - horizontalChrome) / 2, 0)
    }
}

struct StickyNoteCardChrome<Content: View>: View {
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(StickyNoteCardLayout.contentPadding)
            .frame(maxWidth: .infinity, minHeight: StickyNoteCardLayout.height, alignment: .topLeading)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: StickyNoteCardLayout.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: StickyNoteCardLayout.cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}

enum StickyNoteDisplayOrder {
    static func reconciledIDs(
        currentIDs: [String],
        latestIDs: [String],
        preserveCurrentOrder: Bool
    ) -> [String] {
        guard preserveCurrentOrder, !currentIDs.isEmpty else { return latestIDs }

        let latestIDSet = Set(latestIDs)
        let survivingCurrentIDs = currentIDs.filter { latestIDSet.contains($0) }
        let survivingCurrentIDSet = Set(survivingCurrentIDs)
        let appendedLatestIDs = latestIDs.filter { !survivingCurrentIDSet.contains($0) }

        return survivingCurrentIDs + appendedLatestIDs
    }
}

struct StickyNoteCardView: View {
    let note: StickyNote

    var body: some View {
        StickyNoteCardChrome(color: note.color.tint) {
            VStack(alignment: .leading, spacing: 8) {
                if note.needsCloudUpload {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(note.content.isEmpty ? "Empty Note" : note.content)
                    .font(StickyNoteTypography.bodyFont)
                    .foregroundStyle(.black)
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

struct HomeScreenStickyNoteEditorCardView: View {
    let note: StickyNote

    var body: some View {
        StickyNoteCardChrome(color: note.color.tint) {
            VStack(alignment: .leading, spacing: 8) {
                if note.needsCloudUpload {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                StickyNoteEditor(noteID: note.id, autoFocusOnAppear: true)
            }
        }
    }
}

private struct StickyNotesSyncModifier: ViewModifier {
    @ObservedObject var store: StickyNotesStore
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, newValue in
                if newValue == .active {
                    Task { await store.syncNow() }
                } else if newValue == .background {
                    Task { await store.flushPendingPersistence() }
                }
            }
            .alert("Sync Error", isPresented: syncErrorBinding) {
                Button("OK") { store.lastErrorMessage = nil }
            } message: {
                Text(store.lastErrorMessage ?? "")
            }
    }

    private var syncErrorBinding: Binding<Bool> {
        Binding(
            get: { store.lastErrorMessage != nil },
            set: { if !$0 { store.lastErrorMessage = nil } }
        )
    }
}

#if !os(macOS)
struct MobileNotesSceneView: View {
    @EnvironmentObject private var store: StickyNotesStore

    @State private var editingNoteID: String?
    @State private var displayOrderIDs: [String] = []
    @State private var noteToDelete: String?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: StickyNoteCardLayout.gridSpacing, alignment: .top),
        count: 2
    )

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                if store.notes.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "note.text",
                        description: Text("Tap + to create a sticky note.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: StickyNoteCardLayout.gridSpacing) {
                            ForEach(orderedNotes) { note in
                                if editingNoteID == note.id {
                                    HomeScreenStickyNoteEditorCardView(note: note)
                                } else {
                                    StickyNoteCardView(note: note)
                                        .contentShape(
                                            RoundedRectangle(
                                                cornerRadius: StickyNoteCardLayout.cornerRadius,
                                                style: .continuous
                                            )
                                        )
                                        .onTapGesture {
                                            beginEditing(noteID: note.id)
                                        }
                                        .onLongPressGesture {
                                            noteToDelete = note.id
                                        }
                                }
                            }
                        }
                        .padding(StickyNoteCardLayout.outerPadding)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .navigationTitle("Stickies")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.syncNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let id = store.createNote()
                        beginEditing(noteID: id)
                    } label: {
                        Image(systemName: "plus")
                    }
                }

                if editingNoteID != nil {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()

                        Button("Done") {
                            editingNoteID = nil
                        }
                    }
                }
            }
        }
        .confirmationDialog("Delete this note?", isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let noteToDelete {
                    store.deleteNote(id: noteToDelete)
                    self.noteToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                noteToDelete = nil
            }
        }
        .onAppear {
            displayOrderIDs = store.notes.map(\.id)
        }
        .onChange(of: store.notes.map(\.id)) { _, ids in
            if let editingNoteID, !ids.contains(editingNoteID) {
                self.editingNoteID = nil
            }
            if let noteToDelete, !ids.contains(noteToDelete) {
                self.noteToDelete = nil
            }

            syncDisplayOrder(with: ids)
        }
        .onChange(of: editingNoteID) { _, newValue in
            if newValue == nil {
                displayOrderIDs = store.notes.map(\.id)
            }
        }
        .modifier(StickyNotesSyncModifier(store: store))
    }

    private var orderedNotes: [StickyNote] {
        let latestIDs = store.notes.map(\.id)
        let orderedIDs = StickyNoteDisplayOrder.reconciledIDs(
            currentIDs: displayOrderIDs,
            latestIDs: latestIDs,
            preserveCurrentOrder: editingNoteID != nil
        )
        let notesByID = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0) })

        return orderedIDs.compactMap { notesByID[$0] }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { noteToDelete != nil },
            set: { shouldShow in
                if !shouldShow {
                    noteToDelete = nil
                }
            }
        )
    }

    private func beginEditing(noteID: String) {
        displayOrderIDs = orderedNotes.map(\.id)
        editingNoteID = noteID
    }

    private func syncDisplayOrder(with latestIDs: [String]) {
        displayOrderIDs = StickyNoteDisplayOrder.reconciledIDs(
            currentIDs: displayOrderIDs,
            latestIDs: latestIDs,
            preserveCurrentOrder: editingNoteID != nil
        )
    }
}
#endif
