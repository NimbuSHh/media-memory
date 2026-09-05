import MediaMemoryCore
import SwiftUI

/// 侧栏底部的媒体库状态面板。
///
/// 三层信息，计数一律以"媒体（个）"为单位，分母恒为媒体总数：
/// 1. 总进度：分色桶条 + 图例（已完成/处理中/待处理/失败），行尾是
///    处理总开关（⏸/▶），一次性启停内容分片、建库与描述三条车道；
/// 2. 三阶段漏斗：内容分片 → 建库 → 描述，各显示"多少媒体走完了这一步"；
/// 3. 活动行：一行"正在做什么 / 为什么停着"，其下是数秒后自动消失的操作回执。
///
/// 片段级（job 条数）进度是车道内部视角，不进面板——只出现在活动行文案
/// 与失败明细弹窗。数据源为 `pipelineProgress` 与 `videoQueue`，同一趟
/// 汇总算出，面板上的数字不会来自不同时刻的库状态。
struct LibraryStatusPanel: View {
    @ObservedObject var model: AppModel

    @State private var showFailureList = false
    @State private var showBackgroundWarnings = false

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: 10) {
                if model.videoQueue.total > 0 {
                    heroSection
                    Divider()
                    stageSection
                    Divider()
                }
                activitySection
                if !model.backgroundWarnings.isEmpty {
                    warningRow
                }
                if model.staleDescriptionCount > 0 {
                    staleRow
                }
            }
            .padding(12)
            .background(.bar)
            .popover(isPresented: $showFailureList) {
                failureListPopover
            }
            .popover(isPresented: $showBackgroundWarnings) {
                backgroundWarningPopover
            }
        }
    }

    /// 没有媒体、没有活动也没有回执时整块让位（空库静默，不留一条空栏）。
    private var isVisible: Bool {
        model.videoQueue.total > 0
            || model.currentActivity != nil
            || model.transientNotice != nil
    }

    // MARK: 总进度

    private var heroSection: some View {
        let queue = model.videoQueue
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("已完成 \(queue.completed)/\(queue.total)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Text(percentText(queue.completedFraction))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                processingSwitch
            }
            bucketBar
            legend
        }
    }

    // MARK: 处理总开关

    /// 唯一的启停控件：运行中给 ⏸，停着且有排队任务给 ▶；无事可做
    /// （全部完成，或只剩失败任务）时不占位——失败重试入口在失败明细弹窗。
    @ViewBuilder
    private var processingSwitch: some View {
        if model.isEvidenceIndexing || model.isDescriptionIndexing {
            controlButton(icon: "pause.circle", help: "暂停处理（内容分片、建库、描述一起停）") {
                model.pauseProcessing()
            }
        } else if model.segmentationProgress.pending > 0
            || model.indexingProgress.pending > 0
            || model.describeProgress.pending > 0 {
            controlButton(icon: "play.circle", help: "开始处理（内容分片、建库、描述一起跑）") {
                model.startProcessing()
            }
        }
    }

    private var bucketBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                bucketSegment(color: .green, count: model.videoQueue.completed, fullWidth: proxy.size.width)
                bucketSegment(color: .blue, count: model.videoQueue.inProgress, fullWidth: proxy.size.width)
                bucketSegment(color: .orange, count: model.videoQueue.failed, fullWidth: proxy.size.width)
                bucketSegment(color: .gray, count: model.pendingMediaCount, fullWidth: proxy.size.width)
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }

    private func bucketSegment(color: Color, count: Int, fullWidth: CGFloat) -> some View {
        let total = model.videoQueue.total
        let fraction = total > 0 ? Double(count) / Double(total) : 0
        return Rectangle()
            .fill(color)
            .opacity(count > 0 ? 1 : 0)
            .frame(width: fullWidth * fraction)
    }

    private var legend: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
            ],
            spacing: 3
        ) {
            legendItem(color: .green, count: model.videoQueue.completed, label: "已完成")
            legendItem(color: .blue, count: model.videoQueue.inProgress, label: "处理中")
            legendItem(color: .gray, count: model.pendingMediaCount, label: "待处理")
            failureLegendItem(count: model.videoQueue.failed)
        }
        .font(.caption2)
    }

    private func legendItem(color: Color, count: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// 失败图例即失败明细入口：媒体口径的失败数在面板上只有一个，
    /// 片段级的明细收进弹窗。
    @ViewBuilder
    private func failureLegendItem(count: Int) -> some View {
        if count > 0 {
            Button {
                showFailureList = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    Text("失败 \(count)").monospacedDigit()
                }
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("查看失败任务明细")
        } else {
            legendItem(color: .orange, count: 0, label: "失败")
        }
    }

    private func percentText(_ fraction: Double) -> String {
        let percent = fraction * 100
        return percent >= 10 || percent == 0
            ? String(format: "%.0f%%", percent)
            : String(format: "%.1f%%", percent)
    }

    // MARK: 三阶段漏斗

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            stageRow(
                title: "内容分片",
                icon: "timeline.selection",
                counts: model.pipelineProgress.segmentation
            )
            stageRow(
                title: "建库",
                icon: "waveform",
                counts: model.pipelineProgress.indexing
            )
            stageRow(
                title: "描述",
                icon: "sparkles",
                counts: model.pipelineProgress.description
            )
        }
    }

    @ViewBuilder
    private func stageRow(
        title: String,
        icon: String,
        counts: LibraryPipelineStageCounts
    ) -> some View {
        let total = model.pipelineProgress.totalAssets
        let fraction = total > 0 ? Double(counts.done) / Double(total) : 0
        // 标签行 + 全宽进度条：条宽不受行尾控件有无影响，三阶段
        // 漏斗的条与计数永远纵向对齐。
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(counts.active > 0 ? Color.blue : Color.secondary)
                Text(title)
                    .font(.caption)
                if counts.failed > 0 {
                    Button {
                        showFailureList = true
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("\(counts.failed)").monospacedDigit()
                        }
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("该阶段有失败任务，点击查看明细")
                }
                Spacer(minLength: 8)
                Text("\(counts.done)/\(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            ProgressView(value: fraction)
        }
    }

    private func controlButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: 活动与回执

    @ViewBuilder
    private var activitySection: some View {
        if let activity = model.currentActivity {
            HStack(spacing: 6) {
                if activity.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(activity.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let notice = model.transientNotice {
            // 操作回执：数秒后自动消失，放在最底部避免高度跳动挤动上方内容。
            Text(notice)
                .font(.caption)
                .foregroundStyle(.tint)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var warningRow: some View {
        Button {
            showBackgroundWarnings = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                Text("后台警告 \(model.backgroundWarnings.count)").monospacedDigit()
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看后台状态与权限警告")
    }

    private var staleRow: some View {
        HStack(spacing: 6) {
            Text("\(model.staleDescriptionCount) 条描述为旧版提示词生成")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
            Spacer()
            Button("重新生成") {
                model.regenerateStaleDescriptions()
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    // MARK: 失败明细

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

    private var backgroundWarningPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("后台状态与权限警告")
                .font(.headline)
                .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.backgroundWarnings) { warning in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(warning.title).font(.callout.weight(.medium))
                                Spacer()
                                if warning.id.hasPrefix("source.") {
                                    Button("重试读取源") {
                                        model.retrySourceCircuits()
                                    }
                                    .buttonStyle(.borderless)
                                }
                                Button("清除") {
                                    model.dismissBackgroundWarning(warning)
                                }
                                .buttonStyle(.borderless)
                            }
                            Text(warning.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
            }
            .frame(width: 460, height: 280)
        }
    }
}
