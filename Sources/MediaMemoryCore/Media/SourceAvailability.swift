import Foundation

/// 源（NAS 卷 / 授权目录）暂时不可访问。授权失败与卷离线在源缓存边界被
/// 归一化为此类型；单视频自身的问题（内容变化、缓存校验失败、本地容量
/// 不足）不会以它上报。
public struct SourceUnavailableError: Error, LocalizedError, Sendable {
    public let rootID: String
    public let underlyingDescription: String

    public init(rootID: String, underlying: Error) {
        self.rootID = rootID
        self.underlyingDescription = underlying.localizedDescription
    }

    public var errorDescription: String? {
        "媒体源暂时不可访问（可能已断连或需要重新授权）：\(underlyingDescription)"
    }
}

/// 车道收到 SourceUnavailableError 后的处置：停车（默认）或降级为该任务自身失败。
public enum SourceUnavailableDisposition: Sendable, Equatable {
    case park
    case failJob
}

public typealias SourceUnavailableHandler =
    @Sendable (SourceUnavailableError) async -> SourceUnavailableDisposition

func resolveSourceDisposition(
    _ handler: SourceUnavailableHandler?,
    _ error: SourceUnavailableError
) async -> SourceUnavailableDisposition {
    guard let handler else { return .park }
    return await handler(error)
}

/// 源不可用断路板：记录当前因“整个源暂时不可访问”而停车的媒体根。
/// 独立于用户主动暂停语义；车道启动守卫与三个恢复入口共用这一份状态。
///
/// 退火规则：一次解除若其后没有任何成功物化，计为一个“无进展恢复
/// 周期”；同一根累计两个周期后再遇源不可用不再停车，降级为单任务失败，
/// 使坏扇区类活锁有界化。该源任一次成功物化即清零。
public actor SourceCircuitBoard {
    public struct OpenCircuit: Equatable, Sendable {
        public let rootID: String
        public let generation: Int
        public let reason: String
    }

    private var circuits: [String: OpenCircuit] = [:]
    private var badRecoveryCycles: [String: Int] = [:]
    private var generations: [String: Int] = [:]
    private static let downgradeAfterBadCycles = 2

    public init() {}

    /// 尝试开路。已开路时幂等并保留首次原因；退火到期时返回 .failJob 且
    /// 不建立断路。
    public func beginOpen(rootID: String, reason: String) -> SourceUnavailableDisposition {
        if circuits[rootID] != nil { return .park }
        guard (badRecoveryCycles[rootID] ?? 0) < Self.downgradeAfterBadCycles else {
            return .failJob
        }
        let generation = (generations[rootID] ?? 0) + 1
        generations[rootID] = generation
        circuits[rootID] = OpenCircuit(rootID: rootID, generation: generation, reason: reason)
        return .park
    }

    public func openCircuit(rootID: String) -> OpenCircuit? {
        circuits[rootID]
    }

    public func isBlocked(rootID: String) -> Bool {
        circuits[rootID] != nil
    }

    public func blockedRootIDs() -> [String] {
        circuits.keys.sorted()
    }

    public var hasOpenCircuit: Bool {
        !circuits.isEmpty
    }

    /// 定向恢复（重新授权 / 权威重扫）的解除入口：代际必须匹配，防止旧的
    /// 恢复回调误清更新一轮断路。
    @discardableResult
    public func clear(rootID: String, ifGeneration generation: Int) -> Bool {
        guard let circuit = circuits[rootID], circuit.generation == generation else {
            return false
        }
        circuits[rootID] = nil
        badRecoveryCycles[rootID] = (badRecoveryCycles[rootID] ?? 0) + 1
        return true
    }

    /// 显式重试入口：解除全部断路。用户动作即最新意图，不做代际校验；
    /// 各根按与 clear 相同的规则累计无进展恢复周期。
    public func clearAll() {
        for rootID in circuits.keys {
            circuits[rootID] = nil
            badRecoveryCycles[rootID] = (badRecoveryCycles[rootID] ?? 0) + 1
        }
    }

    /// 该源任一视频成功物化：退火计数清零。
    public func recordMaterialization(rootID: String) {
        badRecoveryCycles[rootID] = 0
    }
}
