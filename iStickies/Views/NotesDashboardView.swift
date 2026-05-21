import SwiftUI
#if os(iOS)
import UIKit
#endif

enum StickyNoteCardLayout {
    static let gridSpacing: CGFloat = 16
    static let outerPadding: CGFloat = 16
    static let contentPadding: CGFloat = 16
    static let cornerRadius: CGFloat = 4
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
        paperBody
    }

    private var paperBody: some View {
        let cardShape = RoundedRectangle(
            cornerRadius: StickyNoteCardLayout.cornerRadius,
            style: .continuous
        )

        return content
            .padding(StickyNoteCardLayout.contentPadding)
            .frame(maxWidth: .infinity, minHeight: StickyNoteCardLayout.height, alignment: .topLeading)
            .background {
                ZStack {
                    StickyNotePaperBackground(color: color)
                    StickyNotePaperEdgeTone()
                }
                .clipShape(cardShape)
            }
            .clipShape(cardShape)
            .overlay {
                cardShape
                    .strokeBorder(.black.opacity(0.12), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.13), radius: 5, x: 0, y: 3)
            .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
    }
}

struct StickyNotePaperBackground: View {
    let color: Color

    var body: some View {
        ZStack {
            color

            LinearGradient(
                colors: [
                    .white.opacity(0.14),
                    .clear,
                    .black.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    .white.opacity(0.08),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            StickyNotePaperTexture()
        }
    }
}

private struct StickyNotePaperEdgeTone: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .white.opacity(0.20),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                Color.white.opacity(0.32)
                    .frame(height: 1)

                Spacer(minLength: 0)

                Color.black.opacity(0.07)
                    .frame(height: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct StickyNotePaperTexture: View {
    private struct Fiber: Identifiable {
        let id: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let thickness: CGFloat
        let rotation: Double
        let opacity: Double
        let isHighlight: Bool
    }

    private static let fibers: [Fiber] = [
        Fiber(id: 0, x: 0.17, y: 0.10, width: 0.50, thickness: 0.55, rotation: -2, opacity: 0.13, isHighlight: true),
        Fiber(id: 1, x: 0.72, y: 0.14, width: 0.30, thickness: 0.45, rotation: 3, opacity: 0.08, isHighlight: false),
        Fiber(id: 2, x: 0.42, y: 0.22, width: 0.62, thickness: 0.55, rotation: 1, opacity: 0.10, isHighlight: true),
        Fiber(id: 3, x: 0.66, y: 0.29, width: 0.38, thickness: 0.45, rotation: -3, opacity: 0.08, isHighlight: false),
        Fiber(id: 4, x: 0.24, y: 0.36, width: 0.40, thickness: 0.50, rotation: 3, opacity: 0.09, isHighlight: false),
        Fiber(id: 5, x: 0.57, y: 0.44, width: 0.58, thickness: 0.55, rotation: -1, opacity: 0.11, isHighlight: true),
        Fiber(id: 6, x: 0.20, y: 0.52, width: 0.34, thickness: 0.45, rotation: -4, opacity: 0.09, isHighlight: true),
        Fiber(id: 7, x: 0.78, y: 0.59, width: 0.44, thickness: 0.50, rotation: 2, opacity: 0.08, isHighlight: false),
        Fiber(id: 8, x: 0.36, y: 0.67, width: 0.56, thickness: 0.55, rotation: -1, opacity: 0.09, isHighlight: false),
        Fiber(id: 9, x: 0.64, y: 0.76, width: 0.36, thickness: 0.45, rotation: 3, opacity: 0.10, isHighlight: true),
        Fiber(id: 10, x: 0.18, y: 0.85, width: 0.48, thickness: 0.50, rotation: 1, opacity: 0.08, isHighlight: false),
        Fiber(id: 11, x: 0.52, y: 0.91, width: 0.52, thickness: 0.45, rotation: -2, opacity: 0.09, isHighlight: true)
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Self.fibers) { fiber in
                    Capsule()
                        .fill((fiber.isHighlight ? Color.white : Color.black).opacity(fiber.opacity))
                        .frame(
                            width: max(24, geometry.size.width * fiber.width),
                            height: fiber.thickness
                        )
                        .rotationEffect(.degrees(fiber.rotation))
                        .position(
                            x: geometry.size.width * fiber.x,
                            y: geometry.size.height * fiber.y
                        )
                }
            }
        }
        .blendMode(.multiply)
        .opacity(0.9)
        .allowsHitTesting(false)
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

    @ObservedObject private var noteListObservation: StickyNotesListObservation
    @ObservedObject private var statusObservation: StickyNotesStatusObservation

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
        self._noteListObservation = ObservedObject(wrappedValue: noteListObservation)
        self._statusObservation = ObservedObject(wrappedValue: statusObservation)
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

                        GeometryReader { geometry in
                            ScrollViewReader { scrollProxy in
                                ScrollView {
                                    if noteListObservation.noteIDs.isEmpty {
                                        ContentUnavailableView(
                                            "No Notes",
                                            systemImage: "note.text",
                                            description: Text("Tap + to create a sticky note.")
                                        )
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: geometry.size.height)
                                    } else {
                                        LazyVGrid(columns: columns, spacing: StickyNoteCardLayout.gridSpacing) {
                                            ForEach(orderedNoteIDs, id: \.self) { noteID in
                                                Group {
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
                                                .id(noteID)
                                            }
                                        }
                                        .padding(StickyNoteCardLayout.outerPadding)
                                        .frame(maxWidth: .infinity, alignment: .top)
                                    }
                                }
                                .refreshable {
                                    await store.syncNow()
                                }
                                .scrollDismissesKeyboard(.interactively)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .onChange(of: editingNoteID) { _, noteID in
                                    guard let noteID else { return }
                                    scrollNoteIntoView(noteID, with: scrollProxy)
                                }
#if os(iOS)
                                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                                    scrollEditingNoteIntoView(with: scrollProxy, delay: 0.18)
                                }
                                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                                    scrollEditingNoteIntoView(with: scrollProxy, delay: 0.08)
                                }
#endif
                            }
                        }
                    }
                    .navigationTitle("Stickies")
                    .toolbar {
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

    private func scrollEditingNoteIntoView(
        with scrollProxy: ScrollViewProxy,
        delay: TimeInterval = 0.12
    ) {
        guard let editingNoteID else { return }
        scrollNoteIntoView(editingNoteID, with: scrollProxy, delay: delay)
    }

    private func scrollNoteIntoView(
        _ noteID: String,
        with scrollProxy: ScrollViewProxy,
        delay: TimeInterval = 0.12
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard editingNoteID == noteID else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy.scrollTo(noteID, anchor: .center)
            }
        }
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
