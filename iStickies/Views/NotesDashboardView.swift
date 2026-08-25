import SwiftUI
#if os(iOS)
import UIKit
#endif

enum StickyNoteCardLayout {
    static let gridSpacing: CGFloat = 8
    static let outerPadding: CGFloat = 14
    static let topPadding: CGFloat = 28
    static let bottomPadding: CGFloat = 96
    static let contentPadding: CGFloat = 10
    static let cornerRadius: CGFloat = 8
    static let height: CGFloat = 164

    static var gridPadding: EdgeInsets {
        EdgeInsets(
            top: topPadding,
            leading: outerPadding,
            bottom: bottomPadding,
            trailing: outerPadding
        )
    }

    static func cardWidth(for availableWidth: CGFloat) -> CGFloat {
        let horizontalChrome = (outerPadding * 2) + gridSpacing
        return max((availableWidth - horizontalChrome) / 2, 0)
    }
}

enum StickyNotesKeyboardFrame {
    static func coversScene(endFrame: CGRect, sceneFrame: CGRect) -> Bool {
        guard !endFrame.isNull, !endFrame.isEmpty, !sceneFrame.isNull, !sceneFrame.isEmpty else {
            return false
        }

        return endFrame.intersects(sceneFrame)
    }

    static func coversScene(
        screenEndFrame: CGRect,
        sceneFrame: CGRect,
        convertScreenFrameToScene: (CGRect) -> CGRect
    ) -> Bool {
        coversScene(
            endFrame: convertScreenFrameToScene(screenEndFrame),
            sceneFrame: sceneFrame
        )
    }
}

struct StickyNoteCard<Content: View>: View {
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        paperBody
    }

    private var paperBody: some View {
        content
            .padding(StickyNoteCardLayout.contentPadding)
            .frame(maxWidth: .infinity, minHeight: StickyNoteCardLayout.height, alignment: .topLeading)
            .clipShape(StickyNotePaperShape())
            .background {
                StickyNotePaperSurface(color: color)
            }
            .contentShape(StickyNotePaperShape())
    }
}

struct StickyNotePaperSurface: View {
    let color: Color
    var showsShadow = true

    var body: some View {
        ZStack {
            StickyNotePaperBackground(color: color)
            StickyNotePaperEdgeTone()
        }
        .clipShape(StickyNotePaperShape())
        .overlay {
            StickyNotePaperShape()
                .stroke(.black.opacity(0.035), lineWidth: 0.6)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(showsShadow ? 0.16 : 0), radius: 18, x: 8, y: 13)
        .shadow(color: .black.opacity(showsShadow ? 0.07 : 0), radius: 4, x: 1, y: 2)
    }
}

struct StickyNotePaperShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(StickyNotePaperHitRegion.path(in: rect))
    }
}

enum StickyNotePaperHitRegion {
    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        return path(in: rect).contains(point, using: .winding, transform: .identity)
    }

    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return path }

        let cornerRadius = min(
            StickyNoteCardLayout.cornerRadius,
            rect.width / 2,
            rect.height / 2
        )

        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()

        return path
    }
}

struct StickyNotePaperBackground: View {
    let color: Color

