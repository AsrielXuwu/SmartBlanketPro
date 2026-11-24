import Foundation

/// 连接策略：参考 Home Assistant 网关的「省电直连唤醒」与「常连实时监控」双模式设计
public enum BLEConnectionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case smartInstantWake = "power_save"
    case continuous = "continuous"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smartInstantWake: return "智能极速唤醒（省电推荐）"
        case .continuous: return "常连实时同步"
        }
    }

    public var description: String {
        switch self {
        case .smartInstantWake:
            return "操作或打开页面时 0.15 秒极速直连；关机闲置 10 分钟后自动休眠省电"
        case .continuous:
            return "始终维持 BLE 连接并每 15 秒静默同步物理线控器状态"
        }
    }
}

/// 蓝牙实时连接状态
public enum DeviceConnectionPhase: String, Codable, Sendable {
    case disconnected = "已休眠待命"
    case connecting   = "正在极速直连..."
    case connected    = "已直连就绪"
    case failed       = "连接未响应"

    public var isReady: Bool {
        self == .connected
    }
}

/// 单次电热毯开启运行历史记录条目（用于统计本周/本月时长、各挡位时长与绘制历史图表）
public struct BlanketUsageRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    public var durationSeconds: TimeInterval
    public var primaryGear: Int
    public var mode: BlanketHeatingMode

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        durationSeconds: TimeInterval,
        primaryGear: Int,
        mode: BlanketHeatingMode = .normal
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.durationSeconds = max(0, durationSeconds)
        self.primaryGear = min(9, max(1, primaryGear))
        self.mode = mode
    }
}

/// 运行记录清除范围选项
public enum UsageHistoryClearScope: String, CaseIterable, Identifiable, Sendable {
    case today = "仅清除今天"
    case last7Days = "最近 7 天"
    case last30Days = "最近 30 天"
    case customRange = "自定义日期时间范围"
    case allHistory = "清除全部运行数据"

    public var id: String { rawValue }
}

/// 每日运行时长图表数据点
public struct DailyUsageChartPoint: Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let label: String
    public let hours: Double
    public let dominantGear: Int
}

/// 各挡位累计运行时间统计条目
public struct GearUsageRankItem: Identifiable, Hashable, Sendable {
    public var id: Int { gear }
    public let gear: Int
    public let seconds: TimeInterval
    public let hours: Double
    public let percentage: Double
}

