import SwiftUI

struct StickyNotesLocalRecoveryView: View {
    let issue: StickyNotesLocalRecoveryIssue
    let startFresh: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(issue.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(issue.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(role: .destructive, action: startFresh) {
                Label("Start Fresh", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("StickyNotes.startFreshRecoveryButton")
        }
        .padding(28)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("StickyNotes.localRecoveryView")
    }
}

struct StickyNotesCloudIssueBanner: View {
    @ObservedObject private var statusObservation: StickyNotesStatusObservation

    let retry: () -> Void
    let dismiss: () -> Void

    init(
        statusObservation: StickyNotesStatusObservation,
        retry: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self._statusObservation = ObservedObject(wrappedValue: statusObservation)
        self.retry = retry
        self.dismiss = dismiss
    }

    var body: some View {
        if statusObservation.localRecoveryIssue == nil,
           let message = statusObservation.lastErrorMessage {
            HStack(spacing: 10) {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.secondary)

                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: retry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            }
            .padding(10)
            .accessibilityIdentifier("StickyNotes.cloudIssueBanner")
        }
    }
}
