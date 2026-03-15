import SwiftUI

struct NoteRowView: View {
    let note: StickyNote

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(note.color.tint)
                .frame(width: 12, height: 12)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(note.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if note.needsCloudUpload {
                    Label("Pending", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                }

                Text(note.lastModified, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SyncStatusView: View {
    let state: StickyNotesSyncState
    let lastSuccessfulCloudSync: Date?

    var body: some View {
        switch state {
        case .idle:
            if let lastSuccessfulCloudSync {
                Label(lastSuccessfulCloudSync.formatted(date: .omitted, time: .shortened), systemImage: "icloud")
                    .foregroundStyle(.secondary)
            } else {
                Label("Not synced yet", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
        case .syncing:
            Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.icloud")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

#if os(macOS)
struct MacNotesDashboardView: View {
    @EnvironmentObject private var store: StickyNotesStore
    @Environment(\.scenePhase) private var scenePhase

    let windowCoordinator: MacStickyNoteWindowCoordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("New Note") {
                    windowCoordinator.createAndFocusNote()
                }

                Button("Show All") {
                    windowCoordinator.showAllNotes()
                }

                Button("Sync") {
                    Task { await store.syncNow() }
                }

                Spacer()

                SyncStatusView(
                    state: store.syncState,
                    lastSuccessfulCloudSync: store.lastSuccessfulCloudSync
                )
                .font(.caption)
            }
            .padding(14)

            if store.notes.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "note.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.notes) { note in
                    HStack {
                        Button {
                            windowCoordinator.focus(noteID: note.id)
                        } label: {
                            NoteRowView(note: note)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(note.isOpen ? "Focus" : "Open") {
                            windowCoordinator.focus(noteID: note.id)
                        }

                        Button("Delete", role: .destructive) {
                            store.deleteNote(id: note.id)
                        }
                    }
                    .contextMenu {
                        Button("Open") {
                            windowCoordinator.focus(noteID: note.id)
                        }
                        Button("Delete", role: .destructive) {
                            store.deleteNote(id: note.id)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 460)
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                Task { await store.syncNow() }
            } else if newValue == .background {
                Task { await store.flushPendingPersistence() }
            }
        }
        .alert("Sync Error", isPresented: syncErrorBinding) {
            Button("OK") {
                store.lastErrorMessage = nil
            }
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
    }

    private var syncErrorBinding: Binding<Bool> {
        Binding(
            get: { store.lastErrorMessage != nil },
            set: { shouldShow in
                if !shouldShow {
                    store.lastErrorMessage = nil
                }
            }
        )
    }
}
#else
private struct StickyCardView: View {
    let note: StickyNote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title)
                .font(.headline)
                .lineLimit(2)

            Text(note.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            Spacer(minLength: 0)

            HStack {
                if note.needsCloudUpload {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(note.lastModified, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(note.color.tint)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 2)
    }
}

struct MobileNotesSceneView: View {
    @EnvironmentObject private var store: StickyNotesStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var editingNoteID: String?
    @State private var noteToDelete: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if store.notes.isEmpty {
                    ContentUnavailableView("No Notes", systemImage: "note.text",
                                           description: Text("Tap + to create a sticky note."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(store.notes) { note in
                                StickyCardView(note: note)
                                    .onTapGesture {
                                        editingNoteID = note.id
                                    }
                                    .onLongPressGesture {
                                        noteToDelete = note.id
                                    }
                            }
                        }
                        .padding(12)
                    }
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
                        editingNoteID = id
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                SyncStatusView(
                    state: store.syncState,
                    lastSuccessfulCloudSync: store.lastSuccessfulCloudSync
                )
                .font(.caption)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
            .navigationDestination(item: $editingNoteID) { noteID in
                NoteEditorView(noteID: noteID)
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
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                Task { await store.syncNow() }
            } else if newValue == .background {
                Task { await store.flushPendingPersistence() }
            }
        }
        .alert("Sync Error", isPresented: syncErrorBinding) {
            Button("OK") {
                store.lastErrorMessage = nil
            }
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
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

    private var syncErrorBinding: Binding<Bool> {
        Binding(
            get: { store.lastErrorMessage != nil },
            set: { shouldShow in
                if !shouldShow {
                    store.lastErrorMessage = nil
                }
            }
        )
    }
}
#endif
