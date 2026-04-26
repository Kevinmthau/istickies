import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum StickyTextEditorSync {
    static func shouldApplyProgrammaticUpdate(
        currentText: String,
        incomingText: String,
        isEditorActive: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        guard currentText != incomingText else { return false }
        guard !isEditorActive, !hasMarkedText else { return false }
        return true
    }

    static func clampedSelection(_ selection: NSRange, utf16Count: Int) -> NSRange {
        let location = min(selection.location, utf16Count)
        let maxLength = max(utf16Count - location, 0)
        let length = min(selection.length, maxLength)
        return NSRange(location: location, length: length)
    }
}

enum StickyTextEditorLayout {
    static func centeredVerticalInset(
        availableHeight: CGFloat,
        contentHeight: CGFloat,
        minimumVerticalInset: CGFloat
    ) -> CGFloat {
        let clampedAvailableHeight = max(availableHeight, 0)
        let clampedContentHeight = max(contentHeight, 0)
        let minimumRequiredHeight = (minimumVerticalInset * 2) + clampedContentHeight

        guard clampedAvailableHeight > minimumRequiredHeight else {
            return minimumVerticalInset
        }

        return minimumVerticalInset + ((clampedAvailableHeight - minimumRequiredHeight) / 2)
    }
}

enum StickyNoteTypography {
    static let bodySize: CGFloat = 18
    static let editorSize: CGFloat = 19

    private static let handwrittenFontNames = [
        "Noteworthy-Light",
        "MarkerFelt-Thin",
        "ChalkboardSE-Regular",
        "BradleyHandITCTT-Bold"
    ]

#if os(macOS)
    private static let handwrittenFontName: String = {
        handwrittenFontNames.first { NSFont(name: $0, size: editorSize) != nil }
            ?? NSFont.systemFont(ofSize: editorSize).fontName
    }()

    static let bodyFont: Font = .custom(handwrittenFontName, size: bodySize, relativeTo: .body)
    static let editorFont: NSFont = NSFont(name: handwrittenFontName, size: editorSize)
        ?? .systemFont(ofSize: editorSize)
#elseif os(iOS)
    private static let handwrittenFontName: String = {
        handwrittenFontNames.first { UIFont(name: $0, size: editorSize) != nil }
            ?? UIFont.systemFont(ofSize: editorSize).fontName
    }()

    static let bodyFont: Font = .custom(handwrittenFontName, size: bodySize, relativeTo: .body)
    static let editorFont: UIFont = {
        let font = UIFont(name: handwrittenFontName, size: editorSize)
            ?? .systemFont(ofSize: editorSize)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
    }()
#endif
}

struct StickyNoteEditor: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: StickyNotesStore
    @StateObject private var draftSession = NoteDraftSession()

    let noteID: String
    let autoFocusOnAppear: Bool

    init(noteID: String, autoFocusOnAppear: Bool = false) {
        self.noteID = noteID
        self.autoFocusOnAppear = autoFocusOnAppear
    }

    var body: some View {
        if let note = store.note(withID: noteID) {
            configuredEditor(for: note)
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "note.text")
        }
    }

    @ViewBuilder
    private func editor(for note: StickyNote) -> some View {
#if os(macOS)
        MacStickyTextView(text: draftContentBinding)
            .padding(14)
#else
        IOSStickyTextView(
            text: draftContentBinding,
            shouldAutoFocus: autoFocusOnAppear
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
    }

    @ViewBuilder
    private func configuredEditor(for note: StickyNote) -> some View {
        editor(for: note)
            .onAppear {
                configureDraftSession(with: note)
            }
            .onChange(of: noteID) { _, _ in
                guard let latestNote = store.note(withID: noteID) else { return }
                configureDraftSession(with: latestNote, force: true)
            }
            .onChange(of: note.content) { _, newValue in
                draftSession.handlePersistedContentChange(newValue)
            }
            .onChange(of: scenePhase) { _, newValue in
                if newValue != .active {
                    draftSession.flush()
                }
            }
#if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .stickyNotesWillTerminate)) { _ in
                draftSession.flush()
            }
#endif
            .onDisappear {
                draftSession.flush()
            }
    }

    private var draftContentBinding: Binding<String> {
        Binding(
            get: { draftSession.draftContent },
            set: { draftSession.updateDraftContent($0) }
        )
    }

    private func configureDraftSession(with note: StickyNote, force: Bool = false) {
        let store = self.store
        let currentNoteID = noteID

        draftSession.configure(
            noteID: currentNoteID,
            initialContent: note.content,
            force: force,
            readPersistedContent: {
                store.note(withID: currentNoteID)?.content
            },
            persistDraftContent: { content, expectedBaseContent in
                store.updateContent(
                    id: currentNoteID,
                    content: content,
                    expectedBaseContent: expectedBaseContent
                )
            }
        )
    }
}

