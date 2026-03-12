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
struct MobileNotesSceneView: View {
    @EnvironmentObject private var store: StickyNotesStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.notes) { note in
                    NoteRowView(note: note)
                        .tag(note.id)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                if selection == note.id {
                                    selection = nil
                                }
                                store.deleteNote(id: note.id)
                            }
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
                        selection = id
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
                .padding()
            }
        } detail: {
            if let selection {
                NoteEditorView(noteID: selection)
            } else {
                ContentUnavailableView("Select a Note", systemImage: "note.text")
            }
        }
        .onAppear {
            if selection == nil {
                selection = store.notes.first?.id
            }
        }
        .onChange(of: store.notes.map(\.id)) { _, ids in
            guard let selection, !ids.contains(selection) else { return }
            self.selection = ids.first
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