    var body: some View {
        ZStack {
            color

            LinearGradient(
                colors: [
                    .white.opacity(0.28),
                    Color(red: 1.0, green: 0.86, blue: 0.36).opacity(0.08),
                    .clear,
                    .black.opacity(0.028)
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

            LinearGradient(
                colors: [
                    .clear,
                    .black.opacity(0.032)
                ],
                startPoint: .center,
                endPoint: .bottomTrailing
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
                    .white.opacity(0.18),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                Color.white.opacity(0.24)
                    .frame(height: 1)

                Spacer(minLength: 0)

                Color.black.opacity(0.018)
                    .frame(height: 1)
            }

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                LinearGradient(
                    colors: [
                        .black.opacity(0.032),
                        .clear
                    ],
                    startPoint: .trailing,
                    endPoint: .leading
                )
                .frame(width: 2)
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

    private struct Speck: Identifiable {
        let id: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let opacity: Double
        let isHighlight: Bool
    }

    private static let fibers: [Fiber] = [
        Fiber(id: 0, x: 0.18, y: 0.13, width: 0.24, thickness: 0.45, rotation: -12, opacity: 0.040, isHighlight: true),
        Fiber(id: 1, x: 0.68, y: 0.22, width: 0.18, thickness: 0.40, rotation: 14, opacity: 0.026, isHighlight: false),
        Fiber(id: 2, x: 0.38, y: 0.37, width: 0.28, thickness: 0.45, rotation: 7, opacity: 0.032, isHighlight: true),
        Fiber(id: 3, x: 0.75, y: 0.53, width: 0.20, thickness: 0.40, rotation: -16, opacity: 0.024, isHighlight: false),
        Fiber(id: 4, x: 0.25, y: 0.70, width: 0.22, thickness: 0.42, rotation: 11, opacity: 0.030, isHighlight: false),
        Fiber(id: 5, x: 0.58, y: 0.86, width: 0.26, thickness: 0.42, rotation: -9, opacity: 0.036, isHighlight: true)
    ]

    private static let specks: [Speck] = [
        Speck(id: 0, x: 0.12, y: 0.18, size: 0.9, opacity: 0.030, isHighlight: false),
        Speck(id: 1, x: 0.31, y: 0.09, size: 0.8, opacity: 0.040, isHighlight: true),
        Speck(id: 2, x: 0.54, y: 0.16, size: 1.0, opacity: 0.026, isHighlight: false),
        Speck(id: 3, x: 0.83, y: 0.12, size: 0.8, opacity: 0.035, isHighlight: true),
        Speck(id: 4, x: 0.18, y: 0.35, size: 1.1, opacity: 0.024, isHighlight: false),
        Speck(id: 5, x: 0.47, y: 0.31, size: 0.7, opacity: 0.042, isHighlight: true),
        Speck(id: 6, x: 0.72, y: 0.40, size: 1.0, opacity: 0.028, isHighlight: false),
        Speck(id: 7, x: 0.90, y: 0.34, size: 0.8, opacity: 0.036, isHighlight: true),
        Speck(id: 8, x: 0.09, y: 0.58, size: 0.8, opacity: 0.036, isHighlight: true),
        Speck(id: 9, x: 0.34, y: 0.55, size: 1.0, opacity: 0.025, isHighlight: false),
        Speck(id: 10, x: 0.62, y: 0.62, size: 0.8, opacity: 0.038, isHighlight: true),
        Speck(id: 11, x: 0.84, y: 0.69, size: 1.1, opacity: 0.026, isHighlight: false),
        Speck(id: 12, x: 0.20, y: 0.82, size: 0.9, opacity: 0.032, isHighlight: false),
        Speck(id: 13, x: 0.45, y: 0.78, size: 0.8, opacity: 0.040, isHighlight: true),
        Speck(id: 14, x: 0.70, y: 0.88, size: 1.0, opacity: 0.024, isHighlight: false),
        Speck(id: 15, x: 0.91, y: 0.86, size: 0.8, opacity: 0.034, isHighlight: true)
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Self.fibers) { fiber in
                    Capsule()
                        .fill((fiber.isHighlight ? Color.white : Color.black).opacity(fiber.opacity))
                        .frame(
                            width: max(12, geometry.size.width * fiber.width),
                            height: fiber.thickness
                        )
                        .rotationEffect(.degrees(fiber.rotation))
                        .position(
                            x: geometry.size.width * fiber.x,
                            y: geometry.size.height * fiber.y
                        )
                }

                ForEach(Self.specks) { speck in
                    Circle()
                        .fill((speck.isHighlight ? Color.white : Color.black).opacity(speck.opacity))
                        .frame(width: speck.size, height: speck.size)
                        .position(
                            x: geometry.size.width * speck.x,
                            y: geometry.size.height * speck.y
                        )
                }
            }
        }
        .opacity(0.72)
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
            StickyNoteCard(color: note.color.tint) {
                ZStack(alignment: .topTrailing) {
                    Text(note.content.isEmpty ? "Empty Note" : note.title)
                        .font(StickyNoteTypography.cardTitleFont)
                        .foregroundStyle(Color.black.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.horizontal, 10)

                    if note.needsCloudUpload {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(Color.black.opacity(0.42))
                            .padding(2)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: StickyNoteCardLayout.height - (StickyNoteCardLayout.contentPadding * 2)
                )
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
            StickyNoteCard(color: note.color.tint) {
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
                    Task { await store.syncNow(retryingBlockedUploads: true) }
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
private struct AddStickyNoteButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void

    private var ambientShadowOpacity: Double {
        colorScheme == .dark ? 0.55 : 0.16
    }

    private var contactShadowOpacity: Double {
        colorScheme == .dark ? 0.25 : 0.07
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 27, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.92))
                .frame(width: 58, height: 58)
                .background {
                    Circle()
                        .fill(Color(.secondarySystemGroupedBackground).opacity(0.98))
                        .overlay {
                            Circle()
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
                        }
                        .shadow(color: .black.opacity(ambientShadowOpacity), radius: 18, x: 0, y: 10)
                        .shadow(color: .black.opacity(contactShadowOpacity), radius: 4, x: 0, y: 2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("StickyNotes.addNoteButton")
    }
}

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
#if os(iOS)
    @StateObject private var sceneWindowReference = StickyNotesSceneWindowReference()
#endif

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
                                                            StickyNotePaperShape()
                                                        )
                                                        .onTapGesture {
                                                            beginEditing(noteID: noteID)
                                                        }
                                                        .highPriorityGesture(
                                                            LongPressGesture()
                                                                .onEnded { _ in
                                                                    noteToDelete = noteID
                                                                }
                                                        )
                                                    }
                                                }
                                                .id(noteID)
                                            }
                                        }
                                        .padding(StickyNoteCardLayout.gridPadding)
                                        .frame(maxWidth: .infinity, alignment: .top)
                                    }
                                }
                                .refreshable {
                                    await store.syncNow(retryingBlockedUploads: true)
                                }
                                .scrollDismissesKeyboard(.interactively)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
