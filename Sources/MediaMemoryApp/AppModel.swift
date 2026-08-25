@preconcurrency import AVFoundation
import Combine
import Foundation
import MediaMemoryCore

struct ModelSettingsDraft: Equatable {
    var baseURL = ""
    var asrModelID = ""
    var alignerModelID = ""
    var embeddingModelID = ""
    var descriptionModelID = ""
    var pythonLauncherPath = ""
    var modelRootPath = ""
    var apiKey = ""
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

/// 展示用的片段描述：内容 + 是否由旧版 prompt/模型生成。
struct DisplayedSegmentDescription: Equatable {
    let cached: CachedSegmentDescription
    let isStale: Bool
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
    @Published private(set) var failedJobs: [IndexJobRecord] = []
    @Published private(set) var failureSummaries: [FailedJobSummary] = []
    @Published var selectedRootID: String? {
        didSet { rebuildVisibleAssetItems() }
    }
    @Published var searchQuery = ""
    @Published var settingsDraft = ModelSettingsDraft()
    @Published var isSettingsPresented = false
    @Published private(set) var isScanning = false
    @Published private(set) var isIndexing = false
    @Published private(set) var isSearching = false
    @Published private(set) var isLibraryBusy = false
    @Published private(set) var isSettingsLoading = false
    @Published private(set) var isSavingSettings = false
    @Published private(set) var startupPhase = AppStartupPhase.loadingLocalData
    @Published private(set) var statusMessage = "正在读取本地数据…"
    @Published private(set) var scanStatusMessage = "扫描空闲"
    @Published private(set) var searchStatusMessage = ""
    @Published private(set) var evidenceStatusMessage = "建库空闲"
    @Published private(set) var descriptionStatusMessage = "描述空闲"
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
    private var scanTask: Task<Void, Never>?
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
                model.scopedLibraries[root.id] = access
            }
            try await model.refreshLibrary()
            model.startScan()
        }
    }

    func startScan() {
        guard database != nil else {
            statusMessage = startupPhase == .loadingLocalData ? "正在读取本地数据…" : "数据库尚未就绪"
            return
        }
        guard scanTask == nil else { return }
        let targets = roots.filter(\.isEnabled)
        guard !targets.isEmpty else {
            statusMessage = "请先选择媒体目录"
            return
        }
        isScanning = true
        scanStatusMessage = "正在准备扫描…"
        scanTask = Task(priority: .utility) { [weak self] in
            await self?.scan(roots: targets)
        }
    }

    // MARK: 从库中删除

    /// 移除一个根（目录或单个文件）：删除其全部记录与派生数据，不触碰源文件。
    func removeRoot(_ root: LibraryRootRecord) {
        runLibraryOperation(status: "正在移除媒体库…") { model in
            guard let database = model.database, let workRoot = model.workRoot else { return }
            model.isBackgroundControlBarrierActive = true
            await model.pauseScanAndWait()
            await model.pauseIndexingAndWait()
            defer {
                model.isBackgroundControlBarrierActive = false
                model.startIndexing()
            }
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
            guard let database = model.database, let workRoot = model.workRoot else { return }
            model.isBackgroundControlBarrierActive = true
            await model.pauseScanAndWait()
            await model.pauseIndexingAndWait()
            defer {
                model.isBackgroundControlBarrierActive = false
                model.startIndexing()
            }
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
        let isStale = cached.promptVersion != DescriptionService.promptVersion
            || cached.modelID != configuration?.omlx.descriptionModelID
        return DisplayedSegmentDescription(cached: cached, isStale: isStale)
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
                descriptionModelID: configuration.omlx.descriptionModelID,
                promptVersion: DescriptionService.promptVersion
            )
            model.segmentDescriptions = [:]
            try await model.refreshJobs()
            try await model.prepareIndexQueue(autoStart: true)
            if let asset = model.selectedAsset { model.loadAssetDetail(for: asset) }
            model.statusMessage = "旧版描述已重新排队"
        }
    }

    /// 右键单个媒体库条目重新扫描（目录枚举或单文件探测）。
    func rescanRoot(_ root: LibraryRootRecord) {
        guard database != nil, scanTask == nil, libraryTask == nil else {
            statusMessage = "已有媒体库操作正在进行，请稍候"
            return
        }
        isScanning = true
        scanStatusMessage = "正在准备扫描：\(root.name)"
        scanTask = Task(priority: .utility) { [weak self] in
            await self?.scan(roots: [root])
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
        isEvidencePaused = false
        evidenceLaneFailure = nil
        segmentationLaneFailure = nil
        startSegmentationLane()
        startEvidenceLane()
    }

    func startDescriptionProcessing() {
        isDescriptionPaused = false
        descriptionLaneFailure = nil
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
        runLibraryOperation(status: "正在重新排队建库失败任务…") { model in
            if let segmenter = model.segmenter {
                model.segmentationProgress = try await segmenter.retryFailed()
            }
            if let indexer = model.indexer {
                model.indexingProgress = try await indexer.retryFailed()
            }
            try await model.refreshJobs()
            model.startEvidenceProcessing()
        }
    }

    func retryFailedDescriptionJobs() {
        runLibraryOperation(status: "正在重新排队描述失败任务…") { model in
            guard let describeQueue = model.describeQueue else { return }
            model.describeProgress = try await describeQueue.retryFailed()
            try await model.refreshJobs()
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
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
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
        settingsDraft = ModelSettingsDraft(
            baseURL: configuration.omlx.baseURL.absoluteString,
            asrModelID: configuration.omlx.asrModelID,
            alignerModelID: configuration.worker.forcedAlignerModelID,
            embeddingModelID: configuration.worker.embeddingModelID,
            descriptionModelID: configuration.omlx.descriptionModelID,
            pythonLauncherPath: configuration.worker.pythonLauncherPath,
            modelRootPath: configuration.worker.modelRootPath,
            apiKey: ""
        )
        isSettingsPresented = true
        isSettingsLoading = true
        settingsKeyLoadTask = Task { [weak self] in
            let key: String?
            do {
                key = try await KeychainStore.loadOMLXKeyAsync()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.isSettingsLoading = false
                self.settingsKeyLoadTask = nil
                self.present(error)
                return
            }
            guard !Task.isCancelled, let self, self.isSettingsPresented else { return }
            self.settingsDraft.apiKey = key ?? ""
            self.isSettingsLoading = false
            self.settingsKeyLoadTask = nil
        }
    }

    func saveSettings() {
        guard settingsSaveTask == nil, libraryTask == nil, !isSettingsLoading else {
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
        isSettingsLoading = false
        isSettingsPresented = false
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
            instanceLock = core.instanceLock
            database = core.database
            readDatabase = core.readDatabase
            searchDatabase = core.searchDatabase
            workRoot = core.workRoot
            segmenter = ContentSegmenter(database: core.database)
            // Search is available as soon as local data is open. A configured
            // runtime later enriches it with semantic ranking, but FTS never
            // waits for model setup or background indexing lifecycle.
            searchService = SearchService(
                database: core.searchDatabase,
                configuration: core.configuration
            )
            // Give semantic segmentation ownership before publishing the new
            // library snapshot. This removes scan-time compatibility ranges,
            // so newly added videos never flash fixed 20-second cards in UI.
            if let segmenter {
                segmentationProgress = try await segmenter.prepareQueue()
            }
            try await refreshLibrary()
            startupPhase = .ready
            statusMessage = roots.isEmpty ? "请选择媒体目录" : "已就绪"
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
    }

    /// nonisolated async：在全局执行器上打开数据库与读取配置，
    /// 首次迁移或 WAL 恢复再慢也不占用主线程。
    private nonisolated static func loadLocalCore() async throws -> BootstrapCore {
        let configuration = try ModelConfigurationStore.load()
        let instanceLock = try ApplicationInstanceLock(url: ApplicationPaths.instanceLockURL())
        let databaseURL = try ApplicationPaths.databaseURL()
        let database = try MediaDatabase(url: databaseURL)
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
            workRoot: workRoot
        )
    }

    /// 后台维护：孤儿文件清扫、书签解析与续期、服务配置、车道启动。
    private func bootstrapMaintenance(generation: Int) async {
        guard let database, let searchDatabase, let workRoot else { return }
        do {
            try await recoverInterruptedJobsIfNeeded()
            try Task.checkCancellation()
            segmentationProgress = try await segmenter?.prepareQueue() ?? segmentationProgress
            if scanTask == nil, libraryTask == nil, settingsSaveTask == nil {
                startSegmentationLane()
            }
            try Task.checkCancellation()
            // Queue reconciliation is local database maintenance, not model
            // work. Run it before Keychain/runtime setup so legacy saved
            // descriptions recover immediately even when models are offline.
            try await database.reconcileDescribeJobs()
            try await refreshJobs()
            try Task.checkCancellation()
            try await Self.runCleanup(database: database, workRoot: workRoot)
            try Task.checkCancellation()
            await renewBookmarks()
            try Task.checkCancellation()
            guard generation == serviceGeneration else { return }
            guard let configuration else { return }
            if let apiKey = try await KeychainStore.loadOMLXKeyAsync(), !apiKey.isEmpty {
                let services = try await Self.makeServices(
                    configuration: configuration,
                    apiKey: apiKey,
                    database: database,
                    searchDatabase: searchDatabase,
                    workRoot: workRoot
                )
                try Task.checkCancellation()
                guard generation == serviceGeneration else { return }
                install(services)
                try await prepareIndexQueue(
                    autoStart: scanTask == nil && libraryTask == nil && settingsSaveTask == nil
                )
            } else if !roots.isEmpty {
                statusMessage = "全文搜索已可用；配置 oMLX 后启用语义检索和后台建库"
            }
            if generation == serviceGeneration { maintenanceTask = nil }
        } catch is CancellationError {
            if generation == serviceGeneration { maintenanceTask = nil }
        } catch {
            guard generation == serviceGeneration else { return }
            maintenanceTask = nil
            present(error)
        }
    }

    private nonisolated static func runCleanup(
        database: MediaDatabase,
        workRoot: URL
    ) async throws {
        try ApplicationPaths.cleanupAbandonedRuns(in: workRoot)
        try Task.checkCancellation()
        try ApplicationPaths.cleanupAbandonedPrefetch(in: workRoot)
        try Task.checkCancellation()
        try ApplicationPaths.cleanupUnreferencedFrames(
            in: workRoot,
            referencedRelativePaths: try await database.referencedFrameRelativePaths()
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

    /// 书签解析可能触达慢速或离线的远程卷，逐个在后台线程进行；
    /// 单个失败只提示，不阻塞其他根。
    private func renewBookmarks() async {
        guard let database else { return }
        for root in roots where root.isEnabled {
            guard !Task.isCancelled, libraryTask == nil else { return }
            do {
                let access = try await LibraryAuthorization.resolveAsync(bookmark: root.bookmark)
                guard !Task.isCancelled,
                      libraryTask == nil,
                      roots.contains(where: { $0.id == root.id && $0.isEnabled }) else { return }
                scopedLibraries[root.id] = access
                if access.isBookmarkStale {
                    let renewed = try await LibraryAuthorization.createReadOnlyBookmarkAsync(
                        for: access.url
                    )
                    guard !Task.isCancelled,
                          libraryTask == nil,
                          roots.contains(where: { $0.id == root.id && $0.isEnabled }) else { return }
                    try await database.updateLibraryRootBookmark(id: root.id, bookmark: renewed)
                }
            } catch {
                guard !Task.isCancelled,
                      libraryTask == nil,
                      roots.contains(where: { $0.id == root.id && $0.isEnabled }) else { return }
                errorMessage = "目录或文件授权已经失效：\(root.path)\n\(error.localizedDescription)"
            }
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
            guard let baseURL = URL(string: draft.baseURL),
                  ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
                  !draft.asrModelID.isEmpty,
                  !draft.alignerModelID.isEmpty,
                  !draft.embeddingModelID.isEmpty,
                  !draft.descriptionModelID.isEmpty else {
                throw SettingsValidationError.invalidValues
            }
            guard let database, let searchDatabase, let workRoot else { return }
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

            let newConfiguration = ModelConfiguration(
                schemaVersion: 1,
                omlx: .init(
                    baseURL: baseURL,
                    asrModelID: draft.asrModelID,
                    descriptionModelID: draft.descriptionModelID
                ),
                worker: .init(
                    forcedAlignerModelID: draft.alignerModelID,
                    embeddingModelID: draft.embeddingModelID,
                    pythonLauncherPath: draft.pythonLauncherPath,
                    modelRootPath: draft.modelRootPath
                )
            )
            let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let services = try await Self.makeServices(
                configuration: newConfiguration,
                apiKey: apiKey,
                database: database,
                searchDatabase: searchDatabase,
                workRoot: workRoot
            )
            try Task.checkCancellation()
            try await ModelConfigurationStore.saveAsync(newConfiguration)
            try await KeychainStore.saveOMLXKeyAsync(apiKey)
            try Task.checkCancellation()
            guard generation == serviceGeneration else { return }
            configuration = newConfiguration
            install(services)
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
            isSettingsPresented = false
            statusMessage = "模型设置已保存"
            try await prepareIndexQueue(autoStart: false)
        } catch is CancellationError {
            statusMessage = "模型设置保存已停止"
        } catch {
            present(error)
        }
    }

    private nonisolated static func makeServices(
        configuration: ModelConfiguration,
        apiKey: String,
        database: MediaDatabase,
        searchDatabase: MediaDatabase,
        workRoot: URL
    ) async throws -> ConfiguredServices {
        try Task.checkCancellation()
        let runtime = try LocalModelRuntime(
            configuration: configuration,
            apiKey: apiKey,
            workRoot: workRoot
        )
        let indexer = SegmentIndexer(
            database: database,
            configuration: configuration,
            runtime: runtime,
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
            workRoot: workRoot
        )
        let describeQueue = DescriptionQueue(
            database: database,
            descriptionService: descriptionService
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
            descriptionModelID: configuration?.omlx.descriptionModelID,
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

        var queue = VideoQueueSummary()
        queue.total = assets.count
        for asset in assets {
            guard let summary = summaries[asset.id] else {
                queue.notStarted += 1
                continue
            }
            if summary.segmentationStatus == .running
                || summary.evidenceRunning || summary.describeRunning {
                queue.inProgress += 1
            } else if summary.failedCount > 0 {
                queue.failed += 1
            } else if summary.segmentationStatus == .pending
                || summary.evidencePending > 0 || summary.describePending > 0 {
                queue.waiting += 1
            } else if summary.totalSegments == 0 {
                queue.notStarted += 1
            } else if summary.evidenceSucceeded >= summary.totalSegments,
                      summary.describeSucceeded >= summary.totalSegments {
                queue.completed += 1
            } else {
                // 车道都空闲但产物不完整（例如描述任务缺队）：
                // 等待 reconcile 补齐，期间按待处理显示，不误报完成。
                queue.waiting += 1
            }
        }
        videoQueue = queue
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

    private func scan(roots rootsToScan: [LibraryRootRecord]) async {
        errorMessage = nil
        defer {
            isScanning = false
            scanTask = nil
        }

        do {
            guard let database else { throw AppLifecycleError.databaseUnavailable }
            var scanErrors: [String] = []
            for (index, root) in rootsToScan.enumerated() {
                try Task.checkCancellation()
                scanStatusMessage = "正在扫描 \(index + 1)/\(rootsToScan.count)：\(root.name)"
                do {
                    let access: SecurityScopedLibrary
                    if let existing = scopedLibraries[root.id] {
                        access = existing
                    } else {
                        access = try await LibraryAuthorization.resolveAsync(bookmark: root.bookmark)
                        scopedLibraries[root.id] = access
                    }
                    let result: MediaScanResult
                    switch root.kind {
                    case .directory:
                        result = try await scanner.scan(rootURL: access.url)
                    case .file:
                        result = try await scanner.scanFile(fileURL: access.url)
                    }
                    try Task.checkCancellation()
                    try await database.applyScan(rootID: root.id, result: result)
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
                errorMessage = scanErrors.joined(separator: "\n")
            }
            scanStatusMessage = "扫描完成：\(assets.count) 个视频"
            if segmenter != nil {
                try await prepareIndexQueue(autoStart: true)
            }
        } catch is CancellationError {
            scanStatusMessage = "扫描已停止；已提交的数据保持完整"
        } catch {
            scanStatusMessage = "扫描失败：\(error.localizedDescription)"
            errorMessage = scanStatusMessage
        }
    }

    // MARK: 三车道调度

    /// 内容分片是轻量生产者，证据与描述是模型消费者。三者独立失败；
    /// 每个视频的分片完成后即可进入证据队列，不必等待其余视频。

    private func startSegmentationLane() {
        guard !isBackgroundControlBarrierActive,
              !isEvidencePaused,
              segmentationLaneFailure == nil,
              segmentationTask == nil,
              let segmenter,
              segmentationProgress.pending > 0 else { return }
        isIndexing = true
        evidenceStatusMessage = "正在分析视频内容边界…"
        segmentationEventGeneration += 1
        let generation = segmentationEventGeneration
        segmentationTask = Task(priority: .utility) { [weak self] in
            do {
                let summary = try await segmenter.runUntilIdle { [weak self] event in
                    await self?.receiveSegmentation(event, generation: generation)
                }
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
                let summary = try await indexer.runUntilIdle { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.receive(event, generation: generation)
                    }
                }
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
                let summary = try await describeQueue.runUntilIdle { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.receiveDescribe(event, generation: generation)
                    }
                }
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

    private func receiveSegmentation(_ event: SegmentationEvent, generation: Int) async {
        guard generation == segmentationEventGeneration, segmentationTask != nil else { return }
        segmentationProgress = event.progress
        evidenceStatusMessage = "\(stageName(event.stage))：\(event.assetName)"
        scheduleDetailRefresh(matching: event.assetID)
        if event.stage == "complete" {
            // The producer publishes after the new generation is committed.
            // Reconcile immediately so this video can enter ASR/OCR while the
            // producer analyzes the next video.
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
        if event.stage == "complete", describeTask == nil {
            startDescriptionLane()
        }
        refreshProcessingStatusThrottled()
    }

    private func receiveDescribe(_ event: IndexingEvent, generation: Int) {
        guard generation == descriptionEventGeneration, describeTask != nil else { return }
        describeProgress = event.progress
        descriptionStatusMessage = "\(stageName(event.stage))：\(event.assetName) · 片段 \(event.segmentOrdinal + 1)"
        scheduleDetailRefresh(matching: event.assetID)
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
            errorMessage = evidenceStatusMessage
        } else if cancelled {
            if indexTask == nil { evidenceStatusMessage = "建库已暂停" }
        } else if let summary, summary.failed > 0 {
            if indexTask == nil { evidenceStatusMessage = "语义分片完成，\(summary.failed) 个视频失败" }
        } else if indexTask == nil {
            evidenceStatusMessage = "视频分片已处理到当前队尾"
        }

        if readDatabase != nil { try? await refreshJobs() }
        if !cancelled, error == nil {
            try? await prepareIndexQueue(autoStart: false)
        }
        if !isBackgroundControlBarrierActive,
           !isEvidencePaused,
           segmentationLaneFailure == nil,
           segmentationProgress.pending > 0 {
            startSegmentationLane()
        }
        if !isBackgroundControlBarrierActive,
           !isEvidencePaused,
           evidenceLaneFailure == nil,
           indexingProgress.pending > 0 {
            startEvidenceLane()
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
            errorMessage = message
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

        if let asset = selectedAsset, selectedResult == nil {
            loadAssetDetail(for: asset)
        }

        // Reconcile only discovers new work. It never resets a running claim.
        if !cancelled, error == nil, indexer != nil {
            try? await prepareIndexQueue(autoStart: false)
        }
        if !isBackgroundControlBarrierActive,
           !isEvidencePaused,
           evidenceLaneFailure == nil,
           indexingProgress.pending > 0 {
            startEvidenceLane()
        }
        if !isBackgroundControlBarrierActive,
           !isDescriptionPaused,
           descriptionLaneFailure == nil,
           describeProgress.pending > 0 {
            startDescriptionLane()
        }
        isIndexing = segmentationTask != nil || indexTask != nil || describeTask != nil
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
        let url = URL(fileURLWithPath: asset.standardizedPath)
        playerPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
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

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "发生错误"
    }
}

private enum SettingsValidationError: Error, LocalizedError {
    case invalidValues

    var errorDescription: String? {
        "模型设置不完整，或 oMLX 地址不是有效的 http/https 地址。"
    }
}

private enum AppLifecycleError: Error, LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        "本地数据库尚未就绪，请稍后重试。"
    }
}

private enum PlayerPreparationError: Error, LocalizedError {
    case notPlayable

    var errorDescription: String? {
        "该媒体无法播放。"
    }
}
