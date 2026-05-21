import SwiftUI
#if os(iOS)
import UIKit
#endif

enum StickyNoteCardLayout {
    static let gridSpacing: CGFloat = 20
    static let outerPadding: CGFloat = 24
    static let contentPadding: CGFloat = 18
    static let cornerRadius: CGFloat = 12
    static let height: CGFloat = 172

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
            StickyNoteCornerCurl(color: color)
        }
        .clipShape(StickyNotePaperShape())
        .overlay {
            StickyNotePaperShape()
                .stroke(.black.opacity(0.055), lineWidth: 0.7)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(showsShadow ? 0.12 : 0), radius: 18, x: 4, y: 12)
        .shadow(color: .black.opacity(showsShadow ? 0.06 : 0), radius: 3, x: 0, y: 1)
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
        let curlSize = StickyNotePaperMetrics.curlSize(in: rect)
        let curlReach = curlSize * 0.96
        let rightCurveStartY = max(rect.minY + cornerRadius, rect.maxY - curlReach)
        let bottomCurveEndX = max(rect.minX + cornerRadius, rect.maxX - curlReach)

        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rightCurveStartY))
        path.addCurve(
            to: CGPoint(x: bottomCurveEndX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - (curlSize * 0.38)),
            control2: CGPoint(x: rect.maxX - (curlSize * 0.24), y: rect.maxY)
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
                    .white.opacity(0.34),
                    .clear,
                    .black.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    .white.opacity(0.10),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [
                    .clear,
                    .black.opacity(0.045)
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

                Color.black.opacity(0.035)
                    .frame(height: 1)
            }

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                LinearGradient(
                    colors: [
                        .black.opacity(0.045),
                        .clear
                    ],
                    startPoint: .trailing,
                    endPoint: .leading
                )
                .frame(width: 3)
            }
        }
        .allowsHitTesting(false)
    }
}

private enum StickyNotePaperMetrics {
    static func curlSize(in rect: CGRect) -> CGFloat {
        let shortestSide = min(rect.width, rect.height)
        guard shortestSide > 0 else { return 0 }

        let minimum = min(shortestSide * 0.30, 38)
        let maximum = min(shortestSide * 0.40, 58)
        return min(max(shortestSide * 0.27, minimum), maximum)
    }
}

private struct StickyNoteCornerCurl: View {
    let color: Color

    var body: some View {
        ZStack {
            StickyNoteCurlPocketShadowShape()
                .fill(.black.opacity(0.16))
                .blur(radius: 3.2)
                .offset(x: -1.0, y: 1.4)

            StickyNoteCurlFoldShape()
                .fill(color)
                .overlay {
                    StickyNoteCurlFoldShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.30),
                                    .clear,
                                    .black.opacity(0.24)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    StickyNoteCurlFoldShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.10),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
                .overlay {
                    StickyNoteCurlFoldShape()
                        .stroke(.white.opacity(0.24), lineWidth: 0.7)
                }

            StickyNoteCurlCreaseShape()
                .stroke(.black.opacity(0.12), lineWidth: 0.9)
                .blur(radius: 0.2)

            StickyNoteCurlHighlightShape()
                .stroke(.white.opacity(0.48), lineWidth: 1.1)
                .blur(radius: 0.2)
        }
        .allowsHitTesting(false)
    }
}

private struct StickyNoteCurlFoldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let curlSize = StickyNotePaperMetrics.curlSize(in: rect)
        guard curlSize > 0 else { return Path() }

        let bottomAnchor = CGPoint(
            x: rect.maxX - (curlSize * 0.94),
            y: rect.maxY - (curlSize * 0.015)
        )
        let innerPoint = CGPoint(
            x: rect.maxX - (curlSize * 0.15),
            y: rect.maxY - (curlSize * 0.16)
        )
        let rightAnchor = CGPoint(
            x: rect.maxX - (curlSize * 0.015),
            y: rect.maxY - (curlSize * 0.94)
        )

        var path = Path()
        path.move(to: bottomAnchor)
        path.addCurve(
            to: innerPoint,
            control1: CGPoint(x: rect.maxX - (curlSize * 0.55), y: rect.maxY + (curlSize * 0.01)),
            control2: CGPoint(x: rect.maxX - (curlSize * 0.28), y: rect.maxY - (curlSize * 0.04))
        )
        path.addCurve(
            to: rightAnchor,
            control1: CGPoint(x: rect.maxX - (curlSize * 0.05), y: rect.maxY - (curlSize * 0.33)),
            control2: CGPoint(x: rect.maxX + (curlSize * 0.01), y: rect.maxY - (curlSize * 0.58))
        )
        path.addCurve(
            to: bottomAnchor,
            control1: CGPoint(x: rect.maxX - (curlSize * 0.18), y: rect.maxY - (curlSize * 0.66)),
            control2: CGPoint(x: rect.maxX - (curlSize * 0.55), y: rect.maxY - (curlSize * 0.22))
        )
        path.closeSubpath()

        return path
    }
}

private struct StickyNoteCurlPocketShadowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let curlSize = StickyNotePaperMetrics.curlSize(in: rect)
        guard curlSize > 0 else { return Path() }

        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - (curlSize * 1.02), y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - (curlSize * 1.02)),
            control1: CGPoint(x: rect.maxX - (curlSize * 0.36), y: rect.maxY),
            control2: CGPoint(x: rect.maxX, y: rect.maxY - (curlSize * 0.36))
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX - (curlSize * 0.28), y: rect.maxY - (curlSize * 0.24)),
            control1: CGPoint(x: rect.maxX - (curlSize * 0.04), y: rect.maxY - (curlSize * 0.62)),
            control2: CGPoint(x: rect.maxX - (curlSize * 0.12), y: rect.maxY - (curlSize * 0.36))
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX - (curlSize * 1.02), y: rect.maxY),
            control1: CGPoint(x: rect.maxX - (curlSize * 0.54), y: rect.maxY - (curlSize * 0.08)),
            control2: CGPoint(x: rect.maxX - (curlSize * 0.82), y: rect.maxY)
        )
        path.closeSubpath()

        return path
    }
}

private struct StickyNoteCurlCreaseShape: Shape {
    func path(in rect: CGRect) -> Path {
        let curlSize = StickyNotePaperMetrics.curlSize(in: rect)
        guard curlSize > 0 else { return Path() }

        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - (curlSize * 0.88), y: rect.maxY - (curlSize * 0.025)))
        path.addCurve(
            to: CGPoint(x: rect.maxX - (curlSize * 0.025), y: rect.maxY - (curlSize * 0.88)),
            control1: CGPoint(x: rect.maxX - (curlSize * 0.34), y: rect.maxY - (curlSize * 0.025)),
            control2: CGPoint(x: rect.maxX - (curlSize * 0.025), y: rect.maxY - (curlSize * 0.34))
        )

        return path
    }
}

private struct StickyNoteCurlHighlightShape: Shape {
    func path(in rect: CGRect) -> Path {
        let curlSize = StickyNotePaperMetrics.curlSize(in: rect)
        guard curlSize > 0 else { return Path() }

        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - (curlSize * 0.66), y: rect.maxY - (curlSize * 0.09)))
        path.addCurve(
            to: CGPoint(x: rect.maxX - (curlSize * 0.09), y: rect.maxY - (curlSize * 0.66)),
            control1: CGPoint(x: rect.maxX - (curlSize * 0.32), y: rect.maxY - (curlSize * 0.11)),
            control2: CGPoint(x: rect.maxX - (curlSize * 0.11), y: rect.maxY - (curlSize * 0.32))
        )

        return path
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
        Fiber(id: 0, x: 0.17, y: 0.10, width: 0.50, thickness: 0.55, rotation: -2, opacity: 0.08, isHighlight: true),
        Fiber(id: 1, x: 0.72, y: 0.14, width: 0.30, thickness: 0.45, rotation: 3, opacity: 0.05, isHighlight: false),
        Fiber(id: 2, x: 0.42, y: 0.22, width: 0.62, thickness: 0.55, rotation: 1, opacity: 0.07, isHighlight: true),
        Fiber(id: 3, x: 0.66, y: 0.29, width: 0.38, thickness: 0.45, rotation: -3, opacity: 0.05, isHighlight: false),
        Fiber(id: 4, x: 0.24, y: 0.36, width: 0.40, thickness: 0.50, rotation: 3, opacity: 0.06, isHighlight: false),
        Fiber(id: 5, x: 0.57, y: 0.44, width: 0.58, thickness: 0.55, rotation: -1, opacity: 0.07, isHighlight: true),
        Fiber(id: 6, x: 0.20, y: 0.52, width: 0.34, thickness: 0.45, rotation: -4, opacity: 0.06, isHighlight: true),
        Fiber(id: 7, x: 0.78, y: 0.59, width: 0.44, thickness: 0.50, rotation: 2, opacity: 0.05, isHighlight: false),
        Fiber(id: 8, x: 0.36, y: 0.67, width: 0.56, thickness: 0.55, rotation: -1, opacity: 0.06, isHighlight: false),
        Fiber(id: 9, x: 0.64, y: 0.76, width: 0.36, thickness: 0.45, rotation: 3, opacity: 0.07, isHighlight: true),
        Fiber(id: 10, x: 0.18, y: 0.85, width: 0.48, thickness: 0.50, rotation: 1, opacity: 0.05, isHighlight: false),
        Fiber(id: 11, x: 0.52, y: 0.91, width: 0.52, thickness: 0.45, rotation: -2, opacity: 0.06, isHighlight: true)
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
        .opacity(0.55)
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
                        .foregroundStyle(Color.black.opacity(0.88))
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 24)
                        .offset(y: -6)

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
                                        .padding(StickyNoteCardLayout.outerPadding)
                                        .frame(maxWidth: .infinity, alignment: .top)
                                    }
                                }
                                .refreshable {
                                    await store.syncNow()
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
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                let id = store.createNote()
                                beginEditing(noteID: id)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 26, weight: .regular))
                                    .foregroundStyle(Color.black.opacity(0.92))
                                    .frame(width: 54, height: 54)
                                    .background {
                                        Circle()
                                            .fill(Color(.systemBackground).opacity(0.96))
                                            .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 8)
                                            .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
                                    }
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
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
