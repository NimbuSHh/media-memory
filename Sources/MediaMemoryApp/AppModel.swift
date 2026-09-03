@preconcurrency import AVFoundation
import Combine
import Foundation
import MediaMemoryCore

struct ModelEndpointDraft: Equatable, Hashable, Sendable {
    var transport: ModelTransport
    var endpointURL = ""
    var modelID = ""
    var authentication: ModelAuthentication = .none
    var apiKey = ""
}

struct ModelSettingsDraft: Equatable, Sendable {
    var asr = ModelEndpointDraft(transport: .openAITranscription)
    var aligner = ModelEndpointDraft(transport: .localWorker)
    var embedding = ModelEndpointDraft(transport: .localWorker)
    var description = ModelEndpointDraft(transport: .openAIChatCompletion)
    var pythonLauncherPath = ""
    var modelRootPath = ""

    func endpoint(for role: ModelRole) -> ModelEndpointDraft {
        switch role {
        case .asr: asr
        case .aligner: aligner
        case .embedding: embedding
        case .description: description
        }
    }
}

enum ModelTestPhase: Equatable {
    case untested
    case testing
    case passed
    case failed
}

struct ModelTestState: Equatable {
    var phase: ModelTestPhase = .untested
    var message = "未测试"
    var draftSignature: Int?
}

struct AppBackgroundWarning: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

/// 视频队列总览：以视频为单位的处理进度。
struct VideoQueueSummary: Equatable {
    var total = 0
    var completed = 0
    var inProgress = 0
    var waiting = 0
    var failed = 0
    var notStarted = 0

    var completedFraction: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }
}

/// 侧栏路径统计：视频数、总大小、总时长，加上以视频为单位的处理进度。
/// 与 `videoQueue` 同一趟汇总产出，共享同一节流刷新节奏。
struct RootLibraryStatistics: Equatable {
    var videoCount = 0
    var totalFileSize: Int64 = 0
    var totalDurationMS: Int64 = 0
    var queue = VideoQueueSummary()
}

/// 展示用的片段描述：内容 + 两类过期标记。
/// 配置性过期（旧版 prompt/模型）只标记、手动重跑；数据性过期（证据已
/// 重新提交）由 reconcile 自动重跑，标记覆盖等待窗口。
struct DisplayedSegmentDescription: Equatable {
    let cached: CachedSegmentDescription
    let isConfigStale: Bool
    let isEvidenceStale: Bool

    var isStale: Bool { isConfigStale || isEvidenceStale }
}

enum AppStartupPhase: Equatable {
    case loadingLocalData
    case ready
    case failed
}

struct NumberedMediaAsset: Identifiable, Equatable {
    let ordinal: Int
    let asset: MediaAssetRecord

    var id: String { asset.id }
}

private struct ConfiguredServices: Sendable {
    let runtime: LocalModelRuntime
    let indexer: SegmentIndexer
    let describeQueue: DescriptionQueue
    let searchService: SearchService
    let descriptionService: DescriptionService
}

private struct PreparedPlayer: @unchecked Sendable {
    let player: AVPlayer
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var roots: [LibraryRootRecord] = []
    @Published private(set) var assets: [MediaAssetRecord] = []
    @Published private(set) var visibleAssetItems: [NumberedMediaAsset] = []
    @Published private(set) var configuration: ModelConfiguration?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlayerLoading = false
    @Published private(set) var playerError: String?
    @Published private(set) var selectedAsset: MediaAssetRecord?
    @Published private(set) var selectedResult: SearchResult?
    @Published private(set) var assetDetail: AssetLibraryDetail?
    @Published private(set) var segmentDescriptions: [String: DisplayedSegmentDescription] = [:]
    @Published private(set) var staleDescriptionCount = 0
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var indexingProgress = IndexingProgress(
        total: 0, pending: 0, running: 0, succeeded: 0, failed: 0
    )
    @Published private(set) var segmentationProgress = IndexingProgress(
        total: 0, pending: 0, running: 0, succeeded: 0, failed: 0
    )
    @Published private(set) var describeProgress = IndexingProgress(
        total: 0, pending: 0, running: 0, succeeded: 0, failed: 0
    )
    @Published private(set) var processingSummaries: [String: AssetProcessingSummary] = [:]
    @Published private(set) var videoQueue = VideoQueueSummary()
    @Published private(set) var libraryStatistics = RootLibraryStatistics()
    @Published private(set) var rootStatistics: [String: RootLibraryStatistics] = [:]
    @Published private(set) var failedJobs: [IndexJobRecord] = []
    @Published private(set) var failureSummaries: [FailedJobSummary] = []
    @Published var selectedRootID: String? {
        didSet { rebuildVisibleAssetItems() }
    }
    @Published var searchQuery = ""
    @Published var settingsDraft = ModelSettingsDraft()
    @Published private(set) var modelTestStates = Dictionary(
        uniqueKeysWithValues: ModelRole.allCases.map { ($0, ModelTestState()) }
    )
    @Published var isSettingsPresented = false
    @Published private(set) var isScanning = false
    @Published private(set) var isIndexing = false
    @Published private(set) var isSearching = false
    @Published private(set) var isLibraryBusy = false
    @Published private(set) var isSettingsLoading = false
    @Published private(set) var settingsCredentialWarning: String?
    @Published private(set) var isSavingSettings = false
    @Published private(set) var isTestingModels = false
    @Published private(set) var startupPhase = AppStartupPhase.loadingLocalData
    @Published private(set) var statusMessage = "正在读取本地数据…"
    @Published private(set) var scanStatusMessage = "扫描空闲"
    @Published private(set) var searchStatusMessage = ""
    @Published private(set) var evidenceStatusMessage = "建库空闲"
    @Published private(set) var descriptionStatusMessage = "描述空闲"
    @Published private(set) var backgroundWarnings: [AppBackgroundWarning] = []
    @Published var errorMessage: String?

    private var database: MediaDatabase?
    private var instanceLock: ApplicationInstanceLock?
    /// Dedicated WAL reader for App snapshots and search. Background/control
    /// writes use `database`, so UI reads never queue behind its actor mailbox.
    private var readDatabase: MediaDatabase?
    /// Search gets its own read actor because loading the semantic matrix can be
    /// much heavier than App snapshots and detail reads.
    private var searchDatabase: MediaDatabase?
    private var workRoot: URL?
    private var sourceCache: LocalSourceCache?
    private var segmenter: ContentSegmenter?
    private var runtime: LocalModelRuntime?
    private var indexer: SegmentIndexer?
    private var describeQueue: DescriptionQueue?
    private var searchService: SearchService?
    private var descriptionService: DescriptionService?
    private var scopedLibraries: [String: SecurityScopedLibrary] = [:]
    private var bootstrapTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var settingsKeyLoadTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var modelTestTasks: [ModelRole: Task<Void, Never>] = [:]
    private var testAllModelsTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// 扫描请求串行执行；扫描进行中到达的请求（如添加新媒体）在此排队，
    /// 不再被静默丢弃。
    private var scanQueue: [ScanRequest] = []
    private var segmentationTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var describeTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var assetDetailRefreshTask: Task<Void, Never>?
    private var assetDetailLoadTask: Task<Void, Never>?
    private var selectedDescriptionTask: Task<Void, Never>?
    private var playerPreparationTask: Task<Void, Never>?
    private var playerAssetID: String?
    private var searchGeneration = 0
    private var serviceGeneration = 0
    private var authenticationMigrationRoles: Set<ModelRole> = []
    private var detailGeneration = 0
    private var playerGeneration = 0
    private var libraryRefreshGeneration = 0
    private var jobsRefreshGeneration = 0
    private var processingRefreshGeneration = 0
    private var libraryOperationGeneration = 0
    private var evidenceEventGeneration = 0
    private var segmentationEventGeneration = 0
    private var descriptionEventGeneration = 0
    private var evidenceLaneFailure: String?
    private var segmentationLaneFailure: String?
    private var descriptionLaneFailure: String?
    private var isEvidencePaused = false
    private var isDescriptionPaused = false
    private var isBackgroundControlBarrierActive = false
    /// 源不可用断路的 MainActor 镜像：所有断路变更都经由本类发生，
    /// 车道启动守卫同步读取它，避免在守卫里跨 actor 等待。
    private var isSourceCircuitOpen = false
    private let sourceCircuitBoard = SourceCircuitBoard()
    private var didRecoverInterruptedJobs = false
    private let scanner = MediaScanner()

    init() {
        bootstrapTask = Task { [weak self] in await self?.bootstrap() }
    }

    deinit {
        bootstrapTask?.cancel()
        maintenanceTask?.cancel()
        libraryTask?.cancel()
        settingsKeyLoadTask?.cancel()
        settingsSaveTask?.cancel()
        modelTestTasks.values.forEach { $0.cancel() }
        testAllModelsTask?.cancel()
        scanTask?.cancel()
        segmentationTask?.cancel()
        indexTask?.cancel()
        describeTask?.cancel()
        searchTask?.cancel()
        assetDetailRefreshTask?.cancel()
        assetDetailLoadTask?.cancel()
        selectedDescriptionTask?.cancel()
        playerPreparationTask?.cancel()
        processingStatusTask?.cancel()
    }