/// 持久化保存的电热毯设备实体与实时运行状态模型
public struct BlanketDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// CoreBluetooth 分配的 CBPeripheral UUID 字符串（用于零扫描极速直连 retrievePeripherals）
    public var peripheralUUIDString: String?
    /// 硬件 MAC 地址（用于派生 8 字节 DES 密钥：`MAC + 5700`）
    public var macAddress: String
    /// 用户自定义名称（如“主卧智能电热毯”）
    public var name: String
    /// 房间或区域标签（如“主卧”、“次卧”、“儿童房”）
    public var roomName: String
    /// 蓝牙广播原始名称（如 `JH_5700_F860`）
    public var advertisedName: String

    // MARK: - 实时硬件状态 (TLV 同步)
    public var isOn: Bool
    public var mode: BlanketHeatingMode
    public var gearLeft: Int
    public var gearRight: Int
    /// 自动关机定时（小时，1~12）
    public var timeCloseHours: Int
    /// 预约定时开机（小时，0~12，0 表示未启用）
    public var timeOpenHours: Int
    /// 剩余预约开机秒数（硬件上报 + 本地平滑推算）
    public var remainingTimeOpenSec: Int
    /// 剩余自动关机秒数（硬件上报 + 本地平滑推算）
    public var remainingTimeCloseSec: Int
    /// 自动关机倒计时目标截止时间戳（使用绝对时间锚点，切入后台再回前台绝不暂停或回跳）
    public var autoOffTargetDate: Date?
    /// 预约开机倒计时目标截止时间戳
    public var scheduledOnTargetDate: Date?

    // MARK: - 偏好记忆与智能策略
    /// 是否启用双温区同步调节
    public var syncDualZones: Bool
    /// 开机时是否自动恢复上次记忆的左右温区挡位与定时（避开硬件默认重置为 9 挡 / 12h）
    public var restoreMemoryOnPowerOn: Bool
    /// 记忆的左温区挡位 (1~9)
    public var savedGearLeft: Int
    /// 记忆的右温区挡位 (1~9)
    public var savedGearRight: Int
    /// 记忆的定时关机时长 (1~12h)
    public var savedTimeCloseHours: Int
    /// 蓝牙连接策略
    public var connectionPolicy: BLEConnectionPolicy

    // MARK: - 运行时长统计与多维遥测记录 (Requirement 5 & Requirement 7)
    /// 本次开机时间戳
    public var currentSessionStartDate: Date?
    /// 历史累计开启总秒数（跨会话持久化累计）
    public var accumulatedRuntimeSeconds: TimeInterval
    /// 历史累计开机次数
    public var totalPowerOnCount: Int
    /// 历史每次开启会话记录明细（用于统计本周/本月运行时长、绘制图表与按日期范围清除）
    public var usageRecords: [BlanketUsageRecord]
    /// 各挡位 (1~9) 累计运行秒数统计
    public var gearUsageSeconds: [Int: TimeInterval]
    /// 累计除螨模式运行次数
    public var totalMiteRemovalCount: Int
    /// 最近一次状态同步时间
    public var lastSyncDate: Date?
    /// 最近一次信号强度 (dBm)
    public var lastRSSI: Int?
    /// 最近一次 GATT 指令响应耗时 (毫秒)
    public var lastCommandLatencyMs: Int?

    public init(
        id: UUID = UUID(),
        peripheralUUIDString: String? = nil,
        macAddress: String = "8E:B2:D6:64:F8:60",
        name: String = "主卧智能电热毯",
        roomName: String = "主卧",
        advertisedName: String = "JH_Blanket_Pro",
        isOn: Bool = false,
        mode: BlanketHeatingMode = .normal,
        gearLeft: Int = 5,
        gearRight: Int = 5,
        timeCloseHours: Int = 8,
        timeOpenHours: Int = 0,
        remainingTimeOpenSec: Int = 0,
        remainingTimeCloseSec: Int = 0,
        autoOffTargetDate: Date? = nil,
        scheduledOnTargetDate: Date? = nil,
        syncDualZones: Bool = false,
        restoreMemoryOnPowerOn: Bool = true,
        savedGearLeft: Int = 5,
        savedGearRight: Int = 5,
        savedTimeCloseHours: Int = 8,
        connectionPolicy: BLEConnectionPolicy = .smartInstantWake,
        currentSessionStartDate: Date? = nil,
        accumulatedRuntimeSeconds: TimeInterval = 0,
        totalPowerOnCount: Int = 0,
        usageRecords: [BlanketUsageRecord] = [],
        gearUsageSeconds: [Int: TimeInterval] = [:],
        totalMiteRemovalCount: Int = 0,
        lastSyncDate: Date? = nil,
        lastRSSI: Int? = nil,
        lastCommandLatencyMs: Int? = nil
    ) {
        self.id = id
        self.peripheralUUIDString = peripheralUUIDString
        self.macAddress = BlanketProtocol.normalizeMAC(macAddress) ?? macAddress.uppercased()
        self.name = name
        self.roomName = roomName
        self.advertisedName = advertisedName
        self.isOn = isOn
        self.mode = mode
        self.gearLeft = gearLeft
        self.gearRight = gearRight
        self.timeCloseHours = timeCloseHours
        self.timeOpenHours = timeOpenHours
        self.remainingTimeOpenSec = remainingTimeOpenSec
        self.remainingTimeCloseSec = remainingTimeCloseSec
        self.autoOffTargetDate = autoOffTargetDate
        self.scheduledOnTargetDate = scheduledOnTargetDate
        self.syncDualZones = syncDualZones
        self.restoreMemoryOnPowerOn = restoreMemoryOnPowerOn
        self.savedGearLeft = savedGearLeft
        self.savedGearRight = savedGearRight
        self.savedTimeCloseHours = savedTimeCloseHours
        self.connectionPolicy = connectionPolicy
        self.currentSessionStartDate = currentSessionStartDate
        self.accumulatedRuntimeSeconds = accumulatedRuntimeSeconds
        self.totalPowerOnCount = totalPowerOnCount
        self.usageRecords = usageRecords
        self.gearUsageSeconds = gearUsageSeconds
        self.totalMiteRemovalCount = totalMiteRemovalCount
        self.lastSyncDate = lastSyncDate
        self.lastRSSI = lastRSSI
        self.lastCommandLatencyMs = lastCommandLatencyMs
    }

    // 兼容旧版缓存数据的容错解码
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        peripheralUUIDString = try c.decodeIfPresent(String.self, forKey: .peripheralUUIDString)
        let rawMac = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? "8E:B2:D6:64:F8:60"
        macAddress = BlanketProtocol.normalizeMAC(rawMac) ?? rawMac.uppercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "智能蓝牙电热毯"
        roomName = try c.decodeIfPresent(String.self, forKey: .roomName) ?? "主卧"
        advertisedName = try c.decodeIfPresent(String.self, forKey: .advertisedName) ?? "JH_5700_F860"
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        mode = try c.decodeIfPresent(BlanketHeatingMode.self, forKey: .mode) ?? .normal
        gearLeft = try c.decodeIfPresent(Int.self, forKey: .gearLeft) ?? 5
        gearRight = try c.decodeIfPresent(Int.self, forKey: .gearRight) ?? 5
        timeCloseHours = try c.decodeIfPresent(Int.self, forKey: .timeCloseHours) ?? 8
        timeOpenHours = try c.decodeIfPresent(Int.self, forKey: .timeOpenHours) ?? 0
        remainingTimeOpenSec = try c.decodeIfPresent(Int.self, forKey: .remainingTimeOpenSec) ?? 0
        remainingTimeCloseSec = try c.decodeIfPresent(Int.self, forKey: .remainingTimeCloseSec) ?? 0
        autoOffTargetDate = try c.decodeIfPresent(Date.self, forKey: .autoOffTargetDate)
        scheduledOnTargetDate = try c.decodeIfPresent(Date.self, forKey: .scheduledOnTargetDate)
        syncDualZones = try c.decodeIfPresent(Bool.self, forKey: .syncDualZones) ?? false
        restoreMemoryOnPowerOn = try c.decodeIfPresent(Bool.self, forKey: .restoreMemoryOnPowerOn) ?? true
        savedGearLeft = try c.decodeIfPresent(Int.self, forKey: .savedGearLeft) ?? 5
        savedGearRight = try c.decodeIfPresent(Int.self, forKey: .savedGearRight) ?? 5
        savedTimeCloseHours = try c.decodeIfPresent(Int.self, forKey: .savedTimeCloseHours) ?? 8
        connectionPolicy = try c.decodeIfPresent(BLEConnectionPolicy.self, forKey: .connectionPolicy) ?? .smartInstantWake
        currentSessionStartDate = try c.decodeIfPresent(Date.self, forKey: .currentSessionStartDate)
        accumulatedRuntimeSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .accumulatedRuntimeSeconds) ?? 0
        totalPowerOnCount = try c.decodeIfPresent(Int.self, forKey: .totalPowerOnCount) ?? 0
        usageRecords = try c.decodeIfPresent([BlanketUsageRecord].self, forKey: .usageRecords) ?? []
        gearUsageSeconds = try c.decodeIfPresent([Int: TimeInterval].self, forKey: .gearUsageSeconds) ?? [:]
        totalMiteRemovalCount = try c.decodeIfPresent(Int.self, forKey: .totalMiteRemovalCount) ?? 0
        lastSyncDate = try c.decodeIfPresent(Date.self, forKey: .lastSyncDate)
        lastRSSI = try c.decodeIfPresent(Int.self, forKey: .lastRSSI)
        lastCommandLatencyMs = try c.decodeIfPresent(Int.self, forKey: .lastCommandLatencyMs)
    }

    // MARK: - 派生温度与运行时长计算属性
    /// 左温区标称摄氏温度 (18°C ~ 45°C)
    public var temperatureLeft: Int {
        BlanketProtocol.gearToTemp(gearLeft)
    }

    /// 右温区标称摄氏温度 (18°C ~ 45°C)
    public var temperatureRight: Int {
        BlanketProtocol.gearToTemp(gearRight)
    }

    /// 当前实际生效的定时关机小时数（原版小程序除螨模式下固定锁死 2 小时关机，普通模式下为用户选择的 timeCloseHours）
    public var effectiveTimeCloseHours: Int {
        mode == .miteRemoval ? 2 : max(1, timeCloseHours)
    }

    /// 基于绝对时间戳 (`autoOffTargetDate` / `currentSessionStartDate`) 计算当前真实剩余自动关机秒数（彻底解决切入后台 Timer 暂停导致倒计时停滞回跳的问题）
    public func effectiveRemainingCloseSeconds(at now: Date = Date()) -> Int {
        guard isOn else { return 0 }
        if let target = autoOffTargetDate {
            return max(0, Int(target.timeIntervalSince(now)))
        }
        let totalSec = effectiveTimeCloseHours * 3600
        if let start = currentSessionStartDate {
            let elapsed = max(0, Int(now.timeIntervalSince(start)))
            return max(0, totalSec - elapsed)
        }
        return remainingTimeCloseSec > 0 ? remainingTimeCloseSec : totalSec
    }

    /// 基于绝对时间戳 (`scheduledOnTargetDate`) 计算当前真实剩余预约开机秒数
    public func effectiveRemainingOpenSeconds(at now: Date = Date()) -> Int {
        guard !isOn, timeOpenHours > 0 else { return 0 }
        if let target = scheduledOnTargetDate {
            return max(0, Int(target.timeIntervalSince(now)))
        }
        return remainingTimeOpenSec > 0 ? remainingTimeOpenSec : (timeOpenHours * 3600)
    }

    /// 当前会话已开启的秒数（基于开机时间戳 `currentSessionStartDate` 实时计算）
    public func currentSessionElapsedSeconds(at now: Date = Date()) -> Int {
        guard isOn else { return 0 }
        if let start = currentSessionStartDate {
            return max(0, Int(now.timeIntervalSince(start)))
        }
        let totalCloseSec = effectiveTimeCloseHours * 3600
        let rem = effectiveRemainingCloseSeconds(at: now)
        return (rem > 0 && rem <= totalCloseSec) ? (totalCloseSec - rem) : 0
    }

    /// 当前会话已开启的小时数描述
    public func currentSessionElapsedHoursString(at now: Date = Date()) -> String {
        let sec = currentSessionElapsedSeconds(at: now)
        guard sec > 0 else { return isOn ? "刚刚开启 (<1 分钟)" : "未开启 (0.0 小时)" }
        let hours = Double(sec) / 3600.0
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 {
            return String(format: "%d 小时 %02d 分 (%.1f h)", h, m, hours)
        } else {
            return String(format: "%d 分钟 (%.2f h)", max(1, m), hours)
        }
    }

    /// 紧凑版已开启时长文案（用于首页卡片胶囊）
    public func compactElapsedString(at now: Date = Date()) -> String {
        guard isOn else { return "待机中" }
        let sec = currentSessionElapsedSeconds(at: now)
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 {
            return String(format: "已开启 %dh %02dm", h, m)
        } else {
            return String(format: "已开启 %d 分钟", max(1, m))
        }
    }

    /// 历史累计开启总小时数（含当前正在进行的会话）
    public func totalHistoricalHours(at now: Date = Date()) -> Double {
        let totalSec = accumulatedRuntimeSeconds + Double(currentSessionElapsedSeconds(at: now))
        return totalSec / 3600.0
    }

    // MARK: - 多维统计分析：本周运行时长、本月运行时长、挡位排行榜与每日图表 (Requirement 7)

    /// 本周累计运行小时数（含当前进行中的会话）
    public func weeklyRuntimeHours(at now: Date = Date()) -> Double {
        let calendar = Calendar.current
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.date(byAdding: .day, value: -7, to: now)
            ?? now
        let recordedSec = usageRecords
            .filter { $0.endDate >= startOfWeek }
            .reduce(0.0) { $0 + $1.durationSeconds }
        let activeSec = isOn ? Double(currentSessionElapsedSeconds(at: now)) : 0
        return (recordedSec + activeSec) / 3600.0
    }

    /// 本周开启次数
    public func weeklySessionCount(at now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.date(byAdding: .day, value: -7, to: now)
            ?? now
        let count = usageRecords.filter { $0.endDate >= startOfWeek }.count
        return count + (isOn ? 1 : 0)
    }

    /// 本月累计运行小时数（含当前进行中的会话）
    public func monthlyRuntimeHours(at now: Date = Date()) -> Double {
        let calendar = Calendar.current
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start
            ?? calendar.date(byAdding: .day, value: -30, to: now)
            ?? now
        let recordedSec = usageRecords
            .filter { $0.endDate >= startOfMonth }
            .reduce(0.0) { $0 + $1.durationSeconds }
        let activeSec = isOn ? Double(currentSessionElapsedSeconds(at: now)) : 0
        return (recordedSec + activeSec) / 3600.0
    }

    /// 本月开启次数
    public func monthlySessionCount(at now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start
            ?? calendar.date(byAdding: .day, value: -30, to: now)
            ?? now
        let count = usageRecords.filter { $0.endDate >= startOfMonth }.count
        return count + (isOn ? 1 : 0)
    }

    /// 单次平均运行小时数
    public func averageSessionHours(at now: Date = Date()) -> Double {
        let count = max(1, totalPowerOnCount)
        guard totalPowerOnCount > 0 || isOn else { return 0 }
        return totalHistoricalHours(at: now) / Double(count)
    }

    /// 各挡位 (1~9) 运行时间统计排行（按使用时长降序排列，若均为 0 则按常用挡位排序展示）
    public func gearUsageRanking(at now: Date = Date()) -> [GearUsageRankItem] {
        var combined: [Int: TimeInterval] = [:]
        for g in 1...9 {
            combined[g] = gearUsageSeconds[g] ?? 0
        }
        // 叠加历史记录中尚未合入字典的条目
        if gearUsageSeconds.isEmpty {
            for rec in usageRecords {
                combined[rec.primaryGear, default: 0] += rec.durationSeconds
            }
        }
        // 叠加当前正在运行的会话秒数
        if isOn {
            let currentElapsed = TimeInterval(currentSessionElapsedSeconds(at: now))
            let activeGear = max(gearLeft, gearRight)
            combined[activeGear, default: 0] += currentElapsed
        }

        let totalSec = max(1.0, combined.values.reduce(0, +))
        let hasAnyUsage = combined.values.contains { $0 > 0 }

        let items: [GearUsageRankItem] = (1...9).map { g in
            let sec = combined[g] ?? 0
            let pct = hasAnyUsage ? (sec / totalSec) : 0
            return GearUsageRankItem(
                gear: g,
                seconds: sec,
                hours: sec / 3600.0,
                percentage: pct
            )
        }

        if hasAnyUsage {
            return items.sorted {
                if abs($0.seconds - $1.seconds) > 0.5 {
                    return $0.seconds > $1.seconds
                }
                return $0.gear < $1.gear
            }
        } else {
            return items
        }
    }

    /// 最常使用的首选挡位
    public func topFavoriteGear(at now: Date = Date()) -> GearUsageRankItem? {
        let ranked = gearUsageRanking(at: now)
        if let first = ranked.first, first.seconds > 0 {
            return first
        }
        return nil
    }

    private static let chartWeekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "E"
        return f
    }()

    private static let chartMonthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM/dd"
        return f
    }()

    /// 生成最近 N 天（如 7 天或 14 天）的每日运行时长图表数据
    public func dailyUsageChartPoints(days: Int = 7, at now: Date = Date()) -> [DailyUsageChartPoint] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let formatter = days <= 7 ? Self.chartWeekdayFormatter : Self.chartMonthDayFormatter

        var points: [DailyUsageChartPoint] = []
        for offset in stride(from: -(days - 1), through: 0, by: 1) {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: todayStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                continue
            }
            let dayRecords = usageRecords.filter { $0.endDate >= dayStart && $0.endDate < dayEnd }
            var daySec = dayRecords.reduce(0.0) { $0 + $1.durationSeconds }
            var domGear = dayRecords.last?.primaryGear ?? max(gearLeft, gearRight)

            if offset == 0 && isOn {
                daySec += Double(currentSessionElapsedSeconds(at: now))
                domGear = max(gearLeft, gearRight)
            }

            let rawLabel = formatter.string(from: dayStart).replacingOccurrences(of: "周", with: "")
            let label = (offset == 0 && days <= 7) ? "今日" : rawLabel
            points.append(
                DailyUsageChartPoint(
                    date: dayStart,
                    label: label,
                    hours: daySec / 3600.0,
                    dominantGear: domGear
                )
            )
        }
        return points
    }

    /// 格式化剩余自动关机时间（实时按当前墙钟时间计算，后台唤醒后零误差）
    public var formattedRemainingCloseTime: String {
        guard isOn else { return "未启动" }
        let sec = effectiveRemainingCloseSeconds()
        let h = sec / 3600
        let m = (sec % 3600) / 60
        return String(format: "%d 小时 %02d 分后自动关机", h, m)
    }

    /// 格式化剩余预约开机时间
    public var formattedRemainingOpenTime: String {
        guard timeOpenHours > 0 else { return "预约开机：关闭" }
        let sec = effectiveRemainingOpenSeconds()
        let h = sec / 3600
        let m = (sec % 3600) / 60
        return String(format: "%d 小时 %02d 分后自动开机", h, m)
    }

    /// 信号质量语义描述
    public var signalQualityDescription: String {
        guard let rssi = lastRSSI else { return "等待测速" }
        switch rssi {
        case -60...0: return "\(rssi) dBm · 极佳"
        case -75..<(-60): return "\(rssi) dBm · 良好"
        case -88..<(-75): return "\(rssi) dBm · 一般"
        default: return "\(rssi) dBm · 较弱"
        }
    }
}

/// 蓝牙扫描发现的候选设备模型
public struct DiscoveredBLEBlanket: Identifiable, Hashable, Sendable {
    public let id: UUID // CBPeripheral.identifier
    public var name: String
    public var extractedMAC: String?
    public var rssi: Int
    public var isJingHeBlanket: Bool
    public var serviceDataHex: String?
    public var lastSeen: Date

    public var displayMAC: String {
        extractedMAC ?? "连接后自动匹配或手动输入"
    }
}