struct NoteEditorView: View {
    @EnvironmentObject private var store: StickyNotesStore

    let noteID: String
    let autoFocusOnAppear: Bool

    init(noteID: String, autoFocusOnAppear: Bool = false) {
        self.noteID = noteID
        self.autoFocusOnAppear = autoFocusOnAppear
    }

    var body: some View {
        if let note = store.note(withID: noteID) {
#if os(macOS)
            StickyNoteEditor(noteID: noteID, autoFocusOnAppear: autoFocusOnAppear)
                .background(note.color.tint)
#else
            GeometryReader { proxy in
                ZStack {
                    Color(.systemGroupedBackground)
                        .ignoresSafeArea()

                    VStack {
                        StickyNoteCardChrome(color: note.color.tint) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Spacer()

                                    Text(note.lastModified.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                StickyNoteEditor(
                                    noteID: noteID,
                                    autoFocusOnAppear: autoFocusOnAppear
                                )
                            }
                        }
                        .frame(
                            width: StickyNoteCardLayout.cardWidth(for: proxy.size.width),
                            height: StickyNoteCardLayout.height
                        )

                        Spacer(minLength: 0)
                    }
                    .padding(.top, StickyNoteCardLayout.outerPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .navigationTitle(note.title)
            .navigationBarTitleDisplayMode(.inline)
#endif
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "note.text")
        }
    }
}

#if os(macOS)
private struct MacStickyTextView: NSViewRepresentable {
    @Binding var text: String

    private static let minimumVerticalInset: CGFloat = 18

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = StickyNoteTypography.editorFont
        textView.textColor = .black
        textView.insertionPointColor = .black
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: Self.minimumVerticalInset)
        textView.string = text

        if let textContainer = textView.textContainer {
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textContainer.widthTracksTextView = true
        }

        scrollView.documentView = textView
        Self.updateStickyTextInsets(in: scrollView, textView: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        guard textView.string != text else {
            context.coordinator.pendingProgrammaticText = nil
            Self.updateStickyTextInsets(in: scrollView, textView: textView)
            return
        }

        let isFirstResponder = textView.window?.firstResponder === textView
        let hasMarkedText = textView.hasMarkedText()
        guard StickyTextEditorSync.shouldApplyProgrammaticUpdate(
            currentText: textView.string,
            incomingText: text,
            isEditorActive: isFirstResponder,
            hasMarkedText: hasMarkedText
        ) else {
            context.coordinator.pendingProgrammaticText = text
            Self.updateStickyTextInsets(in: scrollView, textView: textView)
            return
        }

        context.coordinator.applyProgrammaticText(text, to: textView)
        Self.updateStickyTextInsets(in: scrollView, textView: textView)
    }

    private static func updateStickyTextInsets(in scrollView: NSScrollView, textView: NSTextView) {
        guard scrollView.contentView.bounds.height > 0 else { return }
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let glyphHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        let fontHeight = textView.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 0
        let contentHeight = max(glyphHeight, fontHeight)
        let verticalInset = StickyTextEditorLayout.centeredVerticalInset(
            availableHeight: scrollView.contentView.bounds.height,
            contentHeight: contentHeight,
            minimumVerticalInset: Self.minimumVerticalInset
        )
        let updatedInset = NSSize(width: 0, height: verticalInset)

        if textView.textContainerInset != updatedInset {
            textView.textContainerInset = updatedInset
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        var isApplyingProgrammaticUpdate = false
        var pendingProgrammaticText: String?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingProgrammaticUpdate else { return }
            if pendingProgrammaticText == textView.string {
                pendingProgrammaticText = nil
            }
            if let scrollView = textView.enclosingScrollView {
                MacStickyTextView.updateStickyTextInsets(in: scrollView, textView: textView)
            }
            text = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            applyPendingProgrammaticTextIfNeeded(to: textView)
        }

        func applyProgrammaticText(_ newText: String, to textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            isApplyingProgrammaticUpdate = true
            textView.string = newText
            textView.setSelectedRange(
                StickyTextEditorSync.clampedSelection(
                    selectedRange,
                    utf16Count: newText.utf16.count
                )
            )
            isApplyingProgrammaticUpdate = false
            pendingProgrammaticText = nil
            text = newText
            if let scrollView = textView.enclosingScrollView {
                MacStickyTextView.updateStickyTextInsets(in: scrollView, textView: textView)
            }
        }

        private func applyPendingProgrammaticTextIfNeeded(to textView: NSTextView) {
            guard let pendingProgrammaticText else { return }
            guard textView.window?.firstResponder !== textView else { return }
            guard !textView.hasMarkedText() else { return }

            if textView.string == pendingProgrammaticText {
                self.pendingProgrammaticText = nil
                return
            }

            applyProgrammaticText(pendingProgrammaticText, to: textView)
        }
    }
}
#elseif os(iOS)
private final class CenteredStickyTextView: UITextView {
    static let minimumVerticalInset: CGFloat = 18
    static let horizontalInset: CGFloat = 16