#if os(iOS)
                                .background {
                                    StickyNotesSceneWindowReader(windowReference: sceneWindowReference)
                                        .frame(width: 0, height: 0)
                                        .allowsHitTesting(false)
                                }
#endif
                                .onChange(of: editingNoteID) { _, noteID in
                                    guard let noteID else { return }
                                    scrollNoteIntoView(noteID, with: scrollProxy)
                                }
#if os(iOS)
                                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                                    scrollEditingNoteIntoView(with: scrollProxy, delay: 0.18)
                                }
                                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
                                    guard keyboardEndFrameCoversScene(notification, sceneFrame: geometry.frame(in: .global)) else {
                                        return
                                    }
                                    scrollEditingNoteIntoView(with: scrollProxy, delay: 0.08)
                                }
#endif
                            }
                        }
                    }
                    .navigationTitle("Stickies")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .overlay(alignment: .bottomTrailing) {
                        AddStickyNoteButton {
                            let id = store.createNote()
                            beginEditing(noteID: id)
                        }
                        .padding(.trailing, 24)
                        .padding(.bottom, 24)
                    }
                    .toolbar {
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

#if os(iOS)
    private func keyboardEndFrameCoversScene(_ notification: Notification, sceneFrame: CGRect) -> Bool {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return false
        }
        guard let sceneWindow = sceneWindowReference.window else {
            return true
        }

        return StickyNotesKeyboardFrame.coversScene(
            screenEndFrame: endFrame,
            sceneFrame: sceneFrame,
            convertScreenFrameToScene: { sceneWindow.convert($0, from: nil) }
        )
    }
#endif

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

#if os(iOS)
private final class StickyNotesSceneWindowReference: ObservableObject {
    weak var window: UIWindow?
}

private struct StickyNotesSceneWindowReader: UIViewRepresentable {
    let windowReference: StickyNotesSceneWindowReference

    func makeUIView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.windowReference = windowReference
        return view
    }

    func updateUIView(_ view: WindowReportingView, context: Context) {
        view.windowReference = windowReference
        view.reportWindow()
    }

    final class WindowReportingView: UIView {
        weak var windowReference: StickyNotesSceneWindowReference?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportWindow()
        }

        func reportWindow() {
            windowReference?.window = window
        }
    }
}
#endif
