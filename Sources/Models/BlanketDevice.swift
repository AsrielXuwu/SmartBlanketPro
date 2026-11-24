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
            return "始终维持 BLE 连接并每 25 秒静默同步物理线控器状态"
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
    /// 剩余预约开机秒数（硬件上报 + 本地秒级平滑推算）
    public var remainingTimeOpenSec: Int
    /// 剩余自动关机秒数（硬件上报 + 本地秒级平滑推算）
    public var remainingTimeCloseSec: Int

    // MARK: - 偏好记忆与智能策略 (参考 ha_mqtt_bridge.py)
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

    // MARK: - 运行时长统计与状态遥测 (Requirement 5)
    /// 本次开机时间戳（用于精确计算“当前已经开启了多少小时/分钟”）
    public var currentSessionStartDate: Date?
    /// 历史累计开启总秒数（跨会话持久化累计）
    public var accumulatedRuntimeSeconds: TimeInterval
    /// 历史累计开机次数
    public var totalPowerOnCount: Int
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
        syncDualZones: Bool = false,
        restoreMemoryOnPowerOn: Bool = true,
        savedGearLeft: Int = 5,
        savedGearRight: Int = 5,
        savedTimeCloseHours: Int = 8,
        connectionPolicy: BLEConnectionPolicy = .smartInstantWake,
        currentSessionStartDate: Date? = nil,
        accumulatedRuntimeSeconds: TimeInterval = 0,
        totalPowerOnCount: Int = 0,
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
        self.syncDualZones = syncDualZones
        self.restoreMemoryOnPowerOn = restoreMemoryOnPowerOn
        self.savedGearLeft = savedGearLeft
        self.savedGearRight = savedGearRight
        self.savedTimeCloseHours = savedTimeCloseHours
        self.connectionPolicy = connectionPolicy
        self.currentSessionStartDate = currentSessionStartDate
        self.accumulatedRuntimeSeconds = accumulatedRuntimeSeconds
        self.totalPowerOnCount = totalPowerOnCount
        self.lastSyncDate = lastSyncDate
        self.lastRSSI = lastRSSI
        self.lastCommandLatencyMs = lastCommandLatencyMs
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

    /// 当前会话已开启的秒数（优先结合硬件倒计时差值与本地开机时间戳，确保物理线控开机也能准确推算）
    public func currentSessionElapsedSeconds(at now: Date = Date()) -> Int {
        guard isOn else { return 0 }
        // 如果硬件上报了剩余关机秒数，且小于设定的总关机秒数，可交叉校准已开启时长
        let totalCloseSec = max(1, timeCloseHours) * 3600
        let hardwareElapsedSec = (remainingTimeCloseSec > 0 && remainingTimeCloseSec <= totalCloseSec)
            ? (totalCloseSec - remainingTimeCloseSec)
            : 0

        if let start = currentSessionStartDate {
            let localElapsed = max(0, Int(now.timeIntervalSince(start)))
            return max(localElapsed, hardwareElapsedSec)
        }
        return hardwareElapsedSec
    }

    /// 当前会话已开启的小时数（保留 1 位小数，如 `2.4 小时`）
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

    /// 格式化剩余自动关机时间
    public var formattedRemainingCloseTime: String {
        guard isOn else { return "未启动" }
        let sec = remainingTimeCloseSec > 0 ? remainingTimeCloseSec : (timeCloseHours * 3600)
        let h = sec / 3600
        let m = (sec % 3600) / 60
        return String(format: "%d 小时 %02d 分后自动关机", h, m)
    }

    /// 格式化剩余预约开机时间
    public var formattedRemainingOpenTime: String {
        guard timeOpenHours > 0 else { return "未设置预约开机" }
        let sec = remainingTimeOpenSec > 0 ? remainingTimeOpenSec : (timeOpenHours * 3600)
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