    override func layoutSubviews() {
        super.layoutSubviews()
        updateStickyTextInsets()
    }

    func updateStickyTextInsets() {
        guard bounds.height > 0 else { return }

        layoutManager.ensureLayout(for: textContainer)
        let glyphHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        let contentHeight = max(glyphHeight, font?.lineHeight ?? 0)
        let verticalInset = StickyTextEditorLayout.centeredVerticalInset(
            availableHeight: bounds.height,
            contentHeight: contentHeight,
            minimumVerticalInset: Self.minimumVerticalInset
        )
        let updatedInsets = UIEdgeInsets(
            top: verticalInset,
            left: Self.horizontalInset,
            bottom: verticalInset,
            right: Self.horizontalInset
        )

        if textContainerInset != updatedInsets {
            textContainerInset = updatedInsets
        }

        let centeredContentHeight = contentHeight + (verticalInset * 2)
        if centeredContentHeight <= bounds.height + 1,
           !isTracking,
           !isDragging,
           !isDecelerating {
            setContentOffset(.zero, animated: false)
        }
    }
}

private struct IOSStickyTextView: UIViewRepresentable {
    @Binding var text: String

    let shouldAutoFocus: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = CenteredStickyTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = StickyNoteTypography.editorFont
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .black
        textView.text = text
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .yes
        textView.textContainer.lineFragmentPadding = 0
        textView.updateStickyTextInsets()
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard textView.text != text else {
            context.coordinator.pendingProgrammaticText = nil
            (textView as? CenteredStickyTextView)?.updateStickyTextInsets()
            applyAutoFocusIfNeeded(to: textView, context: context)
            return
        }

        let hasMarkedText = textView.markedTextRange != nil
        guard StickyTextEditorSync.shouldApplyProgrammaticUpdate(
            currentText: textView.text,
            incomingText: text,
            isEditorActive: context.coordinator.isEditing || textView.isFirstResponder,
            hasMarkedText: hasMarkedText
        ) else {
            context.coordinator.pendingProgrammaticText = text
            (textView as? CenteredStickyTextView)?.updateStickyTextInsets()
            applyAutoFocusIfNeeded(to: textView, context: context)
            return
        }

        context.coordinator.applyProgrammaticText(text, to: textView)
        (textView as? CenteredStickyTextView)?.updateStickyTextInsets()
        applyAutoFocusIfNeeded(to: textView, context: context)
    }

    private func applyAutoFocusIfNeeded(to textView: UITextView, context: Context) {
        guard shouldAutoFocus, !context.coordinator.didAutoFocus else { return }
        DispatchQueue.main.async {
            guard textView.window != nil else { return }
            guard !context.coordinator.didAutoFocus else { return }
            context.coordinator.didAutoFocus = true
            textView.becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String

        var didAutoFocus = false
        var isEditing = false
        var isApplyingProgrammaticUpdate = false
        var pendingProgrammaticText: String?

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            if pendingProgrammaticText == textView.text {
                pendingProgrammaticText = nil
            }
            (textView as? CenteredStickyTextView)?.updateStickyTextInsets()
            text = textView.text
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            applyPendingProgrammaticTextIfNeeded(to: textView)
        }

        func applyProgrammaticText(_ newText: String, to textView: UITextView) {
            let selectedRange = textView.selectedRange
            isApplyingProgrammaticUpdate = true
            textView.text = newText
            textView.selectedRange = StickyTextEditorSync.clampedSelection(
                selectedRange,
                utf16Count: newText.utf16.count
            )
            (textView as? CenteredStickyTextView)?.updateStickyTextInsets()
            isApplyingProgrammaticUpdate = false
            pendingProgrammaticText = nil
            text = newText
        }

        private func applyPendingProgrammaticTextIfNeeded(to textView: UITextView) {
            guard let pendingProgrammaticText else { return }
            guard !isEditing else { return }
            guard textView.markedTextRange == nil else { return }

            if textView.text == pendingProgrammaticText {
                self.pendingProgrammaticText = nil
                return
            }

            applyProgrammaticText(pendingProgrammaticText, to: textView)
        }
    }
}
#endif
