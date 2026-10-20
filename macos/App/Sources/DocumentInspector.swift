import SwiftUI
import SistCore
import SistStore

/// Details of the selected document. Archives list their members; following a member (or the
/// archive holding a member) stacks up, with a way back.
struct DocumentInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchModel.self) private var search
    let hit: SearchHit?
    /// Documents reached from the selection by following archive links
    @State private var trail: [Int64] = []
    @State private var detail: DocumentDetail?
    @State private var members: [DocumentSummary] = []
    @State private var parent: DocumentSummary?
    @State private var newTag = ""

    static let memberLimit = 500

    private var currentId: Int64? { trail.last ?? hit?.id }

    var body: some View {
        Group {
            if let detail, detail.summary.id == currentId {
                content(detail)
            } else if currentId == nil {
                ContentUnavailableView("未选择文件", systemImage: "doc.text.magnifyingglass")
            } else {
                ProgressView()
            }
        }
        .task(id: hit?.id) {
            trail = []
        }
        .task(id: currentId) {
            await load()
        }
    }

    private func load() async {
        guard let id = currentId, let catalog = model.catalog else {
            detail = nil
            return
        }
        detail = try? await catalog.document(id: id)
        members = (try? await catalog.children(of: id, limit: Self.memberLimit + 1)) ?? []
        parent = nil
        if let parentId = detail?.summary.parentId {
            parent = try? await catalog.document(id: parentId)?.summary
        }
    }

    @ViewBuilder
    private func content(_ detail: DocumentDetail) -> some View {
        let document = detail.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !trail.isEmpty {
                    Button {
                        trail.removeLast()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Spacer()
                    ThumbnailView(document: document, size: 220)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.displayTitle)
                        .font(.title3.bold())
                        .textSelection(.enabled)
                    Text(document.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("打开") { model.open(document) }
                    Button("快速查看") { model.preview(document) }
                    Button("在 Finder 中显示") { document.revealInFinder() }
                }
                .controlSize(.small)

                if let parent {
                    Button {
                        trail.append(parent.id)
                    } label: {
                        if parent.category == .email {
                            Label("位于邮件 \(parent.displayTitle)", systemImage: "envelope")
                        } else {
                            Label("位于压缩包 \(parent.name)", systemImage: "archivebox")
                        }
                    }
                    .buttonStyle(.link)
                }

                if let error = detail.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !members.isEmpty {
                    GroupBox(memberTitle(detail)) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(members.prefix(Self.memberLimit)) { member in
                                MemberRow(member: member, archivePath: document.path) {
                                    trail.append(member.id)
                                }
                            }
                            if members.count > Self.memberLimit {
                                Text("只列出前 \(Self.memberLimit) 个，其余可以搜索找到")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("信息") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        infoRow("类型", document.mime ?? "未知")
                        infoRow("大小", Format.bytes(document.size))
                        infoRow("修改时间", Format.date(document.modificationDate))
                        ForEach(detail.metadata.keys.sorted(), id: \.self) { key in
                            infoRow(MetadataLabel.name(for: key), detail.metadata[key]?.description ?? "")
                        }
                        if let checksum = detail.checksum {
                            infoRow("SHA-1", checksum)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("标签") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detail.tags, id: \.self) { tag in
                            HStack {
                                Label(tag, systemImage: "tag")
                                Spacer()
                                Button {
                                    Task {
                                        await model.removeTag(tag, from: document.id)
                                        await load()
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        TextField("添加标签", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                let tag = newTag
                                newTag = ""
                                Task {
                                    await model.addTag(tag, to: document.id)
                                    await load()
                                }
                            }
                        if !document.isArchiveMember {
                            Text("与访达标签双向同步")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let content = detail.content {
                    GroupBox("内容") {
                        Text(Highlighter.highlight(content, terms: search.highlightTerms).attributed)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
    }

    private func memberTitle(_ detail: DocumentDetail) -> String {
        var count: Int64?
        if case .int(let value)? = detail.metadata[MetaKey.archiveMembers] {
            count = value
        }
        if detail.summary.category == .email {
            // A mailbox counts its messages; a message has attachments
            return count.map { "邮件（\($0) 封）" } ?? "附件"
        }
        return count.map { "压缩包内容（\($0) 个文件）" } ?? "压缩包内容"
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}

private struct MemberRow: View {
    @Environment(AppModel.self) private var model
    let member: DocumentSummary
    let archivePath: String
    let select: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: member.category.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(innerPath)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(Format.bytes(member.size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(member) }
        .onTapGesture(perform: select)
        .contextMenu {
            Button("打开") { model.open(member) }
            Button("快速查看") { model.preview(member) }
            Button("查看详情", action: select)
        }
        .help(member.path)
    }

    /// The path inside the archive
    private var innerPath: String {
        let prefix = archivePath + "#/"
        return member.path.hasPrefix(prefix) ? String(member.path.dropFirst(prefix.count)) : member.name
    }
}