    var hasSearch: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !searchResults.isEmpty
    }

    private func rebuildVisibleAssetItems() {
        let filtered: [MediaAssetRecord]
        if let selectedRootID {
            filtered = assets.filter { $0.rootID == selectedRootID }
        } else {
            filtered = assets
        }
        visibleAssetItems = filtered.enumerated().map {
            NumberedMediaAsset(ordinal: $0.offset + 1, asset: $0.element)
        }
    }

    /// Serializes library-changing commands while leaving the main actor free at every wait.
    /// A second click is rejected instead of starting a competing scan/delete/requeue transaction.
    private func runLibraryOperation(
        status: String,
        operation: @escaping @MainActor (AppModel) async throws -> Void
    ) {
        guard libraryTask == nil, settingsSaveTask == nil else {
            statusMessage = "已有媒体库操作正在进行，请稍候"
            return
        }
        libraryOperationGeneration += 1
        let generation = libraryOperationGeneration
        isLibraryBusy = true
        statusMessage = status
        libraryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(self)
            } catch is CancellationError {
                if self.libraryOperationGeneration == generation {
                    self.statusMessage = "操作已停止"
                }
            } catch {
                if self.libraryOperationGeneration == generation {
                    self.present(error)
                }
            }
            guard self.libraryOperationGeneration == generation else { return }
            self.isLibraryBusy = false
            self.libraryTask = nil
        }
    }

    /// 支持整目录、多选文件与单个文件的添加；文件会作为独立的 file 根入库。
    func addMediaItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        runLibraryOperation(status: "正在添加媒体…") { model in
            guard let database = model.database else { return }
            var addedRoots: [LibraryRootRecord] = []
            for url in urls {
                try Task.checkCancellation()
                let standardized = url.standardizedFileURL
                let isDirectory = try await Task.detached(priority: .utility) {
                    try standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                }.value
                let bookmark = try await LibraryAuthorization.createReadOnlyBookmarkAsync(
                    for: standardized
                )
                let access = try await LibraryAuthorization.resolveAsync(bookmark: bookmark)
                let root = try await database.addLibraryRoot(
                    path: standardized.path,
                    bookmark: bookmark,
                    kind: isDirectory ? .directory : .file
                )
                addedRoots.append(root)
                model.scopedLibraries[root.id] = access
            }
            try await model.refreshLibrary()
            // 只扫描本次添加的根；已有目录的缺失检测由启动与后续的轻量
            // 刷新负责，添加操作不再放大成全库重扫。
            model.enqueueScan(roots: addedRoots, mode: .refresh)
        }
    }

    /// 扫描范围：`full` 逐文件探测（手动重扫）；`refresh` 只探测新增或
    /// 元数据变化的文件（自动刷新），已有文件的缺失判定只依赖目录枚举。
    enum ScanMode {
        case full
        case refresh
    }

    struct ScanRequest {
        let roots: [LibraryRootRecord]
        let mode: ScanMode
    }

    /// 扫描请求入口：空闲即启动，否则排队，完成后由 scan 的收尾依次取队首。
    private func enqueueScan(roots: [LibraryRootRecord], mode: ScanMode) {
        guard scanTask == nil else {
            scanQueue.append(ScanRequest(roots: roots, mode: mode))
            return
        }
        startScanTask(ScanRequest(roots: roots, mode: mode))
    }

    private func startScanTask(_ request: ScanRequest) {
        isScanning = true
        scanStatusMessage = "正在准备扫描…"
        scanTask = Task(priority: .utility) { [weak self] in
            await self?.scan(request)
        }
    }

    private func startNextQueuedScan() {
        guard scanTask == nil, !scanQueue.isEmpty else { return }
        startScanTask(scanQueue.removeFirst())
    }

    // MARK: 从库中删除

    /// 移除一个根（目录或单个文件）：删除其全部记录与派生数据，不触碰源文件。
    func removeRoot(_ root: LibraryRootRecord) {
        runLibraryOperation(status: "正在移除媒体库…") { model in
            guard let database = model.database,
                  let sourceCache = model.sourceCache,
                  let workRoot = model.workRoot else { return }
            model.isBackgroundControlBarrierActive = true
            // 复位 defer 必须先于任何可抛错步骤安装（与 persistSettings 一致），
            // 否则失败路径会让屏障永久挡住三条车道。
            defer {
                model.isBackgroundControlBarrierActive = false
                model.startIndexing()
            }
            await model.pauseScanAndWait()
            await model.pauseIndexingAndWait()
            try await sourceCache.removeAll()
            try await database.removeLibraryRoot(id: root.id)
            let cleanupWarning: String?
            do {
                try await Self.runCleanup(database: database, workRoot: workRoot)
                cleanupWarning = nil
            } catch {
                cleanupWarning = error.localizedDescription
            }
            model.scopedLibraries[root.id] = nil
            if model.selectedRootID == root.id { model.selectedRootID = nil }
            try await model.refreshLibrary()
            if model.selectedAsset != nil,
               !model.assets.contains(where: { $0.id == model.selectedAsset?.id }) {
                model.clearSelection()
            }
            model.invalidateSearchAfterLibraryChange()
            if model.segmenter != nil { try await model.prepareIndexQueue(autoStart: true) }
            model.statusMessage = cleanupWarning.map {
                "已移除 \(root.name)；部分派生文件将在下次启动重试清理：\($0)"
            } ?? "已从媒体库移除：\(root.name)"
        }
    }

    /// 移除单个视频：保留排除标记防止目录扫描再次纳入，删除其全部派生数据。
    func removeAsset(_ asset: MediaAssetRecord) {
        runLibraryOperation(status: "正在移除视频…") { model in
            guard let database = model.database,
                  let sourceCache = model.sourceCache,
                  let workRoot = model.workRoot else { return }
            model.isBackgroundControlBarrierActive = true
            // 同 removeRoot：defer 先于可抛错步骤安装。
            defer {
                model.isBackgroundControlBarrierActive = false
                model.startIndexing()
            }
            await model.pauseScanAndWait()
            await model.pauseIndexingAndWait()
            try await sourceCache.removeAll()
            try await database.removeAsset(assetID: asset.id)
            let cleanupWarning: String?
            do {
                try await Self.runCleanup(database: database, workRoot: workRoot)
                cleanupWarning = nil
            } catch {
                cleanupWarning = error.localizedDescription
            }
            if model.selectedAsset?.id == asset.id { model.clearSelection() }
            try await model.refreshLibrary()
            model.invalidateSearchAfterLibraryChange()
            if model.segmenter != nil { try await model.prepareIndexQueue(autoStart: true) }
            model.statusMessage = cleanupWarning.map {
                "已移除 \(asset.filename)；部分派生文件将在下次启动重试清理：\($0)"
            } ?? "已从媒体库移除：\(asset.filename)"
        }
    }

    // MARK: 重跑

    /// 重跑整个视频的证据链（ASR/对齐/OCR/向量），描述会随后自动重新生成。
    func reprocessAsset(_ asset: MediaAssetRecord) {
        runLibraryOperation(status: "正在重新排队…") { model in
            guard let database = model.database else { return }
            try await database.requeueAssetIndexJobs(assetID: asset.id)
            try await model.prepareIndexQueue(autoStart: true)
            model.loadAssetDetail(for: asset)
            model.statusMessage = "已把 \(asset.filename) 重新排队建库"
        }
    }

    /// 重跑单个片段的证据链。
    func reprocessSegment(_ segment: SegmentRecord) {
        runLibraryOperation(status: "正在重新排队…") { model in
            guard let database = model.database else { return }
            try await database.requeueSegmentIndexJob(segmentID: segment.id)
            try await model.prepareIndexQueue(autoStart: true)
            if let asset = model.selectedAsset { model.loadAssetDetail(for: asset) }
            model.statusMessage = "已把片段 \(segment.ordinal + 1) 重新排队"
        }
    }

    /// 丢弃缓存并重新生成单个片段的描述。
    func regenerateDescription(for segmentID: String) {
        runLibraryOperation(status: "正在重新排队描述…") { model in
            guard let database = model.database else { return }
            try await database.requeueDescription(segmentID: segmentID)
            model.segmentDescriptions[segmentID] = nil
            try await model.prepareIndexQueue(autoStart: true)
            if let asset = model.selectedAsset { model.loadAssetDetail(for: asset) }
            model.statusMessage = "描述已重新排队"
        }
    }

    // MARK: 描述手动重跑（prompt/模型变更不再自动触发）

    private func displayed(_ cached: CachedSegmentDescription) -> DisplayedSegmentDescription {
        DisplayedSegmentDescription(
            cached: cached,
            isConfigStale: cached.promptVersion != DescriptionService.promptVersion
                || cached.modelID != configuration?.description.derivationID,
            isEvidenceStale: !cached.isEvidenceCurrent
        )
    }

    /// 重跑整个视频的描述（不动证据链）。
    func regenerateAssetDescriptions(_ asset: MediaAssetRecord) {
        runLibraryOperation(status: "正在重新排队描述…") { model in
            guard let database = model.database else { return }
            try await database.requeueAssetDescriptions(assetID: asset.id)
            model.segmentDescriptions = [:]
            try await model.prepareIndexQueue(autoStart: true)
            model.loadAssetDetail(for: asset)
            model.statusMessage = "已把 \(asset.filename) 的描述重新排队"
        }
    }

    /// 全库手动刷新：只重跑由旧版 prompt/模型生成的描述。
    func regenerateStaleDescriptions() {
        runLibraryOperation(status: "正在重新排队旧版描述…") { model in
            guard let database = model.database, let configuration = model.configuration else { return }
            try await database.requeueStaleDescriptions(
                descriptionModelID: configuration.description.derivationID,
                promptVersion: DescriptionService.promptVersion
            )
            model.segmentDescriptions = [:]
            try await model.refreshJobs()
            try await model.prepareIndexQueue(autoStart: true)
            if let asset = model.selectedAsset { model.loadAssetDetail(for: asset) }
            model.statusMessage = "旧版描述已重新排队"
        }
    }

    /// 右键单个媒体库条目重新扫描（完整探测；扫描进行中则排队）。
    func rescanRoot(_ root: LibraryRootRecord) {
        guard database != nil else {
            statusMessage = startupPhase == .loadingLocalData ? "正在读取本地数据…" : "数据库尚未就绪"
            return
        }
        guard libraryTask == nil, settingsSaveTask == nil else {
            statusMessage = "已有媒体库操作正在进行，请稍候"
            return
        }
        enqueueScan(roots: [root], mode: .full)
    }

    func reauthorizeRoot(_ root: LibraryRootRecord, using url: URL) {
        runLibraryOperation(status: "正在更新媒体库授权…") { model in
            guard let database = model.database else { return }
            // 恢复动作开始时捕获断路代际：期间若新一轮源失败重新开路，
            // 旧的授权结果不得误清它。
            let circuitGeneration = await model.sourceCircuitBoard
                .openCircuit(rootID: root.id)?.generation
            let selected = url.standardizedFileURL
            let expected = URL(fileURLWithPath: root.path).standardizedFileURL
            guard selected.path == expected.path else {
                throw AppLifecycleError.reauthorizationTargetMismatch(expected: expected.path)
            }
            let bookmark = try await LibraryAuthorization.createReadOnlyBookmarkAsync(for: selected)
            let access = try await LibraryAuthorization.resolveAsync(bookmark: bookmark)
            try await database.updateLibraryRootBookmark(id: root.id, bookmark: bookmark)
            model.scopedLibraries[root.id] = access
            model.clearBackgroundWarning(id: "library.\(root.id)")
            if let circuitGeneration,
               await model.clearSourceCircuitIfMatching(rootID: root.id, generation: circuitGeneration) {
                model.startIndexing()
            }
            try await model.refreshLibrary()
            model.statusMessage = "已重新授权：\(root.name)"
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanStatusMessage = "正在停止扫描…"
    }

    func startIndexing() {
        startSegmentationLane()
        startEvidenceLane()
        startDescriptionLane()
    }

    var isEvidenceIndexing: Bool { segmentationTask != nil || indexTask != nil }
    var isDescriptionIndexing: Bool { describeTask != nil }

    func startEvidenceProcessing() {
        guard !isSourceCircuitOpen else {
            statusMessage = "媒体源不可用：请先恢复该源（重试读取源 / 重新授权 / 重新扫描）"
            return
        }
        isEvidencePaused = false
        evidenceLaneFailure = nil
        segmentationLaneFailure = nil
        clearBackgroundWarning(id: "lane.segmentation")
        clearBackgroundWarning(id: "lane.evidence")
        clearBackgroundWarning(id: "lane.queue")
        startSegmentationLane()
        startEvidenceLane()
    }

    func startDescriptionProcessing() {
        guard !isSourceCircuitOpen else {
            statusMessage = "媒体源不可用：请先恢复该源（重试读取源 / 重新授权 / 重新扫描）"
            return
        }
        isDescriptionPaused = false
        descriptionLaneFailure = nil
        clearBackgroundWarning(id: "lane.description")
        clearBackgroundWarning(id: "lane.queue")
        startDescriptionLane()
    }

    func pauseEvidenceProcessing() {
        guard segmentationTask != nil || indexTask != nil else { return }
        isEvidencePaused = true
        evidenceStatusMessage = "正在暂停建库…"
        segmentationTask?.cancel()
        indexTask?.cancel()
    }

    func pauseDescriptionProcessing() {
        guard describeTask != nil else { return }
        isDescriptionPaused = true
        descriptionStatusMessage = "正在暂停描述…"
        describeTask?.cancel()
    }

    func retryFailedEvidenceJobs() {
        guard segmentationTask == nil, indexTask == nil else { return }
        runLibraryOperation(status: "正在重新排队建库失败任务…") { model in
            guard let database = model.database else { return }
            try await database.recoverInterruptedJobs(kind: .segmentAsset)
            try await database.recoverInterruptedJobs(kind: .indexSegment)
            if let segmenter = model.segmenter {
                model.segmentationProgress = try await segmenter.retryFailed()
            }
            if let indexer = model.indexer {
                model.indexingProgress = try await indexer.retryFailed()
            }
            try await model.prepareIndexQueue(autoStart: false)
            model.startEvidenceProcessing()
        }
    }

    func retryFailedDescriptionJobs() {
        guard describeTask == nil else { return }
        runLibraryOperation(status: "正在重新排队描述失败任务…") { model in
            guard let database = model.database,
                  let describeQueue = model.describeQueue else { return }
            try await database.recoverInterruptedJobs(kind: .describeSegment)
            model.describeProgress = try await describeQueue.retryFailed()
            try await model.prepareIndexQueue(autoStart: false)
            model.startDescriptionProcessing()
        }
    }

    func submitSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard let searchService else {
            errorMessage = "本地数据仍在加载，请稍候再搜索。"
            return
        }
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchStatusMessage = "正在搜索…"
        searchTask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let literalResults = try await searchService.literalSearch(query)
                try Task.checkCancellation()
                guard self.searchGeneration == generation else { return }
                self.searchResults = literalResults
                self.searchStatusMessage = "全文找到 \(literalResults.count) 个片段；正在补充语义结果…"

                let results = try await searchService.search(query)
                try Task.checkCancellation()
                guard self.searchGeneration == generation else { return }
                self.searchResults = results
                self.searchStatusMessage = String(
                    format: "找到 %d 个片段（%.2f 秒）",
                    results.count,
                    Date().timeIntervalSince(started)
                )
            } catch is CancellationError {
                // A newer query replaced this one.
            } catch {
                if self.searchGeneration == generation {
                    self.searchStatusMessage = "搜索失败：\(error.localizedDescription)"
                    self.errorMessage = self.searchStatusMessage
                }
            }
            if self.searchGeneration == generation {
                self.isSearching = false
                self.searchTask = nil
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        searchQuery = ""
        searchResults = []
        isSearching = false
        searchTask = nil
        searchStatusMessage = ""
    }

    private func invalidateSearchAfterLibraryChange() {
        searchTask?.cancel()
        searchGeneration += 1
        searchResults = []
        isSearching = false
        searchTask = nil
        searchStatusMessage = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : "媒体库已更新，请重新搜索"
    }

    func select(asset: MediaAssetRecord) {
        selectedDescriptionTask?.cancel()
        selectedResult = nil
        segmentDescriptions = [:]
        assetDetail = nil
        play(asset: asset, startMS: 0)
        loadAssetDetail(for: asset)
    }

    func select(result: SearchResult) {
        assetDetailLoadTask?.cancel()
        detailGeneration += 1
        selectedDescriptionTask?.cancel()
        selectedResult = result
        segmentDescriptions = [:]
        play(asset: result.asset, startMS: result.playbackStartMS)
        selectedDescriptionTask = Task { [weak self] in
            guard let self, let readDatabase = self.readDatabase else { return }
            let cached = try? await readDatabase.latestDescription(
                segmentID: result.segment.id
            )
            guard !Task.isCancelled else { return }
            if self.selectedResult?.segment.id == result.segment.id, let cached {
                self.segmentDescriptions[result.segment.id] = self.displayed(cached)
            }
            self.selectedDescriptionTask = nil
        }
    }

    /// 空格键播放/暂停。
    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            // waitingToPlayAtSpecifiedRate 也属于已经请求播放；此时再次按空格
            // 应该取消播放，而不是重复发送 play()。
            player.pause()
        }
    }

    /// 在视频详情中点击某个片段，从该片段起点播放。
    func playFromSegment(_ segment: SegmentRecord) {
        guard let asset = selectedAsset else { return }
        selectedResult = nil
        play(asset: asset, startMS: segment.startMS)
    }

    func openSettings() {
        guard let configuration else { return }
        settingsKeyLoadTask?.cancel()
        settingsCredentialWarning = nil
        settingsDraft = ModelSettingsDraft(
            asr: Self.endpointDraft(configuration.asr),
            aligner: Self.endpointDraft(configuration.aligner),
            embedding: Self.endpointDraft(configuration.embedding),
            description: Self.endpointDraft(configuration.description),
            pythonLauncherPath: configuration.localWorker?.pythonLauncherPath ?? "",
            modelRootPath: configuration.localWorker?.modelRootPath ?? ""
        )
        resetModelTestStates()
        isSettingsPresented = true
        let credentialRoles = configuration.credentialRoles
        guard !credentialRoles.isEmpty else {
            isSettingsLoading = false
            settingsKeyLoadTask = nil
            return
        }
        isSettingsLoading = true
        settingsKeyLoadTask = Task { [weak self] in
            let credentials: ModelCredentials
            do {
                credentials = try await KeychainStore.loadModelCredentialsAsync(
                    for: credentialRoles
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.isSettingsLoading = false
                self.settingsKeyLoadTask = nil
                self.recordBackgroundWarning(
                    id: "settings.keychain",
                    title: "无法读取模型凭据",
                    detail: "请在模型设置中重新输入需要 Bearer 鉴权的 API key。\n\(error.localizedDescription)"
                )
                self.settingsCredentialWarning =
                    "无法读取旧版模型凭据。请重新输入；保存时 macOS 可能要求授权迁移。\n\(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled, let self, self.isSettingsPresented else { return }
            self.settingsDraft.asr.apiKey = credentials.asr
            self.settingsDraft.aligner.apiKey = credentials.aligner
            self.settingsDraft.embedding.apiKey = credentials.embedding
            self.settingsDraft.description.apiKey = credentials.description
            self.clearBackgroundWarning(id: "settings.keychain")
            self.isSettingsLoading = false
            self.settingsKeyLoadTask = nil
        }
    }

    func saveSettings() {
        guard settingsSaveTask == nil,
              libraryTask == nil,
              !isSettingsLoading,
              !isTestingModels else {
            statusMessage = isSettingsLoading ? "正在读取钥匙串…" : "另一项设置或媒体库操作尚未完成"
            return
        }
        let draft = settingsDraft
        isSavingSettings = true
        settingsSaveTask = Task { [weak self] in
            await self?.persistSettings(draft)
        }
    }

    func dismissSettings() {
        guard !isSavingSettings else { return }
        settingsKeyLoadTask?.cancel()
        settingsKeyLoadTask = nil
        cancelModelTests()
        isSettingsLoading = false
        settingsCredentialWarning = nil
        isSettingsPresented = false
    }

    func loadCredentialForSettingsIfNeeded(_ role: ModelRole) {
        guard isSettingsPresented,
              !isSettingsLoading,
              settingsDraft.endpoint(for: role).authentication == .bearer,
              settingsDraft.endpoint(for: role).apiKey.isEmpty else { return }
        isSettingsLoading = true
        settingsKeyLoadTask?.cancel()
        settingsKeyLoadTask = Task { [weak self] in
            defer {
                self?.isSettingsLoading = false
                self?.settingsKeyLoadTask = nil
            }
            do {
                let credentials = try await KeychainStore.loadModelCredentialsAsync(for: [role])
                guard !Task.isCancelled, let self, self.isSettingsPresented,
                      self.settingsDraft.endpoint(for: role).authentication == .bearer else {
                    return
                }
                self.setSettingsAPIKey(credentials[role], for: role)
                self.settingsCredentialWarning = credentials[role].isEmpty
                    ? "未找到该能力的旧密钥，请重新输入后保存。" : nil
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.settingsCredentialWarning =
                    "无法读取旧版模型凭据。请重新输入；保存时 macOS 可能要求授权迁移。\n\(error.localizedDescription)"
            }
        }
    }

    private func setSettingsAPIKey(_ value: String, for role: ModelRole) {
        switch role {
        case .asr: settingsDraft.asr.apiKey = value
        case .aligner: settingsDraft.aligner.apiKey = value
        case .embedding: settingsDraft.embedding.apiKey = value
        case .description: settingsDraft.description.apiKey = value
        }
    }

    func modelTestState(for role: ModelRole) -> ModelTestState {
        let state = modelTestStates[role] ?? ModelTestState()
        guard state.draftSignature == modelTestSignature(for: role, draft: settingsDraft) else {
            return ModelTestState()
        }
        return state
    }

    func testModel(_ role: ModelRole) {
        guard !isSettingsLoading,
              !isSavingSettings,
              testAllModelsTask == nil,
              modelTestTasks[role] == nil,
              let workRoot else { return }
        let draft = settingsDraft
        let configuration = Self.configuration(from: draft)
        let credentials = Self.credentials(from: draft)
        let signature = modelTestSignature(for: role, draft: draft)
        modelTestStates[role] = ModelTestState(
            phase: .testing,
            message: "正在发送真实测试请求…",
            draftSignature: signature
        )
        isTestingModels = true
        modelTestTasks[role] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.modelTestTasks[role] = nil
                self.isTestingModels = !self.modelTestTasks.isEmpty || self.testAllModelsTask != nil
            }
            do {
                let report = try await ModelCapabilityTester.test(
                    role: role,
                    configuration: configuration,
                    credentials: credentials,
                    workRoot: workRoot
                )
                guard !Task.isCancelled else { return }
                guard self.modelTestSignature(for: role, draft: self.settingsDraft) == signature else {
                    self.modelTestStates[role] = ModelTestState()
                    return
                }
                self.modelTestStates[role] = ModelTestState(
                    phase: .passed,
                    message: report.detail,
                    draftSignature: signature
                )
            } catch is CancellationError {
                self.modelTestStates[role] = ModelTestState()
            } catch {
                self.modelTestStates[role] = ModelTestState(
                    phase: .failed,
                    message: Self.sanitizedModelTestError(error, credentials: credentials),
                    draftSignature: signature
                )
            }
        }
    }

    /// Runs serially to avoid loading several large models into unified memory at once.
    func testAllModels() {
        guard !isSettingsLoading,
              !isSavingSettings,
              !isTestingModels,
              let workRoot else { return }
        let draft = settingsDraft
        let configuration = Self.configuration(from: draft)
        let credentials = Self.credentials(from: draft)
        isTestingModels = true
        testAllModelsTask = Task { [weak self] in
            guard let self else { return }
            for role in ModelRole.allCases {
                guard !Task.isCancelled else { break }
                let signature = self.modelTestSignature(for: role, draft: draft)
                self.modelTestStates[role] = ModelTestState(
                    phase: .testing,
                    message: "正在发送真实测试请求…",
                    draftSignature: signature
                )
                do {
                    let report = try await ModelCapabilityTester.test(
                        role: role,
                        configuration: configuration,
                        credentials: credentials,
                        workRoot: workRoot
                    )
                    guard self.modelTestSignature(for: role, draft: self.settingsDraft) == signature else {
                        self.modelTestStates[role] = ModelTestState()
                        continue
                    }
                    self.modelTestStates[role] = ModelTestState(
                        phase: .passed,
                        message: report.detail,
                        draftSignature: signature
                    )
                } catch is CancellationError {
                    self.modelTestStates[role] = ModelTestState()
                    break
                } catch {
                    self.modelTestStates[role] = ModelTestState(
                        phase: .failed,
                        message: Self.sanitizedModelTestError(error, credentials: credentials),
                        draftSignature: signature
                    )
                }
            }
            self.testAllModelsTask = nil
            self.isTestingModels = false
        }
    }

    private func cancelModelTests() {
        modelTestTasks.values.forEach { $0.cancel() }
        modelTestTasks.removeAll()
        testAllModelsTask?.cancel()
        testAllModelsTask = nil
        isTestingModels = false
        resetModelTestStates()
    }

    private func resetModelTestStates() {
        modelTestStates = Dictionary(
            uniqueKeysWithValues: ModelRole.allCases.map { ($0, ModelTestState()) }
        )
    }

    private func modelTestSignature(for role: ModelRole, draft: ModelSettingsDraft) -> Int {
        var hasher = Hasher()
        hasher.combine(draft.endpoint(for: role))
        if draft.endpoint(for: role).transport == .localWorker {
            hasher.combine(draft.pythonLauncherPath)
            hasher.combine(draft.modelRootPath)
        }
        return hasher.finalize()
    }

    private nonisolated static func endpointDraft(_ endpoint: ModelEndpoint) -> ModelEndpointDraft {
        ModelEndpointDraft(
            transport: endpoint.transport,
            endpointURL: endpoint.endpointURL?.absoluteString ?? "",
            modelID: endpoint.modelID,
            authentication: endpoint.authentication,
            apiKey: ""
        )
    }

    private nonisolated static func configuration(from draft: ModelSettingsDraft) -> ModelConfiguration {
        func endpoint(_ value: ModelEndpointDraft) -> ModelEndpoint {
            let urlText = value.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return ModelEndpoint(
                transport: value.transport,
                endpointURL: value.transport.requiresEndpoint ? URL(string: urlText) : nil,
                modelID: value.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                authentication: value.authentication
            )
        }
        let worker = ModelConfiguration.Worker(
            forcedAlignerModelID: draft.aligner.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            embeddingModelID: draft.embedding.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            pythonLauncherPath: draft.pythonLauncherPath.trimmingCharacters(in: .whitespacesAndNewlines),
            modelRootPath: draft.modelRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return ModelConfiguration(
            asr: endpoint(draft.asr),
            aligner: endpoint(draft.aligner),
            embedding: endpoint(draft.embedding),
            description: endpoint(draft.description),
            localWorker: worker
        )
    }

    private nonisolated static func credentials(from draft: ModelSettingsDraft) -> ModelCredentials {
        ModelCredentials(
            asr: draft.asr.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            aligner: draft.aligner.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            embedding: draft.embedding.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            description: draft.description.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private nonisolated static func sanitizedModelTestError(
        _ error: Error,
        credentials: ModelCredentials
    ) -> String {
        var message = error.localizedDescription
        for role in ModelRole.allCases {
            let key = credentials[role]
            if !key.isEmpty { message = message.replacingOccurrences(of: key, with: "[已隐藏]") }
        }
        return String(message.prefix(2_000))
    }

    func clearError() {
        errorMessage = nil
        guard statusMessage == "发生错误" else { return }
        if isScanning {
            statusMessage = "正在扫描…"
        } else if isIndexing {
            statusMessage = "后台处理中…"
        } else if isSearching {
            statusMessage = "正在搜索…"
        } else if startupPhase == .failed {
            statusMessage = "启动失败"
        } else {
            statusMessage = roots.isEmpty ? "请选择媒体目录" : "已就绪"
        }
    }

    /// 启动只强依赖本地数据（配置、数据库、库列表），且这些读取也
    /// 全部在后台执行；清扫、书签解析、服务配置等维护工作随后异步进行，
    /// 任何一步慢都不会阻塞界面。
    private func bootstrap() async {
        do {
            let core = try await Self.loadLocalCore()
            try Task.checkCancellation()
            configuration = core.configuration
            authenticationMigrationRoles = core.authenticationMigrationRoles
            instanceLock = core.instanceLock
            database = core.database
            readDatabase = core.readDatabase
            searchDatabase = core.searchDatabase
            workRoot = core.workRoot
            let sourceCache = LocalSourceCache(
                workRoot: core.workRoot,
                authorizeSource: { [weak self] asset in
                    guard let self else { throw CancellationError() }
                    _ = try await self.authorizeLibrary(for: asset)
                }
            )
            self.sourceCache = sourceCache
            segmenter = ContentSegmenter(
                database: core.database,
                sourceCache: sourceCache
            )
            // Search is available as soon as local data is open. A configured
            // runtime later enriches it with semantic ranking, but FTS never
            // waits for model setup or background indexing lifecycle.
            searchService = SearchService(
                database: core.searchDatabase,
                configuration: core.configuration
            )
            // This is DB-only ownership reconciliation. Keep it before the
            // first snapshot so legacy fixed-duration cards never flash, but
            // degrade locally instead of turning maintenance into a startup alert.
            do {
                segmentationProgress = try await segmenter?.prepareQueue() ?? segmentationProgress
                clearBackgroundWarning(id: "maintenance.queue")
            } catch {
                recordBackgroundWarning(
                    id: "maintenance.queue",
                    title: "后台队列维护失败",
                    detail: error.localizedDescription
                )
            }
            try await refreshLibrary()
            startupPhase = .ready
            statusMessage = roots.isEmpty ? "请选择媒体目录" : "已就绪"
            if !authenticationMigrationRoles.isEmpty {
                recordBackgroundWarning(
                    id: "settings.authentication-migration",
                    title: "请确认模型鉴权方式",
                    detail: "旧配置没有记录鉴权模式。为避免不必要地访问钥匙串，模型服务会等待你在“模型设置”中确认并保存。"
                )
            }
        } catch {
            guard !(error is CancellationError) else { return }
            startupPhase = .failed
            present(error)
            return
        }
        bootstrapTask = nil
        let generation = serviceGeneration
        maintenanceTask = Task(priority: .utility) { [weak self] in
            await self?.bootstrapMaintenance(generation: generation)
        }
    }

    private struct BootstrapCore {
        let configuration: ModelConfiguration
        let instanceLock: ApplicationInstanceLock
        let database: MediaDatabase
        let readDatabase: MediaDatabase
        let searchDatabase: MediaDatabase
        let workRoot: URL
        let authenticationMigrationRoles: Set<ModelRole>
    }

    /// nonisolated async：在全局执行器上打开数据库与读取配置，
    /// 首次迁移或 WAL 恢复再慢也不占用主线程。
    private nonisolated static func loadLocalCore() async throws -> BootstrapCore {
        let instanceLock = try ApplicationInstanceLock(url: ApplicationPaths.instanceLockURL())
        let loadedConfiguration = try ModelConfigurationStore.loadForStartup()
        let configuration = loadedConfiguration.configuration
        let databaseURL = try ApplicationPaths.databaseURL()
        let database = try MediaDatabase(url: databaseURL)
        // Schema-1 model outputs are byte-compatible with schema 2. Relabel
        // exact pipeline matches before any read snapshot or worker can observe
        // them, so upgrading never turns completed videos back into model work.
        try await database.migrateLegacyModelIdentities(
            configuration: configuration,
            allowLegacyAdoption: loadedConfiguration.canAdoptLegacyModelIdentities
        )
        // Open only after the writer has completed migrations. Both connections
        // use WAL snapshots, but their actor queues remain independent.
        let readDatabase = try MediaDatabase(readOnlyURL: databaseURL)
        let searchDatabase = try MediaDatabase(readOnlyURL: databaseURL)
        let workRoot = try ApplicationPaths.workDirectoryURL()
        return BootstrapCore(
            configuration: configuration,
            instanceLock: instanceLock,
            database: database,
            readDatabase: readDatabase,
            searchDatabase: searchDatabase,
            workRoot: workRoot,
            authenticationMigrationRoles: loadedConfiguration.authenticationMigrationRoles
        )
    }

    /// 启动轻量刷新：给"文件已从磁盘消失/变化"一个常规检测时机（此前
    /// 只有添加媒体会触发扫描，缺失无从发现）。只做目录枚举 + 元数据
    /// 比对，仅新增或变化的文件会被探测；与其他扫描请求共用串行队列。
    private func enqueueStartupRefresh() {
        let targets = roots.filter(\.isEnabled)
        guard !targets.isEmpty else { return }
        enqueueScan(roots: targets, mode: .refresh)
    }

    /// 后台维护只处理本机派生数据与模型运行时。媒体书签解析保持在需要时
    /// 才发生（轻量刷新、源缓存或播放）；启动刷新只做目录枚举与 stat，
    /// 不逐文件打开媒体，对 NAS 的扰动远小于旧的全量扫描。
    private func bootstrapMaintenance(generation: Int) async {
        guard let database, let searchDatabase, let sourceCache, let workRoot else { return }
        enqueueStartupRefresh()
        do {
            try await recoverInterruptedJobsIfNeeded()
            try Task.checkCancellation()
            segmentationProgress = try await segmenter?.prepareQueue() ?? segmentationProgress
            try Task.checkCancellation()
            // Queue reconciliation is local database maintenance, not model
            // work. Run it before Keychain/runtime setup so legacy saved
            // descriptions recover immediately even when models are offline.
            try await database.reconcileDescribeJobs()
            try await refreshJobs()
            clearBackgroundWarning(id: "maintenance.queue")
        } catch is CancellationError {
            if generation == serviceGeneration { maintenanceTask = nil }
            return
        } catch {
            guard generation == serviceGeneration else { return }
            recordBackgroundWarning(
                id: "maintenance.queue",
                title: "后台队列维护失败",
                detail: error.localizedDescription
            )
            maintenanceTask = nil
            return
        }

        do {
            try await Self.runCleanup(database: database, workRoot: workRoot)
            clearBackgroundWarning(id: "maintenance.cleanup")
        } catch is CancellationError {
            if generation == serviceGeneration { maintenanceTask = nil }
            return
        } catch {
            recordBackgroundWarning(
                id: "maintenance.cleanup",
                title: "部分临时文件尚未清理",
                detail: "应用会在下次启动重试。\n\(error.localizedDescription)"
            )
        }

        guard generation == serviceGeneration, let configuration else { return }
        if !authenticationMigrationRoles.isEmpty {
            statusMessage = "本地浏览和字面搜索已可用；请确认模型鉴权方式"
            maintenanceTask = nil
            return
        }
        do {
            let roles = configuration.credentialRoles
            let credentials = roles.isEmpty
                ? ModelCredentials()
                : try await KeychainStore.loadModelCredentialsAsync(for: roles)
            for role in roles where credentials[role].isEmpty {
                throw AppLifecycleError.missingBearerCredential(role)
            }
            let services = try await Self.makeServices(
                configuration: configuration,
                credentials: credentials,
                database: database,
                searchDatabase: searchDatabase,
                sourceCache: sourceCache,
                workRoot: workRoot
            )
            try Task.checkCancellation()
            guard generation == serviceGeneration else { return }
            install(services)
            clearBackgroundWarning(id: "maintenance.models")
            try await prepareIndexQueue(
                autoStart: scanTask == nil && libraryTask == nil && settingsSaveTask == nil
            )
        } catch is CancellationError {
            if generation == serviceGeneration { maintenanceTask = nil }
            return
        } catch {
            statusMessage = "本地浏览和字面搜索已可用；请在模型设置中检查服务"
            recordBackgroundWarning(
                id: "maintenance.models",
                title: "模型服务尚未就绪",
                detail: error.localizedDescription
            )
        }
        if generation == serviceGeneration { maintenanceTask = nil }
    }

    private nonisolated static func runCleanup(
        database: MediaDatabase,
        workRoot: URL
    ) async throws {
        try ApplicationPaths.cleanupAbandonedRuns(in: workRoot)
        try Task.checkCancellation()
        try ApplicationPaths.cleanupAbandonedPrefetch(in: workRoot)
        try Task.checkCancellation()
        try ApplicationPaths.cleanupAbandonedDescriptionRuns(in: workRoot)
        try Task.checkCancellation()
        try ApplicationPaths.cleanupAbandonedSourceCache(in: workRoot)
        try Task.checkCancellation()
        let referencedFrames = try await database.referencedFrameRelativePaths()
        try ApplicationPaths.cleanupUnreferencedFrames(
            in: workRoot,
            referencedRelativePaths: referencedFrames
        )
        try Task.checkCancellation()
        try ApplicationPaths.compactReferencedFrames(
            in: workRoot,
            referencedRelativePaths: referencedFrames
        )
    }

    /// Crash recovery is a startup-only control-plane action. Online queue
    /// reconciliation must never rewrite another live task's running claim.
    private func recoverInterruptedJobsIfNeeded() async throws {
        guard !didRecoverInterruptedJobs, let database else { return }
        try await database.recoverInterruptedJobs(kind: .segmentAsset)
        try await database.recoverInterruptedJobs(kind: .indexSegment)
        try await database.recoverInterruptedJobs(kind: .describeSegment)
        didRecoverInterruptedJobs = true
    }

    private func authorizeLibrary(for asset: MediaAssetRecord) async throws -> SecurityScopedLibrary {
        guard let root = roots.first(where: { $0.id == asset.rootID && $0.isEnabled }) else {
            throw AppLifecycleError.libraryRootUnavailable
        }
        return try await authorizeLibrary(root)
    }

    private func authorizeLibrary(_ root: LibraryRootRecord) async throws -> SecurityScopedLibrary {
        if let existing = scopedLibraries[root.id] { return existing }
        do {
            let access = try await LibraryAuthorization.resolveAsync(
                bookmark: root.bookmark,
                allowMissingItemWhenParentIsReadable: root.kind == .file
            )
            try Task.checkCancellation()
            scopedLibraries[root.id] = access
            clearBackgroundWarning(id: "library.\(root.id)")
            if access.isBookmarkStale, let database {
                do {
                    let renewed = try await LibraryAuthorization.createReadOnlyBookmarkAsync(
                        for: access.url
                    )
                    try await database.updateLibraryRootBookmark(id: root.id, bookmark: renewed)
                } catch {
                    recordBackgroundWarning(
                        id: "library.\(root.id)",
                        title: "媒体库授权需要更新",
                        detail: "\(root.path)\n请右键该媒体库并选择“重新授权”。\n\(error.localizedDescription)"
                    )
                }
            }
            return access
        } catch {
            recordBackgroundWarning(
                id: "library.\(root.id)",
                title: "无法访问媒体库",
                detail: "\(root.path)\n请右键该媒体库并选择“重新授权”。\n\(error.localizedDescription)"
            )
            throw error
        }
    }

    private func persistSettings(_ draft: ModelSettingsDraft) async {
        isBackgroundControlBarrierActive = true
        defer {
            isBackgroundControlBarrierActive = false
            startIndexing()
            isSavingSettings = false
            settingsSaveTask = nil
        }
        do {
            let newConfiguration = Self.configuration(from: draft)
            try newConfiguration.validate()
            let newCredentials = Self.credentials(from: draft)
            for role in newConfiguration.credentialRoles where newCredentials[role].isEmpty {
                throw AppLifecycleError.missingBearerCredential(role)
            }
            guard let database, let searchDatabase, let workRoot,
                  let previousConfiguration = configuration else { return }
            guard let sourceCache else { return }
            let interruptedMaintenance = maintenanceTask
            interruptedMaintenance?.cancel()
            maintenanceTask = nil
            if let interruptedMaintenance {
                await interruptedMaintenance.value
            }
            try await recoverInterruptedJobsIfNeeded()
            serviceGeneration += 1
            let generation = serviceGeneration

            // Model configuration is an explicit control-plane barrier for
            // background writers. Existing searches keep their service snapshot
            // and finish independently; browsing and FTS remain available.
            await pauseIndexingAndWait()
            try Task.checkCancellation()

            let services = try await Self.makeServices(
                configuration: newConfiguration,
                credentials: newCredentials,
                database: database,
                searchDatabase: searchDatabase,
                sourceCache: sourceCache,
                workRoot: workRoot
            )
            try Task.checkCancellation()
            let previousRoles = previousConfiguration.credentialRoles
            let touchedCredentialRoles = previousRoles.union(newConfiguration.credentialRoles)
            let previousCredentials: ModelCredentials?
            let requiresACLReplacement: Bool
            do {
                previousCredentials = try await KeychainStore.loadModelCredentialsAsync(
                    for: touchedCredentialRoles
                )
                requiresACLReplacement = false
            } catch let error as KeychainError where error.isAccessDenied {
                previousCredentials = nil
                requiresACLReplacement = true
            }
            do {
                if requiresACLReplacement {
                    try await KeychainStore.replaceInaccessibleModelCredentialsAsync(
                        newCredentials,
                        for: touchedCredentialRoles
                    )
                } else {
                    try await KeychainStore.saveModelCredentialsAsync(
                        newCredentials,
                        for: touchedCredentialRoles
                    )
                }
                try await ModelConfigurationStore.saveAsync(newConfiguration)
            } catch {
                if let previousCredentials {
                    try? await KeychainStore.saveModelCredentialsAsync(
                        previousCredentials,
                        for: touchedCredentialRoles
                    )
                }
                throw error
            }
            try Task.checkCancellation()
            guard generation == serviceGeneration else { return }
            configuration = newConfiguration
            authenticationMigrationRoles = []
            install(services)
            clearBackgroundWarning(id: "maintenance.models")
            clearBackgroundWarning(id: "settings.keychain")
            clearBackgroundWarning(id: "settings.authentication-migration")
            settingsCredentialWarning = nil
            // Retire the old service snapshot without synchronously stopping its
            // Worker. An in-flight old query owns that snapshot until it finishes;
            // its generation is invalidated so it cannot publish stale ranking.
            searchGeneration += 1
            searchTask = nil
            isSearching = false
            searchResults = []
            searchStatusMessage = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : "模型设置已更新，请重新搜索"
            evidenceLaneFailure = nil
            descriptionLaneFailure = nil
            resetModelTestStates()
            isSettingsPresented = false
            statusMessage = "模型设置已保存"
            try await prepareIndexQueue(autoStart: false)
            if !touchedCredentialRoles.isEmpty {
                await KeychainStore.deleteLegacyOMLXKeyAsync()
            }
        } catch is CancellationError {
            statusMessage = "模型设置保存已停止"
        } catch {
            settingsCredentialWarning = error.localizedDescription
            statusMessage = "模型设置尚未保存"
        }
    }

    private nonisolated static func makeServices(
        configuration: ModelConfiguration,
        credentials: ModelCredentials,
        database: MediaDatabase,
        searchDatabase: MediaDatabase,
        sourceCache: LocalSourceCache,
        workRoot: URL
    ) async throws -> ConfiguredServices {
        try Task.checkCancellation()
        let runtime = try ModelRuntime(
            configuration: configuration,
            credentials: credentials,
            workRoot: workRoot
        )
        let indexer = SegmentIndexer(
            database: database,
            configuration: configuration,
            runtime: runtime,
            sourceCache: sourceCache,
            workRoot: workRoot
        )
        let searchService = SearchService(
            database: searchDatabase,
            configuration: configuration,
            runtime: runtime
        )
        let descriptionService = DescriptionService(
            database: database,
            configuration: configuration,
            runtime: runtime,
            sourceCache: sourceCache,
            workRoot: workRoot
        )
        let describeQueue = DescriptionQueue(
            database: database,
            descriptionService: descriptionService,
            sourceCache: sourceCache
        )
        return ConfiguredServices(
            runtime: runtime,
            indexer: indexer,
            describeQueue: describeQueue,
            searchService: searchService,
            descriptionService: descriptionService
        )
    }

    private func install(_ services: ConfiguredServices) {
        runtime = services.runtime
        indexer = services.indexer
        describeQueue = services.describeQueue
        searchService = services.searchService
        descriptionService = services.descriptionService
    }

    private func refreshLibrary() async throws {
        guard let database = readDatabase else { return }
        libraryRefreshGeneration += 1
        let generation = libraryRefreshGeneration
        let snapshot = try await database.librarySnapshot()
        try Task.checkCancellation()
        guard generation == libraryRefreshGeneration else { return }
        roots = snapshot.roots
        assets = snapshot.assets
        rebuildVisibleAssetItems()
        applyProcessingSummaries(snapshot.processingSummaries)
        if let selectedAsset,
           let refreshed = assets.first(where: { $0.id == selectedAsset.id }) {
            self.selectedAsset = refreshed
        } else if selectedAsset != nil {
            clearSelection()
        }
    }

    private func refreshJobs() async throws {
        guard let database = readDatabase else { return }
        jobsRefreshGeneration += 1
        let generation = jobsRefreshGeneration
        async let dashboard = database.jobDashboardSnapshot(
            descriptionModelID: configuration?.description.derivationID,
            promptVersion: configuration == nil ? nil : DescriptionService.promptVersion
        )
        async let segmentation = database.segmentationProgress()
        let snapshot = try await dashboard
        let segmentationSnapshot = try await segmentation
        try Task.checkCancellation()
        guard generation == jobsRefreshGeneration else { return }
        failedJobs = snapshot.jobs.filter { $0.status == .failed || $0.status == .cancelled }
        failureSummaries = snapshot.failures
        indexingProgress = snapshot.indexingProgress
        segmentationProgress = segmentationSnapshot
        describeProgress = snapshot.describeProgress
        staleDescriptionCount = snapshot.staleDescriptionCount
        applyProcessingSummaries(snapshot.processingSummaries)
    }

    /// 以视频为单位汇总两个独立后台车道的状态。
    private func refreshProcessingStatus() async {
        guard let database = readDatabase else { return }
        processingRefreshGeneration += 1
        let generation = processingRefreshGeneration
        let summaries = (try? await database.processingSnapshot()) ?? [:]
        guard generation == processingRefreshGeneration, !Task.isCancelled else { return }
        applyProcessingSummaries(summaries)
    }

    private func applyProcessingSummaries(
        _ summaries: [String: AssetProcessingSummary]
    ) {
        processingSummaries = summaries

        var overall = RootLibraryStatistics()
        var perRoot: [String: RootLibraryStatistics] = [:]
        for asset in assets {
            var rootStats = perRoot[asset.rootID] ?? RootLibraryStatistics()
            rootStats.videoCount += 1
            rootStats.totalFileSize += asset.fileSize
            rootStats.totalDurationMS += asset.durationMS
            overall.videoCount += 1
            overall.totalFileSize += asset.fileSize
            overall.totalDurationMS += asset.durationMS
            switch Self.videoQueueBucket(summaries[asset.id]) {
            case .inProgress:
                rootStats.queue.inProgress += 1
                overall.queue.inProgress += 1
            case .failed:
                rootStats.queue.failed += 1
                overall.queue.failed += 1
            case .waiting:
                rootStats.queue.waiting += 1
                overall.queue.waiting += 1
            case .completed:
                rootStats.queue.completed += 1
                overall.queue.completed += 1
            case .notStarted:
                rootStats.queue.notStarted += 1
                overall.queue.notStarted += 1
            }
            perRoot[asset.rootID] = rootStats
        }
        overall.queue.total = assets.count
        for (rootID, stats) in perRoot {
            var updated = stats
            updated.queue.total = updated.videoCount
            perRoot[rootID] = updated
        }
        videoQueue = overall.queue
        libraryStatistics = overall
        rootStatistics = perRoot
    }

    /// 以视频为单位的处理分类，底部队列总览与侧栏路径统计共用，
    /// 保证同一份数据在两处显示完全一致。
    private static func videoQueueBucket(
        _ summary: AssetProcessingSummary?
    ) -> VideoQueueBucket {
        guard let summary else { return .notStarted }
        if summary.segmentationStatus == .running
            || summary.evidenceRunning || summary.describeRunning {
            return .inProgress
        }
        if summary.failedCount > 0 { return .failed }
        if summary.segmentationStatus == .pending
            || summary.evidencePending > 0 || summary.describePending > 0 {
            return .waiting
        }
        guard summary.totalSegments > 0 else { return .notStarted }
        if summary.evidenceSucceeded >= summary.totalSegments,
           summary.describeSucceeded >= summary.totalSegments {
            return .completed
        }
        // 车道都空闲但产物不完整（例如描述任务缺队）：
        // 等待 reconcile 补齐，期间按待处理显示，不误报完成。
        return .waiting
    }

    private enum VideoQueueBucket {
        case inProgress
        case failed
        case waiting
        case completed
        case notStarted
    }

    private func prepareIndexQueue(autoStart: Bool) async throws {
        if let segmenter {
            segmentationProgress = try await segmenter.prepareQueue()
        }
        if let indexer {
            indexingProgress = try await indexer.prepareQueue()
        }
        describeProgress = try await describeQueue?.prepareQueue() ?? describeProgress
        try await refreshJobs()
        if autoStart { startIndexing() }
    }

    private func scan(_ request: ScanRequest) async {
        errorMessage = nil
        clearBackgroundWarning(id: "scan")
        // 主动停止时清空排队请求：停止扫描是最新意图，不能立刻又开下一轮。
        var wasCancelled = false
        defer {
            isScanning = false
            scanTask = nil
            if wasCancelled {
                scanQueue.removeAll()
            }
            startNextQueuedScan()
        }

        do {
            guard let database else { throw AppLifecycleError.databaseUnavailable }
            var scanErrors: [String] = []
            let rootsToScan = request.roots
            for (index, root) in rootsToScan.enumerated() {
                try Task.checkCancellation()
                let progressVerb = request.mode == .full ? "正在扫描" : "正在检查"
                scanStatusMessage = "\(progressVerb) \(index + 1)/\(rootsToScan.count)：\(root.name)"
                do {
                    // 恢复动作开始时捕获断路代际：扫描期间若新一轮源失败
                    // 重新开路，本次扫描不得误清它。
                    let circuitGeneration = await sourceCircuitBoard
                        .openCircuit(rootID: root.id)?.generation
                    let access: SecurityScopedLibrary
                    if let existing = scopedLibraries[root.id] {
                        access = existing
                    } else {
                        access = try await authorizeLibrary(root)
                    }
                    let result: MediaScanResult
                    let isAuthoritative: Bool
                    switch root.kind {
                    case .file:
                        // 单文件根只有一个文件，始终完整探测。
                        result = try await scanner.scanFile(fileURL: access.url)
                        try await database.applyScan(rootID: root.id, result: result)
                        isAuthoritative = result.isAuthoritativeComplete
                    case .directory:
                        switch request.mode {
                        case .full:
                            // 手动全量重扫：逐文件探测。
                            result = try await scanner.scan(rootURL: access.url)
                            try await database.applyScan(rootID: root.id, result: result)
                            isAuthoritative = result.isAuthoritativeComplete
                        case .refresh:
                            // 轻量刷新：枚举 + 元数据分类，只探测新增或变化的文件。
                            let enumeration = try scanner.enumerateRoot(rootURL: access.url)
                            let plan = try await database.planScanRefresh(
                                rootID: root.id,
                                candidates: enumeration.candidates
                            )
                            let probed = try await scanner.probeFiles(
                                rootURL: access.url,
                                candidates: plan.toProbe
                            )
                            // 权威性要求枚举完整且探测无不确定项；只有权威刷新
                            // 才能判定"未出现 = 已缺失"。
                            let authoritative = enumeration.isComplete
                                && probed.isAuthoritativeComplete
                            try await database.applyScanRefresh(
                                rootID: root.id,
                                unchangedRelativePaths: plan.unchangedRelativePaths,
                                probed: probed,
                                isAuthoritative: authoritative
                            )
                            result = probed
                            isAuthoritative = authoritative
                        }
                    }
                    try Task.checkCancellation()
                    // 权威重扫成功 = 恢复入口：定向解除该源的断路（代际匹配）。
                    if let circuitGeneration, isAuthoritative {
                        await clearSourceCircuitIfMatching(
                            rootID: root.id,
                            generation: circuitGeneration
                        )
                    }
                    if !result.errors.isEmpty {
                        scanErrors.append(contentsOf: result.errors.prefix(5))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    scanErrors.append("\(root.path)：\(error.localizedDescription)")
                }
            }
            if let segmenter {
                segmentationProgress = try await segmenter.prepareQueue()
            }
            try await refreshLibrary()
            if !scanErrors.isEmpty {
                recordBackgroundWarning(
                    id: "scan",
                    title: "部分媒体未能扫描",
                    detail: scanErrors.joined(separator: "\n")
                )
            }
            scanStatusMessage = request.mode == .full
                ? "扫描完成：\(assets.count) 个视频"
                : "媒体库检查完成：\(assets.count) 个视频"
            if segmenter != nil {
                try await prepareIndexQueue(autoStart: true)
            }
        } catch is CancellationError {
            wasCancelled = true
            scanStatusMessage = "扫描已停止；已提交的数据保持完整"
        } catch {
            scanStatusMessage = "扫描失败：\(error.localizedDescription)"
            recordBackgroundWarning(id: "scan", title: "扫描失败", detail: error.localizedDescription)
        }
    }

    // MARK: 三车道调度

    /// 三条车道只服务当前视频：内容分片完成后，证据链串行处理片段，
    /// 描述可与证据链并行；当前视频全部完成前不会进入下一个视频。

    private func startSegmentationLane() {
        guard !isBackgroundControlBarrierActive,
              !isSourceCircuitOpen,
              !isEvidencePaused,
              segmentationLaneFailure == nil,
              segmentationTask == nil,
              // Do not cache once for segmentation and then again after model
              // setup. A video enters the pipeline only when every lane needed
              // to finish it in the same cache lifetime is available.
              indexer != nil,
              let segmenter,
              segmentationProgress.pending > 0 else { return }
        isIndexing = true
        evidenceStatusMessage = "正在分析视频内容边界…"
        segmentationEventGeneration += 1
        let generation = segmentationEventGeneration
        segmentationTask = Task(priority: .utility) { [weak self] in
            do {
                let summary = try await segmenter.runUntilIdle(
                    onEvent: { [weak self] event in
                        await self?.receiveSegmentation(event, generation: generation)
                    },
                    onSourceUnavailable: { [weak self] error in
                        guard let self else { return .park }
                        return await self.handleSourceUnavailable(error)
                    }
                )
                await self?.finishSegmentationLane(summary: summary, cancelled: false)
            } catch is CancellationError {
                await self?.finishSegmentationLane(summary: nil, cancelled: true)
            } catch {
                await self?.finishSegmentationLane(summary: nil, cancelled: false, error: error)
            }
        }
    }

    private func startEvidenceLane() {
        guard !isBackgroundControlBarrierActive,
              !isSourceCircuitOpen,
              !isEvidencePaused,
              evidenceLaneFailure == nil,
              indexTask == nil,
              let indexer,
              indexingProgress.pending > 0 else { return }
        isIndexing = true
        evidenceStatusMessage = "正在准备建库…"
        evidenceEventGeneration += 1
        let generation = evidenceEventGeneration
        indexTask = Task(priority: .utility) { [weak self] in
            do {
                let summary = try await indexer.runUntilIdle(
                    onEvent: { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.receive(event, generation: generation)
                        }
                    },
                    onSourceUnavailable: { [weak self] error in
                        guard let self else { return .park }
                        return await self.handleSourceUnavailable(error)
                    }
                )
                await self?.finishEvidenceLane(summary: summary, cancelled: false)
            } catch is CancellationError {
                await self?.finishEvidenceLane(summary: nil, cancelled: true)
            } catch {
                await self?.finishEvidenceLane(summary: nil, cancelled: false, error: error)
            }
        }
    }

    private func startDescriptionLane() {
        // 先占位防重入；缓存进度在另一条车道提交新任务时可能过期，
        // 因此空闲时用实时查询决定是否需要启动。
        guard !isBackgroundControlBarrierActive,
              !isSourceCircuitOpen,
              !isDescriptionPaused,
              descriptionLaneFailure == nil,
              describeTask == nil,
              let describeQueue else { return }
        isIndexing = true
        descriptionStatusMessage = "正在准备描述…"
        descriptionEventGeneration += 1
        let generation = descriptionEventGeneration
        describeTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            if self.indexTask == nil {
                let livePending = (try? await describeQueue.progress())?.pending ?? 0
                if livePending == 0 {
                    self.describeTask = nil
                    self.isIndexing = self.segmentationTask != nil || self.indexTask != nil
                    self.descriptionStatusMessage = "描述已处理到当前队尾"
                    return
                }
            }
            do {
                let summary = try await describeQueue.runUntilIdle(
                    onEvent: { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.receiveDescribe(event, generation: generation)
                        }
                    },
                    onSourceUnavailable: { [weak self] error in
                        guard let self else { return .park }
                        return await self.handleSourceUnavailable(error)
                    }
                )
                await self.finishDescriptionLane(summary: summary, cancelled: false)
            } catch is CancellationError {
                await self.finishDescriptionLane(summary: nil, cancelled: true)
            } catch {
                await self.finishDescriptionLane(summary: nil, cancelled: false, error: error)
            }
        }
    }

    private func pauseIndexingAndWait() async {
        let tasks = [segmentationTask, indexTask, describeTask].compactMap { $0 }
        guard !tasks.isEmpty else { return }
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    private func pauseScanAndWait() async {
        guard let task = scanTask else { return }
        task.cancel()
        scanStatusMessage = "正在停止扫描…"
        await task.value
    }

    // MARK: 源不可用断路（sourceUnavailable）

    /// 车道的源不可用通知入口：开路停车并聚合成可操作告警；退火到期时
    /// 返回 .failJob，车道把该任务按普通失败处理，队列按既有语义前进。
    private func handleSourceUnavailable(_ error: SourceUnavailableError) async -> SourceUnavailableDisposition {
        let disposition = await sourceCircuitBoard.beginOpen(
            rootID: error.rootID,
            reason: error.underlyingDescription
        )
        guard disposition == .park else { return disposition }
        isSourceCircuitOpen = true
        let root = roots.first(where: { $0.id == error.rootID })
        recordBackgroundWarning(
            id: "source.\(error.rootID)",
            title: "媒体源暂时不可访问：\(root?.name ?? error.rootID)",
            detail: "\(root?.path ?? "")\n处理已暂停，未产生失败任务；源恢复后可继续。\n\(error.errorDescription ?? "")\n恢复方式：右键该媒体库“重新授权”或“重新扫描”，或点击“重试读取源”。"
        )
        statusMessage = "媒体源不可用，处理已暂停"
        return disposition
    }

    private func refreshSourceCircuitFlag() async {
        isSourceCircuitOpen = await sourceCircuitBoard.hasOpenCircuit
    }

    /// 定向恢复（重新授权 / 权威重扫）的解除入口；代际不匹配时不动新断路。
    @discardableResult
    private func clearSourceCircuitIfMatching(rootID: String, generation: Int) async -> Bool {
        guard await sourceCircuitBoard.clear(rootID: rootID, ifGeneration: generation) else {
            return false
        }
        await refreshSourceCircuitFlag()
        clearBackgroundWarning(id: "source.\(rootID)")
        return true
    }

    /// 成功物化某源的视频即复位该根的断路退火计数；车道成功事件驱动，节流无关紧要。
    private func recordSourceMaterialization(assetID: String) {
        guard let rootID = assets.first(where: { $0.id == assetID })?.rootID else { return }
        Task { [sourceCircuitBoard] in
            await sourceCircuitBoard.recordMaterialization(rootID: rootID)
        }
    }

    /// 显式恢复入口：清除全部源断路并立即重试（NAS 原地恢复、既无需重授权
    /// 也未触发重扫时使用）。断路期间没有失败任务，“重试失败任务”按钮
    /// 无法承担该职责。
    func retrySourceCircuits() {
        Task { [weak self] in
            guard let self else { return }
            await self.sourceCircuitBoard.clearAll()
            await self.refreshSourceCircuitFlag()
            for warning in self.backgroundWarnings where warning.id.hasPrefix("source.") {
                self.clearBackgroundWarning(id: warning.id)
            }
            self.statusMessage = "已重试媒体源，处理继续"
            self.startIndexing()
        }
    }

    private func receiveSegmentation(_ event: SegmentationEvent, generation: Int) async {
        guard generation == segmentationEventGeneration, segmentationTask != nil else { return }
        segmentationProgress = event.progress
        evidenceStatusMessage = "\(stageName(event.stage))：\(event.assetName)"
        scheduleDetailRefresh(matching: event.assetID)
        if event.stage == "complete" {
            recordSourceMaterialization(assetID: event.assetID)
            // The producer publishes after the new generation is committed.
            // Reconcile immediately so this video can enter ASR/OCR; the
            // producer remains gated from the next video meanwhile.
            try? await prepareIndexQueue(autoStart: true)
        }
        refreshProcessingStatusThrottled()
    }

    private func receive(_ event: IndexingEvent, generation: Int) {
        guard generation == evidenceEventGeneration, indexTask != nil else { return }
        indexingProgress = event.progress
        evidenceStatusMessage = "\(stageName(event.stage))：\(event.assetName) · 片段 \(event.segmentOrdinal + 1)"
        scheduleDetailRefresh(matching: event.assetID)
        // SegmentIndexer guarantees that `complete` is emitted after the matching
        // description job is enqueued, so no per-event database task is needed.
        if event.stage == "complete" {
            recordSourceMaterialization(assetID: event.assetID)
            if describeTask == nil {
                startDescriptionLane()
            }
        }
        refreshProcessingStatusThrottled()
    }

    private func receiveDescribe(_ event: IndexingEvent, generation: Int) {
        guard generation == descriptionEventGeneration, describeTask != nil else { return }
        describeProgress = event.progress
        descriptionStatusMessage = "\(stageName(event.stage))：\(event.assetName) · 片段 \(event.segmentOrdinal + 1)"
        scheduleDetailRefresh(matching: event.assetID)
        if event.stage == "described" {
            recordSourceMaterialization(assetID: event.assetID)
        }
        refreshProcessingStatusThrottled()
    }

    /// 处理事件每秒可达十次以上；处理状态汇总（多次分组查询加两次
    /// 全树发布）按 500ms 节流、末尾补一次，保证最终一致且不拖慢界面。
    private var processingStatusTask: Task<Void, Never>?
    private var lastProcessingStatusRefresh = Date.distantPast

    private func refreshProcessingStatusThrottled() {
        guard processingStatusTask == nil else { return }
        let elapsed = Date().timeIntervalSince(lastProcessingStatusRefresh)
        let delay = max(0, 0.5 - elapsed)
        processingStatusTask = Task { [weak self] in
            if delay > 0.01 {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            }
            guard let self else { return }
            self.processingStatusTask = nil
            self.lastProcessingStatusRefresh = Date()
            await self.refreshProcessingStatus()
        }
    }

    /// 详情页的片段状态只在选中和车道结束时整体加载；处理期间由事件
    /// 驱动节流刷新，保证“描述生成中→完成”等状态与卡片徽标一致。
    private func scheduleDetailRefresh(matching assetID: String) {
        guard selectedAsset?.id == assetID, selectedResult == nil else { return }
        assetDetailRefreshTask?.cancel()
        assetDetailRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self,
                  let asset = self.selectedAsset,
                  self.selectedResult == nil else { return }
            self.loadAssetDetail(for: asset)
        }
    }

    private func finishEvidenceLane(
        summary: IndexRunSummary?,
        cancelled: Bool,
        error: Error? = nil
    ) async {
        indexTask = nil
        if readDatabase != nil {
            try? await refreshJobs()
        }
        await finishLane(
            .evidence,
            summary: summary,
            cancelled: cancelled,
            error: error
        )
    }

    private func finishSegmentationLane(
        summary: IndexRunSummary?,
        cancelled: Bool,
        error: Error? = nil
    ) async {
        segmentationTask = nil
        if let error {
            segmentationLaneFailure = error.localizedDescription
            evidenceStatusMessage = "语义分片失败：\(error.localizedDescription)"
            recordBackgroundWarning(
                id: "lane.segmentation",
                title: "语义分片已暂停",
                detail: error.localizedDescription
            )
        } else if cancelled {
            if indexTask == nil { evidenceStatusMessage = "建库已暂停" }
        } else if let summary, summary.failed > 0 {
            if indexTask == nil { evidenceStatusMessage = "语义分片完成，\(summary.failed) 个视频失败" }
        } else if indexTask == nil {
            evidenceStatusMessage = "视频分片已处理到当前队尾"
        }
        if error == nil {
            clearBackgroundWarning(id: "lane.segmentation")
        }

        if readDatabase != nil { try? await refreshJobs() }
        var reconciliationSucceeded = true
        if !cancelled, error == nil {
            do {
                try await prepareIndexQueue(autoStart: false)
                clearBackgroundWarning(id: "lane.queue")
            } catch {
                reconciliationSucceeded = false
                segmentationLaneFailure = error.localizedDescription
                recordBackgroundWarning(
                    id: "lane.queue",
                    title: "处理队列协调失败",
                    detail: error.localizedDescription
                )
            }
        }
        let processedAny = (summary?.succeeded ?? 0) + (summary?.failed ?? 0) > 0
        let advanced = !cancelled && error == nil && reconciliationSucceeded
            ? await releaseCompletedCachedSource()
            : false
        if advanced {
            startIndexing()
        } else if processedAny {
            // A lane can be idle while another lane still owns the current
            // video. Do not spin on globally-pending jobs from later videos.
            startSegmentationLane()
            startEvidenceLane()
            startDescriptionLane()
        }
        isIndexing = segmentationTask != nil || indexTask != nil || describeTask != nil
    }

    private func finishDescriptionLane(
        summary: IndexRunSummary?,
        cancelled: Bool,
        error: Error? = nil
    ) async {
        describeTask = nil
        if readDatabase != nil {
            try? await refreshJobs()
        }
        await finishLane(
            .description,
            summary: summary,
            cancelled: cancelled,
            error: error
        )
    }

    private enum BackgroundLane {
        case evidence
        case description
    }

    private func finishLane(
        _ lane: BackgroundLane,
        summary: IndexRunSummary?,
        cancelled: Bool,
        error: Error?
    ) async {
        let laneName = lane == .evidence ? "建库" : "描述"
        let message: String
        if let error {
            message = "\(laneName)失败：\(error.localizedDescription)"
            if lane == .evidence {
                evidenceLaneFailure = error.localizedDescription
                evidenceStatusMessage = message
            } else {
                descriptionLaneFailure = error.localizedDescription
                descriptionStatusMessage = message
            }
            recordBackgroundWarning(
                id: lane == .evidence ? "lane.evidence" : "lane.description",
                title: "\(laneName)已暂停",
                detail: error.localizedDescription
            )
        } else if cancelled {
            message = "\(laneName)已暂停"
            if lane == .evidence {
                evidenceStatusMessage = message
            } else {
                descriptionStatusMessage = message
            }
        } else if let summary, summary.failed > 0 {
            message = "\(laneName)完成，\(summary.failed) 个片段失败"
            if lane == .evidence {
                evidenceStatusMessage = message
            } else {
                descriptionStatusMessage = message
            }
        } else {
            message = "\(laneName)已处理到当前队尾"
            if lane == .evidence {
                evidenceStatusMessage = message
            } else {
                descriptionStatusMessage = message
            }
        }
        if error == nil {
            clearBackgroundWarning(
                id: lane == .evidence ? "lane.evidence" : "lane.description"
            )
        }

        if let asset = selectedAsset, selectedResult == nil {
            loadAssetDetail(for: asset)
        }

        // Reconcile only discovers new work. It never resets a running claim.
        var reconciliationSucceeded = true
        if !cancelled, error == nil, indexer != nil {
            do {
                try await prepareIndexQueue(autoStart: false)
                clearBackgroundWarning(id: "lane.queue")
            } catch {
                reconciliationSucceeded = false
                let detail = error.localizedDescription
                if lane == .evidence {
                    evidenceLaneFailure = detail
                } else {
                    descriptionLaneFailure = detail
                }
                recordBackgroundWarning(
                    id: "lane.queue",
                    title: "处理队列协调失败",
                    detail: detail
                )
            }
        }
        let processedAny = (summary?.succeeded ?? 0) + (summary?.failed ?? 0) > 0
        let advanced = !cancelled && error == nil && reconciliationSucceeded
            ? await releaseCompletedCachedSource()
            : false
        if advanced {
            startIndexing()
        } else if processedAny {
            // Refresh every consumer once because completion events are
            // delivered asynchronously and may arrive after this lane exits.
            // Database gating keeps these starts on the current video.
            startSegmentationLane()
            startEvidenceLane()
            startDescriptionLane()
        }
        isIndexing = segmentationTask != nil || indexTask != nil || describeTask != nil
    }

    /// The local source is retained while any lane can still work on that
    /// video, then removed before the scheduler advances to another video.
    @discardableResult
    private func releaseCompletedCachedSource() async -> Bool {
        guard let database, let sourceCache,
              let assetID = await sourceCache.cachedAssetID() else { return false }
        let requiresEvidence = indexer != nil
        let requiresDescriptions = describeQueue != nil
        do {
            let removed = try await sourceCache.removeIfUnused(assetID: assetID) {
                try await !database.hasActiveProcessingWork(
                    assetID: assetID,
                    requiresEvidence: requiresEvidence,
                    requiresDescriptions: requiresDescriptions
                )
            }
            clearBackgroundWarning(id: "maintenance.source-cache")
            return removed
        } catch {
            recordBackgroundWarning(
                id: "maintenance.source-cache",
                title: "本地视频缓存尚未清理",
                detail: error.localizedDescription
            )
            return false
        }
    }

    private func loadAssetDetail(for asset: MediaAssetRecord) {
        assetDetailLoadTask?.cancel()
        detailGeneration += 1
        let generation = detailGeneration
        assetDetailLoadTask = Task { [weak self] in
            guard let self, let database = self.readDatabase else { return }
            do {
                async let loadedDetail = database.assetLibraryDetail(assetID: asset.id)
                async let loadedDescriptions = database.latestDescriptions(assetID: asset.id)
                let detail = try await loadedDetail
                let descriptions = try await loadedDescriptions
                try Task.checkCancellation()
                guard generation == self.detailGeneration,
                      self.selectedAsset?.id == asset.id,
                      self.selectedResult == nil else { return }
                let cached = descriptions.mapValues { self.displayed($0) }
                self.assetDetail = detail
                self.segmentDescriptions = cached
                self.assetDetailLoadTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.detailGeneration else { return }
                self.assetDetailLoadTask = nil
                self.present(error)
            }
        }
    }

    private func clearSelection() {
        detailGeneration += 1
        playerGeneration += 1
        assetDetailRefreshTask?.cancel()
        assetDetailLoadTask?.cancel()
        selectedDescriptionTask?.cancel()
        playerPreparationTask?.cancel()
        assetDetailRefreshTask = nil
        assetDetailLoadTask = nil
        selectedDescriptionTask = nil
        playerPreparationTask = nil
        selectedAsset = nil
        selectedResult = nil
        assetDetail = nil
        segmentDescriptions = [:]
        player?.pause()
        player = nil
        playerAssetID = nil
        isPlayerLoading = false
        playerError = nil
    }

    /// 帧缩略图的可访问 URL；校验路径不越过应用工作目录。
    func frameThumbnailURL(_ frame: SegmentFrameRecord) -> URL? {
        guard let workRoot else { return nil }
        let root = workRoot.standardizedFileURL
        let url = root.appending(path: frame.relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    /// 播放器资产准备与可播放性检查都在异步 AVFoundation API 中完成；
    /// 主线程只接收最终播放器，较慢或离线的远程卷不会冻结界面。
    private func play(asset: MediaAssetRecord, startMS: Int64) {
        selectedAsset = asset
        playerPreparationTask?.cancel()
        playerGeneration += 1
        let generation = playerGeneration
        guard asset.status == .ready, asset.isPlayable else {
            player = nil
            playerAssetID = nil
            isPlayerLoading = false
            playerError = asset.errorMessage ?? "该媒体当前不可播放。"
            return
        }

        // 同一视频内跳转（如点击另一个片段）：复用已打开的播放器，
        // 避免重新发起远程文件打开。
        if let existing = player, playerAssetID == asset.id {
            playerError = nil
            isPlayerLoading = true
            playerPreparationTask = Task { [weak self] in
                await self?.seekWhenReady(existing, to: startMS, generation: generation)
            }
            return
        }

        player?.pause()
        player = nil
        playerAssetID = nil
        playerError = nil
        isPlayerLoading = true
        playerPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.authorizeLibrary(for: asset)
                let url = URL(fileURLWithPath: asset.standardizedPath)
                let newPlayer = try await Self.preparePlayer(url: url)
                try Task.checkCancellation()
                guard self.playerGeneration == generation,
                      self.selectedAsset?.id == asset.id else { return }
                self.player = newPlayer
                self.playerAssetID = asset.id
                await self.seekWhenReady(newPlayer, to: startMS, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard self.playerGeneration == generation else { return }
                self.finishPlayerPreparation(error: error.localizedDescription, generation: generation)
            }
        }
    }

    private nonisolated static func preparePlayer(url: URL) async throws -> AVPlayer {
        let prepared = try await AsyncTimeout.run(for: .seconds(30), operationName: "打开视频") {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else {
                throw PlayerPreparationError.notPlayable
            }
            try Task.checkCancellation()
            return PreparedPlayer(player: AVPlayer(playerItem: AVPlayerItem(asset: asset)))
        }
        return prepared.player
    }

    /// 等待 item 就绪（轮询读取缓存属性，不做阻塞 I/O），再异步跳转。
    private func seekWhenReady(_ player: AVPlayer, to startMS: Int64, generation: Int) async {
        let deadline = Date().addingTimeInterval(30)
        var ready = false
        while Date() < deadline {
            if Task.isCancelled { return }
            if let item = player.currentItem {
                if item.status == .readyToPlay { ready = true; break }
                if item.status == .failed {
                    finishPlayerPreparation(
                        error: item.error?.localizedDescription ?? "无法打开视频，远程文件可能不可用。",
                        generation: generation
                    )
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !ready {
            finishPlayerPreparation(
                error: "打开视频超时（30 秒）：远程存储读取缓慢或已断开。",
                generation: generation
            )
            return
        }
        let time = CMTime(value: max(0, startMS), timescale: 1_000)
        _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if Task.isCancelled { return }
        finishPlayerPreparation(error: nil, generation: generation)
    }

    private func finishPlayerPreparation(error: String?, generation: Int) {
        guard generation == playerGeneration else { return }
        isPlayerLoading = false
        playerPreparationTask = nil
        if let error {
            player = nil
            playerAssetID = nil
            playerError = error
        }
    }

    private func stageName(_ stage: String) -> String {
        [
            "analyzing": "分析画面与静音边界",
            "planning": "规划语义片段",
            "committing": "保存分片代际",
            "starting": "准备",
            "audio": "读取音频与画面",
            "asr": "语音识别",
            "alignment": "句子时间定位",
            "frames": "抽取画面",
            "ocr": "识别画面文字",
            "embedding": "建立语义索引",
            "commit": "保存结果",
            "complete": "建库完成",
            "failed": "建库失败",
            "describing": "生成描述",
            "described": "描述完成",
            "describe_failed": "描述失败"
        ][stage] ?? stage
    }

    func dismissBackgroundWarning(_ warning: AppBackgroundWarning) {
        clearBackgroundWarning(id: warning.id)
    }

    private func recordBackgroundWarning(id: String, title: String, detail: String) {
        backgroundWarnings.removeAll { $0.id == id }
        backgroundWarnings.append(AppBackgroundWarning(id: id, title: title, detail: detail))
        backgroundWarnings.sort { $0.id < $1.id }
    }

    private func clearBackgroundWarning(id: String) {
        backgroundWarnings.removeAll { $0.id == id }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "发生错误"
    }
}

private enum AppLifecycleError: Error, LocalizedError {
    case databaseUnavailable
    case libraryRootUnavailable
    case missingBearerCredential(ModelRole)
    case reauthorizationTargetMismatch(expected: String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            "本地数据库尚未就绪，请稍后重试。"
        case .libraryRootUnavailable:
            "该视频所属媒体库已被移除或停用。"
        case let .missingBearerCredential(role):
            "\(role.displayName)已启用 Bearer 鉴权，请填写 API key。"
        case let .reauthorizationTargetMismatch(expected):
            "请选择原媒体库位置：\(expected)"
        }
    }
}

private enum PlayerPreparationError: Error, LocalizedError {
    case notPlayable

    var errorDescription: String? {
        "该媒体无法播放。"
    }
}
