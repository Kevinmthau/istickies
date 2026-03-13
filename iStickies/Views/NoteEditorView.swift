import SwiftUI
#if os(macOS)
import AppKit
#endif

struct NoteEditorView: View {
    @EnvironmentObject private var store: StickyNotesStore
    @State private var draftContent = ""
    @State private var hasLoadedDraft = false
#if os(macOS)
    @State private var saveTask: Task<Void, Never>?
#endif

    let noteID: String

    var body: some View {
        if let note = store.note(withID: noteID) {
            editor(for: note)
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
        MacStickyTextView(text: $draftContent)
            .padding(14)
            .background(StickyNoteColor.yellow.tint)
            .onAppear {
                syncDraft(with: note, force: !hasLoadedDraft)
            }
            .onChange(of: noteID) { _, _ in
                guard let latestNote = store.note(withID: noteID) else { return }
                syncDraft(with: latestNote, force: true)
            }
            .onChange(of: note.content) { _, newValue in
                guard newValue != draftContent else { return }
                draftContent = newValue
                hasLoadedDraft = true
            }
            .onChange(of: draftContent) { _, newValue in
                scheduleDraftPersistence()
            }
            .onReceive(NotificationCenter.default.publisher(for: .stickyNotesWillTerminate)) { _ in
                flushDraftPersistence()
            }
            .onDisappear {
                flushDraftPersistence()
            }
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

            TextEditor(text: $draftContent)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(StickyNoteColor.yellow.tint)
        }
        .onAppear {
            syncDraft(with: note, force: !hasLoadedDraft)
        }
        .onChange(of: noteID) { _, _ in
            guard let latestNote = store.note(withID: noteID) else { return }
            syncDraft(with: latestNote, force: true)
        }
        .onChange(of: note.content) { _, newValue in
            guard newValue != draftContent else { return }
            draftContent = newValue
            hasLoadedDraft = true
        }
        .onChange(of: draftContent) { _, newValue in
            persistDraftContent(newValue)
        }
#endif
    }

    private func syncDraft(with note: StickyNote, force: Bool) {
        guard force || !hasLoadedDraft else { return }
        draftContent = note.content
        hasLoadedDraft = true
    }

    private func persistDraftContent(_ content: String) {
        guard store.note(withID: noteID)?.content != content else { return }
        store.updateContent(id: noteID, content: content)
    }

#if os(macOS)
    private func scheduleDraftPersistence() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            persistDraftContent(draftContent)
        }
    }

    private func flushDraftPersistence() {
        saveTask?.cancel()
        saveTask = nil
        persistDraftContent(draftContent)
    }
#endif
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

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selectedRange)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
#endif
