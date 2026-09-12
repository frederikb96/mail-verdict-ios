import MailVerdictKit
import SwiftUI

/// The mail list's one row shape — UX design §2.2's anatomy, shared by the list (S1) and search
/// (S5) so the two can never drift into different-looking rows for the same data. Every row
/// reserves the same four text lines regardless of content, which is what makes scroll-anchor
/// arithmetic exact (the scrolling skill's own rule); this view renders `MVMailRowData` exactly
/// as given and computes nothing about layout height itself — that is the list controller's job,
/// from `UIFontMetrics` against the current Dynamic Type size.
struct MailRowView: View {
    let data: MVMailRowData

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            unreadDotColumn
            AvatarView(
                identity: data.avatarIdentity, displayName: data.senderName, photoURL: data.avatarPhotoURL,
                unifiedAccountEmoji: data.unifiedAccountEmoji
            )
            .padding(.trailing, 12)
            content
        }
        .padding(.vertical, 8)
    }

    private var unreadDotColumn: some View {
        VStack {
            Circle()
                .fill(data.isUnread ? MVPalette.unreadDot : .clear)
                .frame(width: 8, height: 8)
            Spacer(minLength: 0)
        }
        .frame(width: 12)
        .padding(.top, 6)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            senderLine
            subjectLine
            previewLines
        }
    }

    private var senderLine: some View {
        HStack(spacing: 4) {
            Text(data.senderName)
                .font(MVTypography.listSenderFont(isUnread: data.isUnread))
                .lineLimit(1)
            if data.pendingSync {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 4)
            Text(data.dateText)
                .font(.subheadline)
                .foregroundStyle(MVTypography.listDateColor(isUnread: data.isUnread))
            Image(systemName: MVSymbols.disclosureChevron)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var subjectLine: some View {
        HStack(spacing: 4) {
            if let subject = data.subject {
                Text(subject)
                    .font(MVTypography.listSubjectFont(isUnread: data.isUnread))
                    .foregroundStyle(MVTypography.listSubjectColor(isUnread: data.isUnread))
                    .lineLimit(1)
            }
            if let threadCount = data.threadCount, threadCount > 1 {
                Chip(text: "\(threadCount)")
            }
            if data.isAnswered {
                Image(systemName: MVSymbols.answeredMark).font(.caption2).foregroundStyle(.secondary)
            }
            if data.hasAttachments {
                Image(systemName: MVSymbols.attachmentMark).font(.caption2).foregroundStyle(.secondary)
            }
            if data.verdictIsSpam {
                Image(systemName: MVSymbols.spamMark).font(.caption2).foregroundStyle(MVPalette.spamMark)
            }
            if data.isStarred {
                Image(systemName: MVSymbols.starFilled).font(.caption2).foregroundStyle(MVPalette.star)
            }
            Spacer(minLength: 0)
            if let accountChip = data.accountChip {
                Chip(text: accountChip)
            }
        }
    }

    /// An ordinary row wraps the snippet across both preview lines; a search result shows its
    /// own single-line `line3` ("To: …") above a single-line snippet instead.
    @ViewBuilder
    private var previewLines: some View {
        if let line3 = data.line3 {
            Text(line3).font(MVTypography.listPreview).foregroundStyle(.secondary).lineLimit(1)
            snippetText.font(MVTypography.listPreview).foregroundStyle(.secondary).lineLimit(1)
        } else {
            snippetText.font(MVTypography.listPreview).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var snippetText: Text {
        data.line4.reduce(Text("")) { result, segment in
            result + (segment.isBold ? Text(segment.text).bold() : Text(segment.text))
        }
    }
}
