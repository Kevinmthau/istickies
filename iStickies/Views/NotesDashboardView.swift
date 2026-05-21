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
#if os(iOS)
        paperBody
#else
        flatBody
#endif
    }

    private var flatBody: some View {
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

#if os(iOS)
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
                    IOSStickyNotePaperBackground(color: color)
                    IOSStickyNotePaperEdgeLighting()
                }
                .clipShape(cardShape)
            }
            .clipShape(cardShape)
            .overlay(alignment: .bottomTrailing) {
                IOSStickyNotePaperCurl()
                    .frame(width: 82, height: 34)
                    .padding(.trailing, 8)
                    .padding(.bottom, 2)
            }
            .overlay {
                cardShape
                    .strokeBorder(.primary.opacity(0.13), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 8)
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
    }
#endif
}

#if os(iOS)
private struct IOSStickyNotePaperBackground: View {
    let color: Color

    var body: some View {
        ZStack {
            color

            LinearGradient(
                colors: [
                    .white.opacity(0.30),
                    .white.opacity(0.08),
                    .black.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    .white.opacity(0.22),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 220
            )

            IOSStickyNotePaperTexture()
        }
    }
}

private struct IOSStickyNotePaperEdgeLighting: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .white.opacity(0.32),
                    .clear
                ],
                startPoint: .top,
                endPoint: .center
            )

            LinearGradient(
                colors: [
                    .clear,
                    .black.opacity(0.08)
                ],
                startPoint: .center,
                endPoint: .bottomTrailing
            )
        }
        .allowsHitTesting(false)
    }
}

private struct IOSStickyNotePaperTexture: View {
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
        Fiber(id: 0, x: 0.16, y: 0.12, width: 0.42, thickness: 0.7, rotation: -3, opacity: 0.18, isHighlight: true),
        Fiber(id: 1, x: 0.74, y: 0.16, width: 0.24, thickness: 0.6, rotation: 5, opacity: 0.12, isHighlight: false),
        Fiber(id: 2, x: 0.41, y: 0.24, width: 0.52, thickness: 0.8, rotation: 2, opacity: 0.14, isHighlight: true),
        Fiber(id: 3, x: 0.68, y: 0.31, width: 0.32, thickness: 0.6, rotation: -4, opacity: 0.11, isHighlight: false),
        Fiber(id: 4, x: 0.24, y: 0.39, width: 0.34, thickness: 0.7, rotation: 4, opacity: 0.13, isHighlight: false),
        Fiber(id: 5, x: 0.58, y: 0.47, width: 0.48, thickness: 0.7, rotation: -2, opacity: 0.15, isHighlight: true),
        Fiber(id: 6, x: 0.21, y: 0.55, width: 0.28, thickness: 0.6, rotation: -5, opacity: 0.11, isHighlight: true),
        Fiber(id: 7, x: 0.78, y: 0.61, width: 0.36, thickness: 0.7, rotation: 3, opacity: 0.13, isHighlight: false),
        Fiber(id: 8, x: 0.36, y: 0.69, width: 0.46, thickness: 0.8, rotation: -1, opacity: 0.12, isHighlight: false),
        Fiber(id: 9, x: 0.63, y: 0.78, width: 0.30, thickness: 0.6, rotation: 4, opacity: 0.12, isHighlight: true),
        Fiber(id: 10, x: 0.18, y: 0.86, width: 0.40, thickness: 0.7, rotation: 2, opacity: 0.10, isHighlight: false)
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
        .blendMode(.softLight)
        .allowsHitTesting(false)
    }
}

private struct IOSStickyNotePaperCurl: View {
    var body: some View {
        StickyNotePaperCurlShape()
            .fill(
                LinearGradient(
                    colors: [
                        .white.opacity(0.18),
                        .black.opacity(0.10),
                        .black.opacity(0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                StickyNotePaperCurlShape()
                    .stroke(.white.opacity(0.16), lineWidth: 0.7)
                    .blur(radius: 0.4)
            }
            .blendMode(.multiply)
            .allowsHitTesting(false)
    }
}

private struct StickyNotePaperCurlShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.18),
            control1: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.maxY - rect.height * 0.04),
            control2: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.02)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
#endif

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
                            }
                            .refreshable {
                                await store.syncNow()
                            }
                            .scrollDismissesKeyboard(.interactively)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private func syncDisplayOrder(with latestIDs: [String]) {
        displayOrderIDs = StickyNoteDisplayOrder.reconciledIDs(
            currentIDs: displayOrderIDs,
            latestIDs: latestIDs,
            preserveCurrentOrder: editingNoteID != nil
        )
    }
}
#endif
