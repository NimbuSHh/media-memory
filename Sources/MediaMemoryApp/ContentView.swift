@preconcurrency import AppKit
import AVKit
import ImageIO
import MediaMemoryCore
import SwiftUI

struct ContentView: View {
    private enum FocusedField: Hashable {
        case search
    }

    @ObservedObject var model: AppModel
    @State private var pendingRootRemoval: LibraryRootRecord?
    @State private var pendingAssetRemoval: MediaAssetRecord?
    @State private var selectedSegmentID: String?
    @State private var showFailureList = false
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            searchAndAssets
        } detail: {
            assetDetail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_060, minHeight: 680)
        .toolbar {
            ToolbarItemGroup {
                Button(action: chooseMedia) {
                    Label("添加目录或视频", systemImage: "folder.badge.plus")
                }
                .disabled(model.startupPhase != .ready || model.isLibraryBusy)
                if model.isScanning {
                    Button(action: model.cancelScan) {
                        Label("停止扫描", systemImage: "stop.fill")
                    }
                }
                Button(action: model.openSettings) {
                    Label("模型设置", systemImage: "gearshape")
                }
                .disabled(model.startupPhase != .ready)
            }
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            ModelSettingsView(model: model)
        }
        .alert(
            "Media Memory",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            ),
            actions: {
                Button("好", role: .cancel, action: model.clearError)
            },
            message: {
                Text(model.errorMessage ?? "未知错误")
            }
        )
        .confirmationDialog(
            "从媒体库移除",
            isPresented: Binding(
                get: { pendingRootRemoval != nil },
                set: { if !$0 { pendingRootRemoval = nil } }
            ),
            presenting: pendingRootRemoval
        ) { root in
            Button("移除“\(root.name)”", role: .destructive) {
                model.removeRoot(root)
                pendingRootRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRootRemoval = nil }
        } message: { root in
            Text(root.kind == .directory
                ? "将删除该目录下全部视频的记录、识别结果、向量与描述缓存；源文件不会被改动，重新添加可完整重建。"
                : "将删除该视频的记录、识别结果、向量与描述缓存；源文件不会被改动，重新添加可完整重建。")
        }
        .confirmationDialog(
            "从媒体库移除该视频",
            isPresented: Binding(
                get: { pendingAssetRemoval != nil },
                set: { if !$0 { pendingAssetRemoval = nil } }
            ),
            presenting: pendingAssetRemoval
        ) { asset in
            Button("移除“\(asset.filename)”", role: .destructive) {
                model.removeAsset(asset)
                pendingAssetRemoval = nil
            }
            Button("取消", role: .cancel) { pendingAssetRemoval = nil }
        } message: { _ in
            Text("将删除该视频的识别结果、向量与描述缓存，并在后续扫描中保持排除；源文件不会被改动。")
        }
    }

    private var sidebar: some View {
        List(selection: $model.selectedRootID) {
            Section("媒体库") {
                Label("全部视频", systemImage: "rectangle.stack")
                    .tag(String?.none)
                ForEach(model.roots) { root in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            root.name,
                            systemImage: root.kind == .directory
                                ? "folder" : "doc.movie"
                        )
                        if let lastScanAt = root.lastScanAt {
                            Text("扫描于 \(lastScanAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(root.id))
                    .contextMenu {
                        Button("重新扫描\(root.kind == .directory ? "此目录" : "此文件")") {
                            model.rescanRoot(root)
                        }
                        Divider()
                        Button("从媒体库移除", role: .destructive) {
                            pendingRootRemoval = root
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if model.videoQueue.total > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: model.videoQueue.completedFraction)
                        HStack(spacing: 6) {
                            Text("视频 \(model.videoQueue.completed)/\(model.videoQueue.total)")
                            if model.videoQueue.inProgress > 0 {
                                Text("· 处理中 \(model.videoQueue.inProgress)")
                                    .foregroundStyle(.blue)
                            }
                            if model.videoQueue.waiting > 0 {
                                Text("· 待处理 \(model.videoQueue.waiting)")
                                    .foregroundStyle(.secondary)
                            }
                            if model.videoQueue.failed > 0 {
                                Text("· 失败 \(model.videoQueue.failed)")
                                    .foregroundStyle(.orange)
                            }
                            if model.videoQueue.notStarted > 0 {
                                Text("· 未开始 \(model.videoQueue.notStarted)")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .font(.caption)
                    }
                }
                if model.indexingProgress.total > 0 {
                    laneProgress(
                        title: "建库",
                        progress: model.indexingProgress,
                        systemImage: "waveform"
                    )
                }
                if model.segmentationProgress.total > 0 {
                    laneProgress(
                        title: "内容分片",
                        progress: model.segmentationProgress,
                        systemImage: "timeline.selection"
                    )
                }
                if model.describeProgress.total > 0 {
                    laneProgress(
                        title: "描述",
                        progress: model.describeProgress,
                        systemImage: "sparkles"
                    )
                }
                HStack(spacing: 12) {
                    if model.isEvidenceIndexing {
                        Button("暂停建库", action: model.pauseEvidenceProcessing)
                    } else if model.segmentationProgress.pending > 0
                                || model.indexingProgress.pending > 0 {
                        Button("继续建库", action: model.startEvidenceProcessing)
                    }
                    if model.isDescriptionIndexing {
                        Button("暂停描述", action: model.pauseDescriptionProcessing)
                    } else if model.describeProgress.pending > 0 {
                        Button("继续描述", action: model.startDescriptionProcessing)
                    }
                    if !model.failureSummaries.isEmpty {
                        Button {
                            showFailureList = true
                        } label: {
                            Label("失败 \(model.failureSummaries.count)", systemImage: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.orange)
                        .popover(isPresented: $showFailureList) {
                            failureListPopover
                        }
                    }
                }
                .controlSize(.small)
                if model.staleDescriptionCount > 0 {
                    HStack(spacing: 8) {
                        Text("\(model.staleDescriptionCount) 条描述由旧版提示词/模型生成")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("重新生成旧版描述", action: model.regenerateStaleDescriptions)
                            .controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    statusLine(
                        model.statusMessage,
                        active: model.startupPhase == .loadingLocalData
                            || model.isLibraryBusy || model.isSavingSettings
                    )
                    if model.isScanning || model.scanStatusMessage != "扫描空闲" {
                        statusLine(model.scanStatusMessage, active: model.isScanning)
                    }
                    if model.isEvidenceIndexing || model.segmentationProgress.total > 0
                        || model.indexingProgress.total > 0 {
                        statusLine(model.evidenceStatusMessage, active: model.isEvidenceIndexing)
                    }
                    if model.isDescriptionIndexing || model.describeProgress.total > 0 {
                        statusLine(model.descriptionStatusMessage, active: model.isDescriptionIndexing)
                    }
                    if model.isSearching || !model.searchStatusMessage.isEmpty {
                        statusLine(model.searchStatusMessage, active: model.isSearching)
                    }
                }
            }
            .padding(12)
            .background(.bar)
        }
        .navigationTitle("Media Memory")
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
    }

    private func statusLine(_ text: String, active: Bool) -> some View {
        HStack(spacing: 8) {
            if active {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    /// 失败任务列表：每条带资产名、片段、类型与具体原因，可复制。
    private var failureListPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("失败任务（\(model.failureSummaries.count)）")
                    .font(.headline)
                Spacer()
                if model.failureSummaries.contains(where: {
                    $0.kind == JobKind.segmentAsset.rawValue
                        || $0.kind == JobKind.indexSegment.rawValue
                }) {
                    Button("重试建库") {
                        showFailureList = false
                        model.retryFailedEvidenceJobs()
                    }
                }
                if model.failureSummaries.contains(where: { $0.kind == JobKind.describeSegment.rawValue }) {
                    Button("重试描述") {
                        showFailureList = false
                        model.retryFailedDescriptionJobs()
                    }
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.failureSummaries) { failure in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(failure.assetName)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                if let ordinal = failure.segmentOrdinal {
                                    Text("片段 \(ordinal + 1)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(failure.kindName)
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.orange.opacity(0.15), in: Capsule())
                                Spacer()
                            }
                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(4)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
            .frame(width: 460, height: 320)
        }
    }

    private func laneProgress(
        title: String,
        progress: IndexingProgress,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fractionCompleted)
            HStack {
                Label("\(title) \(progress.succeeded)/\(progress.total)", systemImage: systemImage)
                if progress.failed > 0 {
                    Text("· 失败 \(progress.failed)")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .font(.caption)
        }
    }

    private var searchAndAssets: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("用一句话找回视频片段", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .search)
                    .onSubmit(submitSearch)
                if model.hasSearch {
                    Button(action: model.clearSearch) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清除搜索")
                }
                Button("搜索", action: submitSearch)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .padding(12)

            Divider()
            if model.hasSearch {
                searchResults
            } else {
                assetList
            }
        }
        .navigationTitle(model.hasSearch ? "搜索结果" : "视频（\(model.visibleAssetItems.count)）")
        .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 520)
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.isSearching && model.searchResults.isEmpty {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("正在搜索已入库片段…")
            }
        } else if model.searchResults.isEmpty {
            ContentUnavailableView(
                "没有找到片段",
                systemImage: "magnifyingglass",
                description: Text("当前会立即搜索已入库片段；后台处理中新增的片段会陆续加入结果。")
            )
        } else {
            List(model.searchResults) { result in
                searchResultRow(result)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture {
                        focusedField = nil
                        model.select(result: result)
                    }
                    .listRowBackground(
                        model.selectedResult?.id == result.id
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
            }
        }
    }

    private func submitSearch() {
        model.submitSearch()
        // 提交完成后把空格还给窗口级播放器快捷键；用户再次点击搜索框时
        // 仍可正常输入带空格的查询。
        focusedField = nil
    }

    private func searchResultRow(_ result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(result.asset.filename)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(formatTime(result.playbackStartMS))–\(formatTime(result.playbackEndMS))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if result.evidence.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    evidenceBadge("综合语义")
                    Text("片段整体含义与查询相近")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(result.evidence) { evidence in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        evidenceBadge(evidenceLabel(evidence.kind))
                        Text(evidence.text)
                            .font(.callout)
                            .lineLimit(1)
                    }
                }
            }
            searchScoreSummary(result)
        }
        .padding(.vertical, 6)
    }

    private func evidenceBadge(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.12), in: Capsule())
    }

    private func evidenceLabel(_ kind: SearchEvidenceKind) -> String {
        switch kind {
        case .visual: "画面"
        case .transcript: "语音"
        case .ocr: "文字"
        }
    }

    private func searchScoreSummary(_ result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(String(format: "综合分 %.3f", result.combinedScore))
                    .font(.callout.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                Text("字面 \(scoreText(result.literalScore))")
                Text("语义 \(scoreText(result.semanticScore))")
                Text("BM25 \(scoreText(result.bm25Score))")
            }
            .font(.caption.monospacedDigit())
            Text(
                "命中：视频描述 \(result.visualDescriptionSegmentCount) 段 · "
                    + "OCR \(result.ocrMatchCount) 条 · ASR \(result.asrMatchCount) 条 · "
                    + "候选片段 \(result.matchedSegmentCount)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func scoreText(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "—"
    }

    @ViewBuilder
    private var assetList: some View {
        if model.visibleAssetItems.isEmpty {
            ContentUnavailableView {
                Label("还没有视频", systemImage: "film.stack")
            } description: {
                Text(model.roots.isEmpty ? "添加目录或单个视频后会自动开始只读扫描。" : "点击工具栏中的“重新扫描”。")
            }
        } else {
            List {
                ForEach(model.visibleAssetItems) { item in
                    assetRow(item.asset, ordinal: item.ordinal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture { model.select(asset: item.asset) }
                        .contextMenu {
                            Button("重新建库") { model.reprocessAsset(item.asset) }
                            Button("重新生成描述") { model.regenerateAssetDescriptions(item.asset) }
                            Divider()
                            Button("从媒体库移除该视频", role: .destructive) {
                                pendingAssetRemoval = item.asset
                            }
                        }
                        .listRowBackground(
                            model.selectedAsset?.id == item.asset.id && model.selectedResult == nil
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
                }
            }
        }
    }

    private func assetRow(_ asset: MediaAssetRecord, ordinal: Int) -> some View {
        let summary = model.processingSummaries[asset.id]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(ordinal)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
                Image(systemName: assetStatusIcon(asset, summary: summary))
                    .foregroundStyle(assetStatusColor(asset, summary: summary))
                    .frame(width: 18)
                Text(asset.filename)
                    .lineLimit(1)
                Spacer()
                assetStatusBadge(asset, summary: summary)
            }
            HStack(spacing: 5) {
                Text(formatDuration(asset.durationMS))
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
                if asset.audioTrackCount == 0 { Text("· 无音轨") }
                if asset.relativePath != asset.filename {
                    Text("· \(asset.relativePath)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let summary, summary.totalSegments > 0 {
                modelStatusBadges(asset: asset, summary: summary)
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: 视频卡片状态

    private func assetStatusIcon(
        _ asset: MediaAssetRecord,
        summary: AssetProcessingSummary?
    ) -> String {
        guard asset.status == .ready else { return "exclamationmark.triangle" }
        guard let summary else { return "film" }
        if summary.failedCount > 0 { return "exclamationmark.triangle" }
        if summary.segmentationStatus == .running
            || summary.evidenceRunning || summary.describeRunning {
            return "arrow.triangle.2.circlepath"
        }
        if summary.segmentationStatus == .pending
            || summary.evidencePending > 0 || summary.describePending > 0 { return "clock" }
        guard summary.totalSegments > 0 else { return "film" }
        return "checkmark.circle"
    }

    private func assetStatusColor(
        _ asset: MediaAssetRecord,
        summary: AssetProcessingSummary?
    ) -> Color {
        guard asset.status == .ready else { return .orange }
        guard let summary else { return .accentColor }
        if summary.failedCount > 0 { return .orange }
        if summary.segmentationStatus == .running
            || summary.evidenceRunning || summary.describeRunning {
            return .blue
        }
        if summary.segmentationStatus == .pending
            || summary.evidencePending > 0 || summary.describePending > 0 { return .secondary }
        guard summary.totalSegments > 0 else { return .accentColor }
        return .green
    }

    private func assetStatusBadge(
        _ asset: MediaAssetRecord,
        summary: AssetProcessingSummary?
    ) -> some View {
        let text: String
        let color: Color
        if asset.status != .ready {
            text = asset.status == .missing ? "文件缺失" : "不可播放"
            color = .orange
        } else if let summary {
            if summary.failedCount > 0 {
                text = "失败 \(summary.failedCount)"
                color = .orange
            } else if summary.segmentationStatus == .running
                        || summary.evidenceRunning || summary.describeRunning {
                text = "处理中"
                color = .blue
            } else if summary.segmentationStatus == .pending
                        || summary.evidencePending > 0 || summary.describePending > 0 {
                text = "待处理"
                color = .secondary
            } else if summary.totalSegments > 0 {
                text = "已完成"
                color = .green
            } else {
                text = "未开始"
                color = .secondary
            }
        } else {
            text = "未开始"
            color = .secondary
        }
        return Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    /// 各模型环节的进度徽标。证据链按片段原子提交，四个小模型共享
    /// 同一“已建库片段数”，正在运行的环节高亮并带指示器。
    private func modelStatusBadges(
        asset: MediaAssetRecord,
        summary: AssetProcessingSummary
    ) -> some View {
        let active = activeModelName(summary.currentStage)
        let evidenceDone = summary.evidenceSucceeded
        let total = summary.totalSegments
        var badges: [(name: String, done: Int, active: Bool, failed: Bool)] = []
        if asset.audioTrackCount > 0 {
            badges.append(("ASR", evidenceDone, active == "ASR", summary.evidenceFailed > 0))
            badges.append(("对齐", evidenceDone, active == "对齐", false))
        }
        badges.append(("OCR", evidenceDone, active == "OCR", false))
        badges.append(("向量", evidenceDone, active == "向量", false))
        badges.append(("描述", summary.describeSucceeded, summary.describeRunning, summary.describeFailed > 0))
        return HStack(spacing: 5) {
            ForEach(badges, id: \.name) { badge in
                modelBadge(
                    name: badge.name,
                    done: badge.done,
                    total: total,
                    active: badge.active,
                    failed: badge.failed
                )
            }
        }
    }

    private func modelBadge(
        name: String,
        done: Int,
        total: Int,
        active: Bool,
        failed: Bool
    ) -> some View {
        HStack(spacing: 3) {
            if active {
                ProgressView().controlSize(.mini)
            } else if failed {
                Image(systemName: "exclamationmark")
                    .imageScale(.small)
            } else if done >= total, total > 0 {
                Image(systemName: "checkmark")
                    .imageScale(.small)
            }
            Text(total > 0 ? "\(name) \(done)/\(total)" : name)
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(badgeBackground(active: active, failed: failed, done: done, total: total), in: Capsule())
        .foregroundStyle(badgeForeground(active: active, failed: failed, done: done, total: total))
    }

    private func badgeBackground(
        active: Bool,
        failed: Bool,
        done: Int,
        total: Int
    ) -> Color {
        if active { return Color.accentColor.opacity(0.16) }
        if failed { return Color.orange.opacity(0.16) }
        if total > 0, done >= total { return Color.green.opacity(0.14) }
        return Color.gray.opacity(0.14)
    }

    private func badgeForeground(
        active: Bool,
        failed: Bool,
        done: Int,
        total: Int
    ) -> Color {
        if active { return .accentColor }
        if failed { return .orange }
        if total > 0, done >= total { return .green }
        return .secondary
    }

    private func activeModelName(_ stage: String?) -> String? {
        switch stage {
        case "audio", "asr": "ASR"
        case "alignment": "对齐"
        case "frames", "ocr": "OCR"
        case "embedding", "commit": "向量"
        default: nil
        }
    }

    @ViewBuilder
    private var assetDetail: some View {
        if let asset = model.selectedAsset {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let player = model.player {
                        NativePlayerView(player: player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .background(.black)
                            .overlay {
                                if model.isPlayerLoading {
                                    ZStack {
                                        Rectangle().fill(Color.black.opacity(0.55))
                                        HStack(spacing: 10) {
                                            ProgressView().controlSize(.small)
                                                .tint(.white)
                                            Text("正在打开远程视频…")
                                                .font(.callout)
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .allowsHitTesting(false)
                                }
                            }
                        // 空格：播放/暂停（零尺寸快捷键按钮，不影响布局）。
                        Button(action: model.togglePlayback) { EmptyView() }
                            .keyboardShortcut(.space, modifiers: [])
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .accessibilityHidden(true)
                    } else {
                        ContentUnavailableView(
                            "无法播放",
                            systemImage: "exclamationmark.triangle",
                            description: Text(model.playerError ?? asset.errorMessage ?? "该媒体当前不可播放。")
                        )
                    }

                    if let result = model.selectedResult {
                        LabeledContent(
                            "命中位置",
                            value: "\(formatTime(result.playbackStartMS))–\(formatTime(result.playbackEndMS))"
                        )
                        evidenceSection(result)
                        descriptionSection(for: result.segment.id, describeStatus: nil)
                    } else {
                        assetMetaSection(asset)
                        assetSegmentsSection(for: asset)
                    }
                }
                .padding(24)
            }
            .navigationTitle(asset.filename)
        } else {
            ContentUnavailableView(
                "选择一个视频或搜索结果",
                systemImage: "play.rectangle",
                description: Text("点击结果会直接从命中时间播放原文件。")
            )
        }
    }

    private func evidenceSection(_ result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("检索证据").font(.headline)
            if result.evidence.isEmpty {
                Text("综合语义命中；没有可直接核对的同字语音、画面文字或画面描述。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.evidence) { evidence in
                    HStack(alignment: .top, spacing: 8) {
                        Text(evidenceLabel(evidence.kind))
                            .font(.caption2.bold())
                            .frame(width: 34, alignment: .leading)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(evidence.text).textSelection(.enabled)
                            Text("\(formatTime(evidence.startMS))–\(formatTime(evidence.endMS))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let segmentID = model.selectedResult?.segment.id {
            descriptionSection(for: segmentID, describeStatus: nil)
        }
    }

    /// 描述在建库后由描述车道自动批量生成；这里只展示结果或队列状态。
    private func descriptionSection(
        for segmentID: String,
        describeStatus: JobStatus?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模型描述").font(.headline)
                Spacer()
                if describeStatus == .running {
                    ProgressView().controlSize(.small)
                }
            }
            Text("描述由 Qwen3.8 在后台生成；可观察内容用于补充画面召回，不确定项不参与检索。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let display = model.segmentDescriptions[segmentID] {
                SegmentDescriptionContent(cached: display.cached, isStale: display.isStale)
            } else {
                Text(descriptionQueueText(describeStatus))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func descriptionQueueText(_ status: JobStatus?) -> String {
        switch status {
        case .running: "正在生成描述…"
        case .pending: "描述排队中，生成后会自动出现。"
        case .failed, .cancelled: "描述生成失败，可稍后在左下角重试。"
        case .succeeded: "描述生成中…"
        case nil: "描述还在后台队列中，生成后会自动出现。"
        }
    }

    // MARK: 视频详情：媒体信息与建库产物

    private func assetMetaSection(_ asset: MediaAssetRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("媒体信息").font(.headline)
            LabeledContent("位置", value: asset.relativePath)
            LabeledContent("完整路径") {
                Text(asset.standardizedPath).textSelection(.enabled)
            }
            // 短字段双列排布，减少纵向占用；长文本保持整行。
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                LabeledContent(
                    "大小",
                    value: ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file)
                )
                LabeledContent("时长", value: formatDuration(asset.durationMS))
                LabeledContent(
                    "轨道",
                    value: "视频 \(asset.videoTrackCount) · 音频 \(asset.audioTrackCount)"
                )
                LabeledContent("状态", value: assetStatusText(asset))
                LabeledContent("修改时间", value: asset.modificationDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("最近发现", value: asset.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                if let detail = model.assetDetail {
                    LabeledContent(
                        "建库进度",
                        value: detail.segments.isEmpty
                            ? "尚未分段"
                            : "\(detail.indexedSegmentCount)/\(detail.segments.count) 片段"
                    )
                    LabeledContent(
                        "识别结果",
                        value: "\(detail.transcripts.count) 语音 · \(detail.ocr.count) 文字"
                    )
                }
            }
            if asset.audioTrackCount == 0 {
                Text("无音轨，无法语音识别")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = asset.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            LabeledContent("文件指纹") {
                Text(asset.fingerprint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func assetStatusText(_ asset: MediaAssetRecord) -> String {
        switch asset.status {
        case .ready: asset.isPlayable ? "就绪，可播放" : "可读取但当前不可播放"
        case .failed: "识别失败"
        case .missing: "文件已缺失"
        }
    }

    private func assetSegmentsSection(for asset: MediaAssetRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("片段与模型识别结果").font(.headline)
                Spacer()
                Button {
                    model.regenerateAssetDescriptions(asset)
                } label: {
                    Label("重新生成描述", systemImage: "sparkles")
                }
                .controlSize(.small)
                .help("丢弃该视频全部描述缓存并重新生成，不影响证据与索引")
                Button {
                    model.reprocessAsset(asset)
                } label: {
                    Label("重新建库", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("重跑该视频全部片段的 ASR、对齐、OCR 与向量；描述会自动重新生成")
            }
            if let detail = model.assetDetail {
                if detail.segments.isEmpty {
                    Text("该视频正在分析内容边界；完成后会生成变长语义片段。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(detail.segments) { info in
                            segmentCard(info, detail: detail)
                        }
                    }
                    if let selected = detail.segments.first(where: { $0.segment.id == selectedSegmentID }) {
                        selectedSegmentPanel(selected, detail: detail)
                    }
                }
            } else {
                ProgressView("正在读取建库结果…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: model.selectedAsset?.id) { selectedSegmentID = nil }
    }

    /// 片段卡片：关键帧胶条 + 片段号/时间 + 建库状态。点击播放并展开详情。
    private func segmentCard(
        _ info: AssetSegmentInfo,
        detail: AssetLibraryDetail
    ) -> some View {
        let isSelected = selectedSegmentID == info.segment.id
        return VStack(alignment: .leading, spacing: 6) {
            segmentFilmstrip(info, detail: detail)
            HStack(spacing: 6) {
                Text("片段 \(info.segment.ordinal + 1)")
                    .font(.callout.weight(.medium))
                Text("\(formatTime(info.segment.startMS))–\(formatTime(info.segment.endMS))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if info.isIndexed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(segmentSummaryLine(info, detail: detail))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        // 强制接受网格给定的宽度，内容（长文件名/时间文本）只截断不撑宽。
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            (isSelected ? Color.accentColor.opacity(0.10) : Color.gray.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
        .contentShape(.rect)
        .onTapGesture {
            selectedSegmentID = isSelected ? nil : info.segment.id
            model.playFromSegment(info.segment)
        }
    }

    /// 关键帧胶条：铺满卡片宽度、等分显示全部代表帧。
    @ViewBuilder
    private func segmentFilmstrip(
        _ info: AssetSegmentInfo,
        detail: AssetLibraryDetail
    ) -> some View {
        let frames = detail.framesBySegment[info.segment.id] ?? []
        if frames.isEmpty {
            Rectangle()
                .fill(.quaternary.opacity(0.6))
                .frame(height: 46)
                .overlay(
                    Image(systemName: info.isIndexed ? "photo" : "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            HStack(spacing: 1) {
                ForEach(frames.prefix(8)) { frame in
                    FrameThumbnail(url: model.frameThumbnailURL(frame))
                }
            }
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func segmentSummaryLine(
        _ info: AssetSegmentInfo,
        detail: AssetLibraryDetail
    ) -> String {
        var parts: [String] = []
        let transcriptCount = detail.transcriptsBySegment[info.segment.id]?.count ?? 0
        let ocrCount = detail.ocrBySegment[info.segment.id]?.count ?? 0
        parts.append(transcriptCount > 0 ? "语音 \(transcriptCount) 句" : "无语音")
        parts.append(ocrCount > 0 ? "文字 \(ocrCount) 条" : "无画面文字")
        if info.isIndexed {
            switch info.describeStatus {
            case .succeeded: parts.append("描述✓")
            case .running: parts.append("描述生成中")
            case .pending: parts.append("描述排队")
            case .failed, .cancelled: parts.append("描述失败")
            case nil: parts.append("描述待入队")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// 选中的片段详情：完整证据、描述与重跑入口。
    private func selectedSegmentPanel(
        _ info: AssetSegmentInfo,
        detail: AssetLibraryDetail
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(
                    "片段 \(info.segment.ordinal + 1) · \(formatTime(info.segment.startMS))–\(formatTime(info.segment.endMS))",
                    systemImage: "waveform.path"
                )
                .font(.headline)
                Spacer()
                Button {
                    model.playFromSegment(info.segment)
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                .controlSize(.small)
            }

            if let lines = detail.transcriptsBySegment[info.segment.id], !lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("语音识别（ASR）").font(.subheadline.weight(.semibold))
                        Text(timingSourceLabel(lines))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.12), in: Capsule())
                        if let language = lines.compactMap(\.language).first {
                            Text(language)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(formatTime(line.startMS))–\(formatTime(line.endMS))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 108, alignment: .leading)
                            Text(line.text)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text("该片段没有识别到语音。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let observations = detail.ocrBySegment[info.segment.id], !observations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("画面文字（OCR）").font(.subheadline.weight(.semibold))
                    ForEach(observations) { observation in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(formatTime(observation.startMS))–\(formatTime(observation.endMS))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 108, alignment: .leading)
                            Text(observation.text)
                                .textSelection(.enabled)
                            Text("\(Int(observation.confidence * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if info.isIndexed {
                descriptionSection(for: info.segment.id, describeStatus: info.describeStatus)
            }

            HStack(spacing: 12) {
                Button {
                    model.reprocessSegment(info.segment)
                } label: {
                    Label("重新处理该片段", systemImage: "arrow.clockwise")
                }
                if info.describeStatus != nil {
                    Button {
                        model.regenerateDescription(for: info.segment.id)
                    } label: {
                        Label("重新生成描述", systemImage: "sparkles")
                    }
                }
            }
            .controlSize(.small)

            Text("代表帧 \(info.frameCount) 张 · 片段 ID \(info.segment.id)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func timingSourceLabel(_ lines: [TranscriptEvidenceRecord]) -> String {
        lines.contains { $0.timingSource == "forced_alignment_sentence" }
            ? "句级时间对齐" : "ASR 块时间"
    }

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.title = "选择媒体"
        panel.message = "选择整个目录、多个视频或单个视频；Media Memory 只会读取所选内容。"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in model.addMediaItems(urls) }
        }
    }

    private func formatDuration(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "—" }
        return formatTime(milliseconds)
    }

    private func formatTime(_ milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// 原生播放器：滚轮不做快进/快退，转发给外层滚动视图。
private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    final class PlayerView: AVPlayerView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.player = player
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

/// 关键帧缩略图：基座矩形决定布局尺寸，图片仅作 overlay 视觉填充，
/// 无论图片比例如何都不可能撑破卡片；懒加载并降采样。
private struct FrameThumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.16))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay {
                if image == nil {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .clipped()
            .task(id: url) {
                guard let url, image == nil else { return }
                let loaded = await FrameThumbnailLoader.shared.image(at: url, maxPixel: 200)
                if !Task.isCancelled {
                    image = loaded.value
                }
            }
    }
}

private struct LoadedThumbnail: @unchecked Sendable {
    let value: NSImage?
}

/// Serial decoding plus a bounded cache prevents fast scrolling from launching an
/// unbounded number of blocking ImageIO jobs on Swift's cooperative executor.
private actor FrameThumbnailLoader {
    static let shared = FrameThumbnailLoader()

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    func image(at url: URL, maxPixel: Int) -> LoadedThumbnail {
        guard !Task.isCancelled else { return LoadedThumbnail(value: nil) }
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return LoadedThumbnail(value: cached)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return LoadedThumbnail(value: nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return LoadedThumbnail(value: nil) }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return LoadedThumbnail(value: image)
    }
}

/// 缓存的片段描述内容，搜索结果详情与片段列表共用。
/// 语音与画面文字不在这里展示——它们是证据，由 ASR/OCR 证据区展示。
private struct SegmentDescriptionContent: View {
    let cached: CachedSegmentDescription
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cached.description.summary)
                .font(.body)
                .textSelection(.enabled)
            if !cached.description.visibleDetails.isEmpty {
                DisclosureGroup("画面细节") {
                    bulletList(cached.description.visibleDetails)
                }
            }
            if !cached.description.uncertainty.isEmpty {
                DisclosureGroup("不确定项") {
                    bulletList(cached.description.uncertainty)
                }
            }
            HStack(spacing: 8) {
                if isStale {
                    Label("旧版提示词/模型生成，可重新生成", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                }
                Text("生成于 \(cached.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
        }
    }

    private func bulletList(_ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text("• \(value)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 5)
    }
}

private struct ModelSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("连接方式") {
                    Text("Media Memory 只要求接口兼容，不限制服务商。URL 可以指向本机或远程服务；涉及个人媒体时建议优先使用本机服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.isSettingsLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在从钥匙串读取模型密钥…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ModelEndpointEditor(
                    role: .asr,
                    draft: $model.settingsDraft.asr,
                    testState: model.modelTestState(for: .asr),
                    isAnyTestRunning: model.isTestingModels,
                    supportsLocalWorker: false,
                    testAction: { model.testModel(.asr) }
                )
                ModelEndpointEditor(
                    role: .aligner,
                    draft: $model.settingsDraft.aligner,
                    testState: model.modelTestState(for: .aligner),
                    isAnyTestRunning: model.isTestingModels,
                    supportsLocalWorker: true,
                    testAction: { model.testModel(.aligner) }
                )
                ModelEndpointEditor(
                    role: .embedding,
                    draft: $model.settingsDraft.embedding,
                    testState: model.modelTestState(for: .embedding),
                    isAnyTestRunning: model.isTestingModels,
                    supportsLocalWorker: true,
                    testAction: { model.testModel(.embedding) }
                )
                ModelEndpointEditor(
                    role: .description,
                    draft: $model.settingsDraft.description,
                    testState: model.modelTestState(for: .description),
                    isAnyTestRunning: model.isTestingModels,
                    supportsLocalWorker: false,
                    testAction: { model.testModel(.description) }
                )

                Section {
                    Text("更换 ASR、对齐或向量模型后，受影响的片段会自动重新建库；旧模型不会作为备用链路保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if usesLocalWorker {
                    DisclosureGroup("内置本地 Worker", isExpanded: $showAdvanced) {
                        TextField("Python 启动器", text: $model.settingsDraft.pythonLauncherPath)
                        TextField("本地模型目录", text: $model.settingsDraft.modelRootPath)
                        Text("这是默认本地适配器，不是服务商要求；对齐和向量也可以切换为 HTTP 服务。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.isSettingsLoading || model.isSavingSettings)
            Divider()
            HStack {
                if model.isSavingSettings {
                    ProgressView().controlSize(.small)
                    Text("正在切换模型服务…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("全部测试", action: model.testAllModels)
                    .disabled(model.isSettingsLoading || model.isSavingSettings || model.isTestingModels)
                Spacer()
                Button("取消", action: model.dismissSettings)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSavingSettings)
                Button("保存", action: model.saveSettings)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        model.isSettingsLoading
                            || model.isSavingSettings
                            || model.isTestingModels
                    )
            }
            .padding()
        }
        .frame(width: 720, height: 760)
    }

    private var usesLocalWorker: Bool {
        model.settingsDraft.aligner.transport == .localWorker
            || model.settingsDraft.embedding.transport == .localWorker
    }
}

private struct ModelEndpointEditor: View {
    let role: ModelRole
    @Binding var draft: ModelEndpointDraft
    let testState: ModelTestState
    let isAnyTestRunning: Bool
    let supportsLocalWorker: Bool
    let testAction: () -> Void

    var body: some View {
        Section {
            HStack {
                testStatus
                Spacer()
                Button("测试", action: testAction)
                    .disabled(isAnyTestRunning || testState.phase == .testing)
            }

            if supportsLocalWorker {
                Picker("接口", selection: $draft.transport) {
                    Text("HTTP 服务").tag(httpTransport)
                    Text("内置本地 Worker").tag(ModelTransport.localWorker)
                }
                .pickerStyle(.segmented)
            }

            if draft.transport.requiresEndpoint {
                TextField("完整请求 URL", text: $draft.endpointURL)
                    .textContentType(.URL)
                if usesInsecureRemoteHTTP {
                    Label(
                        "非本机 HTTP 会明文传输测试数据、媒体证据和 API key；请改用 HTTPS。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            TextField("模型名称", text: $draft.modelID)
            if draft.transport.requiresEndpoint {
                SecureField("API key（无鉴权服务可留空）", text: $draft.apiKey)
                Text("密钥只保存在 macOS 钥匙串；测试使用应用生成的音频和图片，不读取媒体库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if testState.phase == .failed {
                Text(testState.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if testState.phase == .passed {
                Text(testState.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(role.displayName)
        } footer: {
            Text(contractDescription)
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState.phase {
        case .untested:
            Label("未测试", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .testing:
            ProgressView()
                .controlSize(.small)
            Text("测试中…")
                .foregroundStyle(.secondary)
        case .passed:
            Label("可用", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("失败", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var httpTransport: ModelTransport {
        switch role {
        case .asr: .openAITranscription
        case .aligner: .mediaMemoryAlignment
        case .embedding: .mediaMemoryEmbedding
        case .description: .openAIChatCompletion
        }
    }

    private var contractDescription: String {
        switch role {
        case .asr: "OpenAI 兼容 audio/transcriptions 请求。"
        case .aligner: "HTTP 模式使用 Media Memory alignment 契约。"
        case .embedding: "HTTP 模式使用 Media Memory 多模态 embedding 契约。"
        case .description: "OpenAI 兼容 chat/completions 多模态请求。"
        }
    }

    private var usesInsecureRemoteHTTP: Bool {
        guard draft.transport.requiresEndpoint,
              let url = URL(string: draft.endpointURL),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" { return false }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4Loopback = octets.count == 4
            && octets.first == "127"
            && octets.allSatisfy { octet in
                guard let value = Int(octet) else { return false }
                return (0...255).contains(value)
            }
        return !isIPv4Loopback
    }
}
