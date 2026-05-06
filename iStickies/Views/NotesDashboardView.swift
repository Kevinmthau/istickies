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
    @ObservedObject private var noteObservation: StickyNoteObservation

    init(noteObservation: StickyNoteObservation) {
        self._noteObservation = ObservedObject(wrappedValue: noteObservation)
    }

    var body: some View {
        if let note = noteObservation.note {
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
            .accessibilityIdentifier("StickyNotes.noteCard")
        }
    }
}

struct HomeScreenStickyNoteEditorCardView: View {
    @ObservedObject private var noteObservation: StickyNoteObservation

    init(noteObservation: StickyNoteObservation) {
        self._noteObservation = ObservedObject(wrappedValue: noteObservation)
    }

    var body: some View {
        if let note = noteObservation.note {
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
            .accessibilityIdentifier("StickyNotes.noteEditorCard")
        }
    }
}

private struct StickyNotesSyncModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var statusObservation: StickyNotesStatusObservation

    let store: StickyNotesStore

    init(store: StickyNotesStore, statusObservation: StickyNotesStatusObservation) {
        self.store = store
        self._statusObservation = ObservedObject(wrappedValue: statusObservation)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, newValue in
                if newValue == .active {
                    Task { await store.syncNow() }
                } else if newValue == .background {
                    Task { await store.flushPendingPersistence() }
                }
            }
            .alert("Sync Issue", isPresented: syncErrorBinding) {
                Button("Retry") {
                    store.clearLastErrorMessage()
                    Task { await store.syncNow() }
                }
                Button("Dismiss", role: .cancel) {
                    store.clearLastErrorMessage()
                }
            } message: {
                Text(statusObservation.lastErrorMessage ?? "")
            }
    }

    private var syncErrorBinding: Binding<Bool> {
        Binding(
            get: {
                statusObservation.localRecoveryIssue == nil
                    && statusObservation.lastErrorMessage != nil
            },
            set: { if !$0 { store.clearLastErrorMessage() } }
        )
    }
}

#if !os(macOS)
struct MobileNotesSceneView: View {
    @Environment(\.stickyNotesStore) private var store

    @ViewBuilder
    var body: some View {
        if let store {
            MobileNotesSceneContent(
                store: store,
                noteListObservation: store.noteListObservation(),
                statusObservation: store.syncStatusObservation()
            )
        } else {
            ContentUnavailableView("Notes Unavailable", systemImage: "note.text")
        }
    }
}

private struct MobileNotesSceneContent: View {
    let store: StickyNotesStore
    let statusObservation: StickyNotesStatusObservation

    @ObservedObject private var noteListObservation: StickyNotesListObservation

    @State private var editingNoteID: String?
    @State private var displayOrderIDs: [String] = []
    @State private var noteToDelete: String?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: StickyNoteCardLayout.gridSpacing, alignment: .top),
        count: 2
    )

    init(
        store: StickyNotesStore,
        noteListObservation: StickyNotesListObservation,
        statusObservation: StickyNotesStatusObservation
    ) {
        self.store = store
        self.statusObservation = statusObservation
        self._noteListObservation = ObservedObject(wrappedValue: noteListObservation)
    }

    var body: some View {
        Group {
            if let localRecoveryIssue = statusObservation.localRecoveryIssue {
                ZStack {
                    Color(.systemGroupedBackground)
                        .ignoresSafeArea()

                    StickyNotesLocalRecoveryView(issue: localRecoveryIssue) {
                        Task { await store.startFreshAfterLocalSnapshotFailure() }
                    }
                }
            } else {
                NavigationStack {
                    ZStack {
                        Color(.systemGroupedBackground)
                            .ignoresSafeArea()

                        if noteListObservation.noteIDs.isEmpty {
                            ContentUnavailableView(
                                "No Notes",
                                systemImage: "note.text",
                                description: Text("Tap + to create a sticky note.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: StickyNoteCardLayout.gridSpacing) {
                                    ForEach(orderedNoteIDs, id: \.self) { noteID in
                                        if editingNoteID == noteID {
                                            HomeScreenStickyNoteEditorCardView(
                                                noteObservation: store.noteObservation(withID: noteID)
                                            )
                                        } else {
                                            StickyNoteCardView(
                                                noteObservation: store.noteObservation(withID: noteID)
                                            )
                                                .contentShape(
                                                    RoundedRectangle(
                                                        cornerRadius: StickyNoteCardLayout.cornerRadius,
                                                        style: .continuous
                                                    )
                                                )
                                                .onTapGesture {
                                                    beginEditing(noteID: noteID)
                                                }
                                                .onLongPressGesture {
                                                    noteToDelete = noteID
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
                            .accessibilityIdentifier("StickyNotes.syncButton")
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                let id = store.createNote()
                                beginEditing(noteID: id)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityIdentifier("StickyNotes.addNoteButton")
                        }

                        if editingNoteID != nil {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()

                                Button("Done") {
                                    editingNoteID = nil
                                }
                                .accessibilityIdentifier("StickyNotes.doneEditingButton")
                            }
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
            displayOrderIDs = noteListObservation.noteIDs
        }
        .onChange(of: noteListObservation.noteIDs) { _, ids in
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
                displayOrderIDs = noteListObservation.noteIDs
            }
        }
        .modifier(StickyNotesSyncModifier(store: store, statusObservation: statusObservation))
    }

    private var orderedNoteIDs: [String] {
        let latestIDs = noteListObservation.noteIDs
        return StickyNoteDisplayOrder.reconciledIDs(
            currentIDs: displayOrderIDs,
            latestIDs: latestIDs,
            preserveCurrentOrder: editingNoteID != nil
        )
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
        displayOrderIDs = orderedNoteIDs
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
