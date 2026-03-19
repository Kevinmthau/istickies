import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if os(macOS)
enum MacStickyTextViewSync {
    static func shouldApplyProgrammaticUpdate(
        currentText: String,
        incomingText: String,
        isFirstResponder: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        guard currentText != incomingText else { return false }
        guard !isFirstResponder, !hasMarkedText else { return false }
        return true
    }

    static func clampedSelection(_ selection: NSRange, utf16Count: Int) -> NSRange {
        let location = min(selection.location, utf16Count)
        let maxLength = max(utf16Count - location, 0)
        let length = min(selection.length, maxLength)
        return NSRange(location: location, length: length)
    }
}
#endif

struct NoteEditorView: View {
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
            .background(StickyNoteColor.yellow.tint)
#if os(iOS)
            .navigationTitle(note.title)
            .navigationBarTitleDisplayMode(.inline)
#endif
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "note.text")
        }
    }

    @ViewBuilder
    private func editor(for note: StickyNote) -> some View {
#if os(macOS)
        MacStickyTextView(text: draftContentBinding)
            .padding(14)
            .background(StickyNoteColor.yellow.tint)
#else
        VStack(spacing: 0) {
            HStack {
                Spacer()

                Text(note.lastModified.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(StickyNoteColor.yellow.tint.opacity(0.85))

            IOSStickyTextView(
                text: draftContentBinding,
                shouldAutoFocus: autoFocusOnAppear
            )
                .background(StickyNoteColor.yellow.tint)
        }
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
            persistDraftContent: { content in
                store.updateContent(id: currentNoteID, content: content)
            }
        )
    }
}

#if os(macOS)
private struct MacStickyTextView: NSViewRepresentable {
    @Binding var text: String

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
        textView.font = .systemFont(ofSize: 18)
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.string = text

        if let textContainer = textView.textContainer {
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textContainer.widthTracksTextView = true
        }

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        guard textView.string != text else {
            context.coordinator.pendingProgrammaticText = nil
            return
        }

        let isFirstResponder = textView.window?.firstResponder === textView
        let hasMarkedText = textView.hasMarkedText()
        guard MacStickyTextViewSync.shouldApplyProgrammaticUpdate(
            currentText: textView.string,
            incomingText: text,
            isFirstResponder: isFirstResponder,
            hasMarkedText: hasMarkedText
        ) else {
            context.coordinator.pendingProgrammaticText = text
            return
        }

        context.coordinator.applyProgrammaticText(text, to: textView)
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
                MacStickyTextViewSync.clampedSelection(
                    selectedRange,
                    utf16Count: newText.utf16.count
                )
            )
            isApplyingProgrammaticUpdate = false
            pendingProgrammaticText = nil
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
private struct IOSStickyTextView: UIViewRepresentable {
    @Binding var text: String

    let shouldAutoFocus: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = .label
        textView.text = text
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .yes
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        textView.textContainer.lineFragmentPadding = 0
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            let priorSelection = textView.selectedRange
            context.coordinator.isApplyingProgrammaticUpdate = true
            textView.text = text
            textView.selectedRange = clampedSelection(priorSelection, utf16Count: text.utf16.count)
            context.coordinator.isApplyingProgrammaticUpdate = false
        }

        guard shouldAutoFocus, !context.coordinator.didAutoFocus else { return }
        DispatchQueue.main.async {
            guard textView.window != nil else { return }
            guard !context.coordinator.didAutoFocus else { return }
            context.coordinator.didAutoFocus = true
            textView.becomeFirstResponder()
        }
    }

    private func clampedSelection(_ selection: NSRange, utf16Count: Int) -> NSRange {
        let location = min(selection.location, utf16Count)
        let maxLength = max(utf16Count - location, 0)
        let length = min(selection.length, maxLength)
        return NSRange(location: location, length: length)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String

        var didAutoFocus = false
        var isApplyingProgrammaticUpdate = false

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            text = textView.text
        }
    }
}
#endif
