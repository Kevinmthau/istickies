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

struct StickyNoteCardView: View {
    let note: StickyNote

    var body: some View {
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
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(8)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(note.color.tint)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
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

#if os(macOS)
struct MacNotesDashboardView: View {
    @EnvironmentObject private var store: StickyNotesStore

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
        .modifier(StickyNotesSyncModifier(store: store))
    }
}
#else
struct MobileNotesSceneView: View {
    @EnvironmentObject private var store: StickyNotesStore

    @State private var editingNoteID: String?
    @State private var noteToDelete: String?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
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
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(store.notes) { note in
                                StickyNoteCardView(note: note)
                                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    .onTapGesture {
                                        editingNoteID = note.id
                                    }
                                    .onLongPressGesture {
                                        noteToDelete = note.id
                                    }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
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
                        editingNoteID = id
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(item: $editingNoteID) { noteID in
                NoteEditorView(noteID: noteID, autoFocusOnAppear: true)
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
        .onChange(of: store.notes.map(\.id)) { _, ids in
            if let editingNoteID, !ids.contains(editingNoteID) {
                self.editingNoteID = nil
            }
            if let noteToDelete, !ids.contains(noteToDelete) {
                self.noteToDelete = nil
            }
        }
        .modifier(StickyNotesSyncModifier(store: store))
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
}
#endif
