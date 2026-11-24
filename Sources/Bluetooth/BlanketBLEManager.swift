import Foundation
import CoreBluetooth
import Combine
import SwiftUI

/// 高速 CoreBluetooth 点对点缓存直连与双向状态同步引擎
/// 严格修复并增强：
/// 1. **彻底修复切后台重进 App 时设备 MAC 被其他未添加蓝牙设备篡改的问题 (Requirement 8)**：
///    - 已添加设备的 `macAddress` 受到严格保护，`didDiscover` 扫描回调中**绝不篡改**任何已存在设备的 `macAddress`；
///    - 后台重回前台重连时，优先通过已绑定的 `peripheralUUIDString` 调用 `retrievePeripherals(withIdentifiers:)` 0.15s 定向重连；
///    - 若需扫描重连，严格要求广播包 `0x5700` CRC16 解析出的 MAC 与当前设备配置的 `macAddress` 完全一致（或 `peripheral.identifier` 完全一致）才允许连接，绝不误连周边其他未添加蓝牙设备；
/// 2. **消除滚动掉帧与主线程高频 I/O (Requirement 1 & 2)**：
///    - 移除每秒 1 次的 `@Published devices` 全量广播与 `UserDefaults` 同步磁盘写入，改为低频增量更新与异步防抖落盘；
/// 3. **安全 ID 绑定与防删崩溃保护 (Requirement 6)**：
///    - 提供 `binding(for:keyPath:default:)` 安全绑定接口，彻底消除删除设备时跨 Tab 视图因 `$bleManager.devices[idx]` 数组越界引发的闪退；
/// 4. **多维运行记录与挡位时长统计及按日期时间范围清理 (Requirement 7)**。
public final class BlanketBLEManager: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = BlanketBLEManager()

    // MARK: - Published UI State
    @Published public var devices: [BlanketDevice] = [] {
        didSet { scheduleSaveDevicesToDisk() }
    }
    @Published public var activeDeviceID: UUID?
    @Published public var connectionPhases: [UUID: DeviceConnectionPhase] = [:]
    @Published public var discoveredPeripherals: [DiscoveredBLEBlanket] = []
    @Published public var isScanning: Bool = false
    @Published public var bluetoothState: CBManagerState = .unknown
    @Published public var onlyFilterJingHeDevices: Bool = true
    @Published public var lastBannerMessage: String?

    /// 切入后台时是否立即断开蓝牙连接（默认开启）
    @Published public var disconnectWhenEnteringBackground: Bool = (UserDefaults.standard.object(forKey: "com.smartblanketpro.bg_disconnect") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(disconnectWhenEnteringBackground, forKey: "com.smartblanketpro.bg_disconnect") }
    }

    // MARK: - Point-to-Point Cache
    private var centralManager: CBCentralManager?
    private var isBluetoothActivated: Bool = false
    private var activePeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredPeripheralObjects: [UUID: CBPeripheral] = [:] // CBPeripheral.identifier -> CBPeripheral
    private var controlCharacteristics: [UUID: CBCharacteristic] = [:]
    private var cachedSecretKeys: [String: (primary: Data, alt: Data)] = [:]
    private var peripheralBroadcastKeys: [UUID: Data] = [:] // CBPeripheral.identifier -> 8-byte DES Key
    private var peripheralProductIDs: [UUID: String] = [:]  // CBPeripheral.identifier -> 12-char Product ID
    private var peripheralDisplayMACs: [UUID: String] = [:] // CBPeripheral.identifier -> XX:XX:XX:XX:XX:XX
    private var verifiedWorkingKeys: [UUID: Data] = [:]     // BlanketDevice.id -> 8-byte DES Key
    private var deviceProductIDs: [UUID: String] = [:]      // BlanketDevice.id -> 12-char Product ID
    private var lastWrittenCipherPayloads: [UUID: Data] = [:]
    private var preferWriteWithoutResponse: Set<UUID> = []
    private var hasConfirmedWriteResponse: Set<UUID> = []
    private var peripheralToDeviceMap: [UUID: UUID] = [:]   // CBPeripheral.identifier -> BlanketDevice.id

    // MARK: - Pipeline & Lifecycle Tracking
    private var commandWriteStartTimes: [UUID: Date] = [:]
    private var pendingCommandsAfterConnect: [UUID: [String]] = [:]
    private var connectionContinuations: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    private var notifyReadyFallbackTasks: [UUID: Task<Void, Never>] = [:]
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var delayedQueryTasks: [UUID: Task<Void, Never>] = [:]
    private var saveDiskDebounceTask: Task<Void, Never>?
    private var isPoweringOnRestoringMemory: Set<UUID> = []
    private var hasCompletedNotifyHandshake: Set<UUID> = []
    private var lastGearAccountingDates: [UUID: Date] = [:]
    private var lastNotifiedStates: [UUID: (isOn: Bool, gearLeft: Int, gearRight: Int, mode: BlanketHeatingMode, timeClose: Int)] = [:]
    private var isAppInBackground: Bool = false
    private var runtimeTicker: AnyCancellable?

    public static let storageKey = "com.smartblanketpro.saved_devices.v3"

    private override init() {
        super.init()
        loadDevicesFromDisk()
        warmUpKeyCache()
        startRuntimeAndCountdownTicker()
    }

    // MARK: - Safe ID-Based SwiftUI Binding (彻底杜绝删除设备时 Array Index Out of Range 闪退)
    public func binding<Value>(
        for deviceID: UUID,
        keyPath: WritableKeyPath<BlanketDevice, Value>,
        default defaultValue: Value
    ) -> Binding<Value> {
        Binding(
            get: { [weak self] in
                guard let self = self,
                      let idx = self.devices.firstIndex(where: { $0.id == deviceID }) else {
                    return defaultValue
                }
                return self.devices[idx][keyPath: keyPath]
            },
            set: { [weak self] newValue in
                guard let self = self,
                      let idx = self.devices.firstIndex(where: { $0.id == deviceID }) else {
                    return
                }
                self.devices[idx][keyPath: keyPath] = newValue
            }
        )
    }

    // MARK: - Dual-Endian Key Cache & Strict MAC Matching
    private func warmUpKeyCache() {
        for dev in devices {
            _ = getCachedKeys(for: dev.macAddress)
        }
    }

    private func getCachedKeys(for mac: String) -> (primary: Data, alt: Data)? {
        let key = mac.uppercased()
        if let hit = cachedSecretKeys[key] {
            return hit
        }
        guard let primary = BlanketProtocol.getSecretKey(macAddress: key, reverseMac: true),
              let alt = BlanketProtocol.getSecretKey(macAddress: key, reverseMac: false) else {
            return nil
        }
        let pair = (primary: primary, alt: alt)
        cachedSecretKeys[key] = pair
        return pair
    }

    /// 严格校验广播包解析出的 MAC 是否与用户已保存设备的 `macAddress` 属于同一台物理设备（支持正反序比对，绝不匹配其他未添加设备）
    private func isMatchingSavedMAC(_ savedMAC: String, advertisementInfo info: BlanketProtocol.ParsedAdvertisementInfo) -> Bool {
        let cleanSaved = savedMAC
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let cleanDisplay = info.displayMAC
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
        return cleanSaved == cleanDisplay || cleanSaved == info.rawMacHex.lowercased()
    }

    /// 获取某个设备当前最权威的 8 字节 DES 密钥
    private func resolveActiveSecretKey(for deviceID: UUID) -> (active: Data, alt: Data)? {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return nil }
        let mac = devices[idx].macAddress
        let pair = getCachedKeys(for: mac)

        if let verified = verifiedWorkingKeys[deviceID] {
            return (active: verified, alt: pair?.alt ?? verified)
        }
        if let p = activePeripherals[deviceID], let bKey = peripheralBroadcastKeys[p.identifier] {
            verifiedWorkingKeys[deviceID] = bKey
            return (active: bKey, alt: pair?.alt ?? bKey)
        }
        if let uuidStr = devices[idx].peripheralUUIDString,
           let pUUID = UUID(uuidString: uuidStr),
           let bKey = peripheralBroadcastKeys[pUUID] {
            verifiedWorkingKeys[deviceID] = bKey
            return (active: bKey, alt: pair?.alt ?? bKey)
        }
        if let pair = pair {
            return (active: pair.primary, alt: pair.alt)
        }
        return nil
    }

    /// 在主视图加载完成后安全激活 CoreBluetooth
    public func activateBluetoothIfNeeded() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.activateBluetoothIfNeeded()
            }
            return
        }
        guard !isBluetoothActivated else { return }
        isBluetoothActivated = true
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - App ScenePhase Lifecycle (切入后台自动断连 & 回到前台定向重连，绝不篡改已保存设备 MAC)
    @MainActor
    public func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isAppInBackground = false
            activateBluetoothIfNeeded()
            if let activeID = activeDeviceID {
                Task { @MainActor in
                    await self.ensureConnected(deviceID: activeID)
                }
            }

        case .background:
            isAppInBackground = true
            flushAllActiveGearAccounting()
            saveDevicesToDiskImmediately()
            let activeSnap = activeDevice
            Task { @MainActor in
                await LiveActivityManager.shared.handleAppEnteredBackground(activeDevice: activeSnap)
            }
            for dev in devices {
                PushNotificationManager.shared.scheduleBackgroundHardwareTimerNotifications(for: dev)
            }
            if disconnectWhenEnteringBackground {
                for dev in devices {
                    disconnect(deviceID: dev.id)
                }
            }

        case .inactive:
            let activeSnap = activeDevice
            Task { @MainActor in
                await LiveActivityManager.shared.handleAppEnteredBackground(activeDevice: activeSnap)
            }
        @unknown default:
            break
        }
    }

    @MainActor
    public func performQuickBackgroundStatusSync(for deviceID: UUID) async {
        let connected = await ensureConnected(deviceID: deviceID, timeout: 4.5)
        if connected {
            await queryStatus(for: deviceID)
            try? await Task.sleep(nanoseconds: 650_000_000)
        }
        if isAppInBackground && disconnectWhenEnteringBackground {
            disconnect(deviceID: deviceID)
        }
    }

    // MARK: - Active Device Convenience
    public var activeDevice: BlanketDevice? {
        if let id = activeDeviceID, let match = devices.first(where: { $0.id == id }) {
            return match
        }
        return devices.first
    }

    public func connectionPhase(for deviceID: UUID) -> DeviceConnectionPhase {
        connectionPhases[deviceID] ?? .disconnected
    }

    // MARK: - Persistence (异步防抖保存，避免主线程滚动掉帧)
    public static func loadSavedDevicesSnapshot() -> [BlanketDevice] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([BlanketDevice].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return [
            BlanketDevice(
                macAddress: "8E:B2:D6:64:F8:60",
                name: "智能蓝牙电热毯",
                roomName: "主卧",
                advertisedName: "JH_5700_F860",
                isOn: false,
                mode: .normal,
                gearLeft: 5,
                gearRight: 5,
                timeCloseHours: 8,
                timeOpenHours: 0,
                syncDualZones: false,
                restoreMemoryOnPowerOn: true,
                savedGearLeft: 5,
                savedGearRight: 5,
                savedTimeCloseHours: 8,
                connectionPolicy: .smartInstantWake
            )
        ]
    }

    private func loadDevicesFromDisk() {
        let loaded = Self.loadSavedDevicesSnapshot()
        self.devices = loaded
        self.activeDeviceID = loaded.first?.id
        for dev in loaded {
            lastNotifiedStates[dev.id] = (dev.isOn, dev.gearLeft, dev.gearRight, dev.mode, dev.timeCloseHours)
            if dev.isOn {
                lastGearAccountingDates[dev.id] = Date()
            }
        }
    }

    private func scheduleSaveDevicesToDisk() {
        let snapshot = devices
        saveDiskDebounceTask?.cancel()
        saveDiskDebounceTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        }
    }

    private func saveDevicesToDiskImmediately() {
        saveDiskDebounceTask?.cancel()
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Runtime & Per-Gear Accounting + History Clearing (Requirement 7)
    private func recordGearRuntimeSlice(for deviceID: UUID, upTo now: Date = Date()) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        guard devices[idx].isOn else {
            lastGearAccountingDates.removeValue(forKey: deviceID)
            return
        }
        if let lastTick = lastGearAccountingDates[deviceID] {
            let delta = max(0, now.timeIntervalSince(lastTick))
            if delta >= 1.0 && delta <= 12 * 3600 {
                let domGear = min(9, max(1, max(devices[idx].gearLeft, devices[idx].gearRight)))
                devices[idx].gearUsageSeconds[domGear, default: 0] += delta
            }
        }
        lastGearAccountingDates[deviceID] = now
    }

    private func flushAllActiveGearAccounting(now: Date = Date()) {
        for dev in devices where dev.isOn {
            recordGearRuntimeSlice(for: dev.id, upTo: now)
        }
    }

    private func finalizeUsageSession(for deviceID: UUID, endDate: Date = Date()) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        recordGearRuntimeSlice(for: deviceID, upTo: endDate)
        lastGearAccountingDates.removeValue(forKey: deviceID)

        if let start = devices[idx].currentSessionStartDate {
            let elapsed = max(0, endDate.timeIntervalSince(start))
            if elapsed >= 5 {
                devices[idx].accumulatedRuntimeSeconds += elapsed
                let domGear = min(9, max(1, max(devices[idx].gearLeft, devices[idx].gearRight)))
                let record = BlanketUsageRecord(
                    startDate: start,
                    endDate: endDate,
                    durationSeconds: elapsed,
                    primaryGear: domGear,
                    mode: devices[idx].mode
                )
                devices[idx].usageRecords.append(record)
            }
        }
        devices[idx].currentSessionStartDate = nil
        devices[idx].remainingTimeCloseSec = 0
    }

    /// 按指定日期时间范围清除运行记录数据 (Requirement 7)
    @MainActor
    public func clearUsageHistory(
        for deviceID: UUID,
        scope: UsageHistoryClearScope,
        customStart: Date = Date(),
        customEnd: Date = Date()
    ) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let now = Date()
        let calendar = Calendar.current

        switch scope {
        case .allHistory:
            devices[idx].usageRecords.removeAll()
            devices[idx].gearUsageSeconds.removeAll()
            devices[idx].accumulatedRuntimeSeconds = 0
            devices[idx].totalPowerOnCount = devices[idx].isOn ? 1 : 0
            devices[idx].totalMiteRemovalCount = (devices[idx].isOn && devices[idx].mode == .miteRemoval) ? 1 : 0
            if devices[idx].isOn {
                devices[idx].currentSessionStartDate = now
                lastGearAccountingDates[deviceID] = now
            }

        case .today:
            let startOfToday = calendar.startOfDay(for: now)
            removeRecords(at: idx, from: startOfToday, to: now)

        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            removeRecords(at: idx, from: start, to: now)

        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            removeRecords(at: idx, from: start, to: now)

        case .customRange:
            let lower = min(customStart, customEnd)
            let upper = max(customStart, customEnd)
            removeRecords(at: idx, from: lower, to: upper)
        }

        saveDevicesToDiskImmediately()
    }

    private func removeRecords(at idx: Int, from startDate: Date, to endDate: Date) {
        let toRemove = devices[idx].usageRecords.filter { $0.endDate >= startDate && $0.endDate <= endDate }
        let removedSeconds = toRemove.reduce(0.0) { $0 + $1.durationSeconds }
        let removedCount = toRemove.count
        let removedMiteCount = toRemove.filter { $0.mode == .miteRemoval }.count

        for rec in toRemove {
            let currentGearSec = devices[idx].gearUsageSeconds[rec.primaryGear] ?? 0
            devices[idx].gearUsageSeconds[rec.primaryGear] = max(0, currentGearSec - rec.durationSeconds)
        }

        devices[idx].usageRecords.removeAll { $0.endDate >= startDate && $0.endDate <= endDate }
        devices[idx].accumulatedRuntimeSeconds = max(0, devices[idx].accumulatedRuntimeSeconds - removedSeconds)
        devices[idx].totalPowerOnCount = max(devices[idx].isOn ? 1 : 0, devices[idx].totalPowerOnCount - removedCount)
        devices[idx].totalMiteRemovalCount = max(0, devices[idx].totalMiteRemovalCount - removedMiteCount)
    }

    // MARK: - Device CRUD Management (Requirement 2 & Requirement 6)
    public func addOrUpdateDevice(
        from discovered: DiscoveredBLEBlanket,
        customName: String,
        roomName: String,
        manualMAC: String
    ) {
        activateBluetoothIfNeeded()
        let normalizedMAC = discovered.extractedMAC
            ?? peripheralDisplayMACs[discovered.id]
            ?? BlanketProtocol.normalizeMAC(manualMAC)
            ?? "8E:B2:D6:64:F8:60"
        _ = getCachedKeys(for: normalizedMAC)

        // 仅在 peripheralUUID 相同或 MAC 地址相同时更新已有设备；若用户扫描添加一个新设备则追加，绝不覆盖其他不同 MAC 的已保存设备
        if let idx = devices.firstIndex(where: {
            $0.peripheralUUIDString == discovered.id.uuidString ||
            $0.macAddress.caseInsensitiveCompare(normalizedMAC) == .orderedSame
        }) {
            let targetID = devices[idx].id
            devices[idx].peripheralUUIDString = discovered.id.uuidString
            devices[idx].macAddress = normalizedMAC
            devices[idx].name = customName.isEmpty ? discovered.name : customName
            devices[idx].roomName = roomName.isEmpty ? "卧室" : roomName
            devices[idx].advertisedName = discovered.name
            devices[idx].lastRSSI = discovered.rssi
            if let exactKey = peripheralBroadcastKeys[discovered.id] {
                verifiedWorkingKeys[targetID] = exactKey
            } else {
                verifiedWorkingKeys.removeValue(forKey: targetID)
            }
            if let pid = peripheralProductIDs[discovered.id] {
                deviceProductIDs[targetID] = pid
            }
            activeDeviceID = targetID
            saveDevicesToDiskImmediately()
            Task { @MainActor in
                await self.ensureConnected(deviceID: targetID)
            }
        } else {
            let newDevice = BlanketDevice(
                peripheralUUIDString: discovered.id.uuidString,
                macAddress: normalizedMAC,
                name: customName.isEmpty ? discovered.name : customName,
                roomName: roomName.isEmpty ? "卧室" : roomName,
                advertisedName: discovered.name,
                lastRSSI: discovered.rssi
            )
            let targetID = newDevice.id
            if let exactKey = peripheralBroadcastKeys[discovered.id] {
                verifiedWorkingKeys[targetID] = exactKey
            }
            if let pid = peripheralProductIDs[discovered.id] {
                deviceProductIDs[targetID] = pid
            }
            devices.append(newDevice)
            activeDeviceID = targetID
            saveDevicesToDiskImmediately()
            Task { @MainActor in
                await self.ensureConnected(deviceID: targetID)
            }
        }
    }

    public func addManualDevice(name: String, roomName: String, macAddress: String) {
        activateBluetoothIfNeeded()
        let normalizedMAC = BlanketProtocol.normalizeMAC(macAddress) ?? "8E:B2:D6:64:F8:60"
        _ = getCachedKeys(for: normalizedMAC)
        let newDevice = BlanketDevice(
            macAddress: normalizedMAC,
            name: name.isEmpty ? "智能蓝牙电热毯" : name,
            roomName: roomName.isEmpty ? "主卧" : roomName
        )
        devices.append(newDevice)
        activeDeviceID = newDevice.id
        saveDevicesToDiskImmediately()
    }

    public func updateDeviceMetadata(deviceID: UUID, name: String, roomName: String, macAddress: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        devices[idx].roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanMAC = BlanketProtocol.normalizeMAC(macAddress) {
            if devices[idx].macAddress.caseInsensitiveCompare(cleanMAC) != .orderedSame {
                devices[idx].macAddress = cleanMAC
                verifiedWorkingKeys.removeValue(forKey: deviceID)
                _ = getCachedKeys(for: cleanMAC)
            }
        }
        saveDevicesToDiskImmediately()
    }

    @MainActor
    public func removeDevice(deviceID: UUID) {
        disconnect(deviceID: deviceID)
        activePeripherals.removeValue(forKey: deviceID)
        verifiedWorkingKeys.removeValue(forKey: deviceID)
        deviceProductIDs.removeValue(forKey: deviceID)
        lastGearAccountingDates.removeValue(forKey: deviceID)
        lastNotifiedStates.removeValue(forKey: deviceID)
        connectionPhases.removeValue(forKey: deviceID)
        peripheralToDeviceMap = peripheralToDeviceMap.filter { $0.value != deviceID }

        let nextActiveID: UUID? = {
            if activeDeviceID == deviceID {
                return devices.first(where: { $0.id != deviceID })?.id
            }
            return activeDeviceID
        }()
        activeDeviceID = nextActiveID
        devices.removeAll { $0.id == deviceID }
        saveDevicesToDiskImmediately()
    }

    // MARK: - BLE Discovery & Scanning
    public func startScanning() {
        activateBluetoothIfNeeded()
        guard let central = centralManager, central.state == .poweredOn else {
            lastBannerMessage = "请确认已在系统设置中开启蓝牙并授予权限"
            return
        }
        isScanning = true
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    public func stopScanning() {
        let hasConnectingWaitingForScan = devices.contains {
            connectionPhases[$0.id] == .connecting && activePeripherals[$0.id] == nil
        }
        guard isScanning, !hasConnectingWaitingForScan else { return }
        centralManager?.stopScan()
        isScanning = false
    }

    // MARK: - Point-to-Point Cached Direct Connection Engine (绝不误连未添加设备、绝不篡改已保存 MAC)
    @discardableResult
    @MainActor
    public func ensureConnected(deviceID: UUID, timeout: TimeInterval = 7.5) async -> Bool {
        activateBluetoothIfNeeded()
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        let device = devices[idx]

        // 1. 当前已连接且特征值与 Notify 订阅均已就绪 -> 0ms 直接命中返回
        if let peripheral = activePeripherals[deviceID],
           peripheral.state == .connected,
           controlCharacteristics[deviceID] != nil,
           hasCompletedNotifyHandshake.contains(deviceID) {
            connectionPhases[deviceID] = .connected
            return true
        }

        guard let central = centralManager, central.state == .poweredOn else {
            connectionPhases[deviceID] = .disconnected
            return false
        }

        connectionPhases[deviceID] = .connecting

        // 2. 优先使用该设备已绑定的 peripheralUUIDString 直接从内存或系统 CoreBluetooth 缓存取回 CBPeripheral（0.15s 定向重连，不触发盲目扫描）
        var targetPeripheral: CBPeripheral? = activePeripherals[deviceID]

        if targetPeripheral == nil,
           let uuidStr = device.peripheralUUIDString,
           let pUUID = UUID(uuidString: uuidStr) {
            targetPeripheral = discoveredPeripheralObjects[pUUID]
                ?? central.retrievePeripherals(withIdentifiers: [pUUID]).first
        }

        // 3. 若该设备尚未记录 peripheralUUIDString，仅从已发现列表中匹配 MAC 地址与 device.macAddress 完全一致的设备
        if targetPeripheral == nil,
           let discoveredMatch = discoveredPeripherals.first(where: {
               guard let extMAC = $0.extractedMAC else { return false }
               return extMAC.caseInsensitiveCompare(device.macAddress) == .orderedSame
           }),
           let cachedObj = discoveredPeripheralObjects[discoveredMatch.id] {
            targetPeripheral = cachedObj
        }

        if let peripheral = targetPeripheral {
            if let bKey = peripheralBroadcastKeys[peripheral.identifier] {
                verifiedWorkingKeys[deviceID] = bKey
            }
            if let pid = peripheralProductIDs[peripheral.identifier] {
                deviceProductIDs[deviceID] = pid
            }
            bindAndConnect(peripheral: peripheral, to: deviceID)
        } else {
            // 启动扫描，didDiscover 中仅当广播包 MAC 与 device.macAddress 完全一致时才会连接
            startScanning()
        }

        return await withCheckedContinuation { continuation in
            connectionContinuations[deviceID, default: []].append(continuation)

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self = self else { return }
                if let pending = self.connectionContinuations[deviceID], !pending.isEmpty {
                    let isReady = (self.connectionPhases[deviceID] == .connected && self.controlCharacteristics[deviceID] != nil)
                    if !isReady {
                        self.connectionPhases[deviceID] = .failed
                    }
                    let list = self.connectionContinuations.removeValue(forKey: deviceID) ?? []
                    for cont in list {
                        cont.resume(returning: isReady)
                    }
                }
            }
        }
    }

    private func bindAndConnect(peripheral: CBPeripheral, to deviceID: UUID) {
        activePeripherals[deviceID] = peripheral
        discoveredPeripheralObjects[peripheral.identifier] = peripheral
        peripheralToDeviceMap[peripheral.identifier] = deviceID

        if let bKey = peripheralBroadcastKeys[peripheral.identifier] {
            verifiedWorkingKeys[deviceID] = bKey
        }
        if let pid = peripheralProductIDs[peripheral.identifier] {
            deviceProductIDs[deviceID] = pid
        }

        // 仅记录该设备对应的 CoreBluetooth peripheralUUIDString，绝不篡改用户已添加设备的 macAddress！
        if let idx = devices.firstIndex(where: { $0.id == deviceID }),
           devices[idx].peripheralUUIDString != peripheral.identifier.uuidString {
            devices[idx].peripheralUUIDString = peripheral.identifier.uuidString
        }

        peripheral.delegate = self
        if peripheral.state == .connected {
            peripheral.discoverServices(nil)
        } else {
            centralManager?.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ])
        }
    }

    public func disconnect(deviceID: UUID) {
        delayedQueryTasks[deviceID]?.cancel()
        notifyReadyFallbackTasks[deviceID]?.cancel()
        hasCompletedNotifyHandshake.remove(deviceID)
        if let peripheral = activePeripherals[deviceID], peripheral.state != .disconnected {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        controlCharacteristics.removeValue(forKey: deviceID)
        connectionPhases[deviceID] = .disconnected
    }

    // MARK: - High-Speed Point-to-Point Command Pipeline
    @discardableResult
    @MainActor
    public func sendCommand(_ cmdHex: String, to deviceID: UUID, useAltKey: Bool = false) async -> Bool {
        let ready = await ensureConnected(deviceID: deviceID)
        guard ready,
              let peripheral = activePeripherals[deviceID],
              let characteristic = controlCharacteristics[deviceID],
              let resolvedKeys = resolveActiveSecretKey(for: deviceID) else {
            pendingCommandsAfterConnect[deviceID, default: []].append(cmdHex)
            return false
        }

        let targetKey = useAltKey ? resolvedKeys.alt : resolvedKeys.active
        guard let cipherData = BlanketProtocol.encryptPayload(cmdHex: cmdHex, secretKey: targetKey) else {
            return false
        }

        writeCipherData(cipherData, to: peripheral, characteristic: characteristic, deviceID: deviceID)
        return true
    }

    private func writeCipherData(_ cipherData: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic, deviceID: UUID) {
        commandWriteStartTimes[deviceID] = Date()
        lastWrittenCipherPayloads[deviceID] = cipherData

        if preferWriteWithoutResponse.contains(deviceID) && characteristic.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(cipherData, for: characteristic, type: .withoutResponse)
        } else if characteristic.properties.contains(.write) {
            peripheral.writeValue(cipherData, for: characteristic, type: .withResponse)
            if !hasConfirmedWriteResponse.contains(deviceID) && characteristic.properties.contains(.writeWithoutResponse) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard let self = self,
                          !self.hasConfirmedWriteResponse.contains(deviceID),
                          let p = self.activePeripherals[deviceID],
                          p.state == .connected,
                          let c = self.controlCharacteristics[deviceID] else { return }
                    self.preferWriteWithoutResponse.insert(deviceID)
                    p.writeValue(cipherData, for: c, type: .withoutResponse)
                }
            }
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(cipherData, for: characteristic, type: .withoutResponse)
        } else {
            peripheral.writeValue(cipherData, for: characteristic, type: .withResponse)
        }
    }

    private func scheduleDelayedQuery(for deviceID: UUID, delaySeconds: Double = 0.55) {
        delayedQueryTasks[deviceID]?.cancel()
        delayedQueryTasks[deviceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            if self.connectionPhases[deviceID] == .connected {
                await self.queryStatus(for: deviceID)
            }
        }
    }

    private func scheduleDebouncedCommand(key: String, delayMs: UInt64 = 140, action: @escaping @MainActor () async -> Void) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    // MARK: - User & AppIntent Control Actions

    /// 1. 开关电热毯电源
    @MainActor
    public func setPower(isOn: Bool, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let wasOn = devices[idx].isOn
        let now = Date()

        if isOn && !wasOn {
            devices[idx].isOn = true
            devices[idx].currentSessionStartDate = now
            lastGearAccountingDates[deviceID] = now
            devices[idx].totalPowerOnCount += 1
            if devices[idx].restoreMemoryOnPowerOn {
                devices[idx].gearLeft = devices[idx].savedGearLeft
                devices[idx].gearRight = devices[idx].savedGearRight
                devices[idx].timeCloseHours = devices[idx].savedTimeCloseHours
            } else {
                devices[idx].gearLeft = 9
                devices[idx].gearRight = 9
                devices[idx].timeCloseHours = 12
            }
            devices[idx].remainingTimeCloseSec = devices[idx].timeCloseHours * 3600
        } else if !isOn && wasOn {
            finalizeUsageSession(for: deviceID, endDate: now)
            devices[idx].isOn = false
        } else {
            devices[idx].isOn = isOn
        }

        if isOn {
            isPoweringOnRestoringMemory.insert(deviceID)
            let ok = await sendCommand(BlanketProtocol.cmdPower(isOn: true), to: deviceID)
            if ok, let currentIdx = devices.firstIndex(where: { $0.id == deviceID }),
               devices[currentIdx].restoreMemoryOnPowerOn {
                let targetLeft = devices[currentIdx].savedGearLeft
                let targetRight = devices[currentIdx].savedGearRight
                let targetClose = devices[currentIdx].savedTimeCloseHours

                try? await Task.sleep(nanoseconds: 450_000_000)
                await sendCommand(BlanketProtocol.cmdGearLeft(targetLeft), to: deviceID)
                try? await Task.sleep(nanoseconds: 220_000_000)
                await sendCommand(BlanketProtocol.cmdGearRight(targetRight), to: deviceID)
                try? await Task.sleep(nanoseconds: 220_000_000)
                await sendCommand(BlanketProtocol.cmdTimeClose(hours: targetClose), to: deviceID)
            }
            isPoweringOnRestoringMemory.remove(deviceID)
            scheduleDelayedQuery(for: deviceID, delaySeconds: 0.65)
        } else {
            await sendCommand(BlanketProtocol.cmdPower(isOn: false), to: deviceID)
            scheduleDelayedQuery(for: deviceID, delaySeconds: 0.55)
        }
        if let updated = devices.first(where: { $0.id == deviceID }) {
            await LiveActivityManager.shared.syncActivityState(for: updated)
        }
    }

    /// 2. 调节左温区挡位 (1~9)
    public func setGearLeft(_ gear: Int, for deviceID: UUID, debounced: Bool = true) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        recordGearRuntimeSlice(for: deviceID)
        let clamped = min(9, max(1, gear))
        devices[idx].gearLeft = clamped
        devices[idx].savedGearLeft = clamped
        let shouldSyncRight = devices[idx].syncDualZones
        if shouldSyncRight {
            devices[idx].gearRight = clamped
            devices[idx].savedGearRight = clamped
        }

        let taskAction: @MainActor () async -> Void = { [weak self] in
            guard let self = self else { return }
            if let cIdx = self.devices.firstIndex(where: { $0.id == deviceID }), !self.devices[cIdx].isOn {
                let now = Date()
                self.devices[cIdx].isOn = true
                if self.devices[cIdx].currentSessionStartDate == nil {
                    self.devices[cIdx].currentSessionStartDate = now
                    self.devices[cIdx].totalPowerOnCount += 1
                }
                self.lastGearAccountingDates[deviceID] = now
                await self.sendCommand(BlanketProtocol.cmdPower(isOn: true), to: deviceID)
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            await self.sendCommand(BlanketProtocol.cmdGearLeft(clamped), to: deviceID)
            if shouldSyncRight {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self.sendCommand(BlanketProtocol.cmdGearRight(clamped), to: deviceID)
            }
            self.scheduleDelayedQuery(for: deviceID, delaySeconds: 0.55)
        }

        if debounced {
            scheduleDebouncedCommand(key: "gearLeft_\(deviceID)", action: taskAction)
        } else {
            Task { @MainActor in await taskAction() }
        }
    }

    /// 3. 调节右温区挡位 (1~9)
    public func setGearRight(_ gear: Int, for deviceID: UUID, debounced: Bool = true) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        recordGearRuntimeSlice(for: deviceID)
        let clamped = min(9, max(1, gear))
        devices[idx].gearRight = clamped
        devices[idx].savedGearRight = clamped
        let shouldSyncLeft = devices[idx].syncDualZones
        if shouldSyncLeft {
            devices[idx].gearLeft = clamped
            devices[idx].savedGearLeft = clamped
        }

        let taskAction: @MainActor () async -> Void = { [weak self] in
            guard let self = self else { return }
            if let cIdx = self.devices.firstIndex(where: { $0.id == deviceID }), !self.devices[cIdx].isOn {
                let now = Date()
                self.devices[cIdx].isOn = true
                if self.devices[cIdx].currentSessionStartDate == nil {
                    self.devices[cIdx].currentSessionStartDate = now
                    self.devices[cIdx].totalPowerOnCount += 1
                }
                self.lastGearAccountingDates[deviceID] = now
                await self.sendCommand(BlanketProtocol.cmdPower(isOn: true), to: deviceID)
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            await self.sendCommand(BlanketProtocol.cmdGearRight(clamped), to: deviceID)
            if shouldSyncLeft {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self.sendCommand(BlanketProtocol.cmdGearLeft(clamped), to: deviceID)
            }
            self.scheduleDelayedQuery(for: deviceID, delaySeconds: 0.55)
        }

        if debounced {
            scheduleDebouncedCommand(key: "gearRight_\(deviceID)", action: taskAction)
        } else {
            Task { @MainActor in await taskAction() }
        }
    }

    /// 4. 切换工作模式（普通加热 / 2小时高温除螨模式）
    @MainActor
    public func setMode(_ mode: BlanketHeatingMode, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        recordGearRuntimeSlice(for: deviceID)
        let prevMode = devices[idx].mode
        devices[idx].mode = mode
        if mode == .miteRemoval {
            devices[idx].gearLeft = 9
            devices[idx].gearRight = 9
            devices[idx].timeCloseHours = 2
            devices[idx].remainingTimeCloseSec = 2 * 3600
            if prevMode != .miteRemoval {
                devices[idx].totalMiteRemovalCount += 1
            }
        }
        if !devices[idx].isOn {
            let now = Date()
            devices[idx].isOn = true
            if devices[idx].currentSessionStartDate == nil {
                devices[idx].currentSessionStartDate = now
                devices[idx].totalPowerOnCount += 1
            }
            lastGearAccountingDates[deviceID] = now
            await sendCommand(BlanketProtocol.cmdPower(isOn: true), to: deviceID)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        await sendCommand(BlanketProtocol.cmdMode(mode), to: deviceID)
        scheduleDelayedQuery(for: deviceID, delaySeconds: 0.55)
    }

    /// 5. 设置自动关机定时 (1~12 小时)
    @MainActor
    public func setAutoOffHours(_ hours: Int, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let clamped = min(12, max(1, hours))
        devices[idx].timeCloseHours = clamped
        devices[idx].savedTimeCloseHours = clamped
        devices[idx].remainingTimeCloseSec = clamped * 3600
        await sendCommand(BlanketProtocol.cmdTimeClose(hours: clamped), to: deviceID)
        PushNotificationManager.shared.scheduleBackgroundHardwareTimerNotifications(for: devices[idx])
        scheduleDelayedQuery(for: deviceID, delaySeconds: 0.55)
    }

    /// 6. 设置预约开机定时 (0~12 小时，0 为关闭预约)
    @MainActor
    public func setScheduledOnHours(_ hours: Int, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let clamped = min(12, max(0, hours))
        devices[idx].timeOpenHours = clamped
        devices[idx].remainingTimeOpenSec = clamped * 3600
        await sendCommand(BlanketProtocol.cmdTimeOpen(hours: clamped), to: deviceID)
        PushNotificationManager.shared.scheduleBackgroundHardwareTimerNotifications(for: devices[idx])
        scheduleDelayedQuery(for: deviceID, delaySeconds: 0.55)
    }

    /// 7. 主动查询硬件实时状态
    @MainActor
    public func queryStatus(for deviceID: UUID) async {
        let pid = deviceProductIDs[deviceID]
        let primaryQueryCmd = BlanketProtocol.queryCommand(forProductId: pid)
        let syncBefore = devices.first(where: { $0.id == deviceID })?.lastSyncDate

        await sendCommand(primaryQueryCmd, to: deviceID, useAltKey: false)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self = self,
                  let idx = self.devices.firstIndex(where: { $0.id == deviceID }),
                  self.connectionPhases[deviceID] == .connected else { return }

            if self.devices[idx].lastSyncDate == syncBefore {
                if primaryQueryCmd != BlanketProtocol.queryCoreStatusCmd {
                    await self.sendCommand(BlanketProtocol.queryCoreStatusCmd, to: deviceID, useAltKey: false)
                } else if self.verifiedWorkingKeys[deviceID] == nil {
                    await self.sendCommand(BlanketProtocol.queryCoreStatusCmd, to: deviceID, useAltKey: true)
                }
            }
        }
    }

    // MARK: - Low-Overhead 15-Second Runtime & Foreground Live Sync Ticker (彻底消除每秒重绘引发的滚动掉帧)
    private func startRuntimeAndCountdownTicker() {
        runtimeTicker = Timer.publish(every: 15.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                guard let self = self else { return }
                self.tickRuntimeAndCountdowns(now: now)
            }
    }

    private func tickRuntimeAndCountdowns(now: Date) {
        for idx in devices.indices {
            let devID = devices[idx].id
            if devices[idx].isOn {
                recordGearRuntimeSlice(for: devID, upTo: now)
                if devices[idx].remainingTimeCloseSec > 0 {
                    devices[idx].remainingTimeCloseSec = max(0, devices[idx].remainingTimeCloseSec - 15)
                    if devices[idx].remainingTimeCloseSec == 0 {
                        Task { @MainActor [weak self] in
                            await self?.queryStatus(for: devID)
                        }
                    }
                }
            } else if devices[idx].timeOpenHours > 0 && devices[idx].remainingTimeOpenSec > 0 {
                devices[idx].remainingTimeOpenSec = max(0, devices[idx].remainingTimeOpenSec - 15)
                if devices[idx].remainingTimeOpenSec == 0 {
                    Task { @MainActor [weak self] in
                        await self?.queryStatus(for: devID)
                    }
                }
            }
        }

        if !isAppInBackground,
           let activeID = activeDeviceID,
           connectionPhases[activeID] == .connected {
            Task { @MainActor [weak self] in
                await self?.queryStatus(for: activeID)
            }
        }
    }

    // MARK: - Complete Notify Handshake & Trigger Initial Status Query
    @MainActor
    private func completeConnectionReady(for deviceID: UUID) {
        notifyReadyFallbackTasks[deviceID]?.cancel()
        notifyReadyFallbackTasks.removeValue(forKey: deviceID)

        let isFirstHandshake = !hasCompletedNotifyHandshake.contains(deviceID)
        hasCompletedNotifyHandshake.insert(deviceID)
        connectionPhases[deviceID] = .connected
        stopScanning()

        let list = connectionContinuations.removeValue(forKey: deviceID) ?? []
        for cont in list {
            cont.resume(returning: true)
        }

        if isFirstHandshake {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(nanoseconds: 60_000_000)
                if let queued = self.pendingCommandsAfterConnect.removeValue(forKey: deviceID), !queued.isEmpty {
                    for cmd in queued {
                        await self.sendCommand(cmd, to: deviceID)
                        try? await Task.sleep(nanoseconds: 180_000_000)
                    }
                }
                if let lastWrite = self.commandWriteStartTimes[deviceID],
                   Date().timeIntervalSince(lastWrite) < 0.25 {
                    self.scheduleDelayedQuery(for: deviceID, delaySeconds: 0.5)
                } else {
                    await self.queryStatus(for: deviceID)
                }
            }
        }
    }

    // MARK: - Handle Decrypted Notification Payload & Lock Verified DES Key
    private func handleIncomingNotification(data: Data, for deviceID: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }),
              let resolvedKeys = resolveActiveSecretKey(for: deviceID) else { return }

        var matchedHex: String?
        if let decActive = BlanketProtocol.decryptPayload(cipherBytes: data, secretKey: resolvedKeys.active, altKey: nil),
           BlanketProtocol.knownPrefixes.contains(where: { decActive.hasPrefix($0) }) {
            matchedHex = decActive
            verifiedWorkingKeys[deviceID] = resolvedKeys.active
        } else if let decAlt = BlanketProtocol.decryptPayload(cipherBytes: data, secretKey: resolvedKeys.alt, altKey: nil),
                  BlanketProtocol.knownPrefixes.contains(where: { decAlt.hasPrefix($0) }) {
            matchedHex = decAlt
            verifiedWorkingKeys[deviceID] = resolvedKeys.alt
        } else if let macPair = getCachedKeys(for: devices[idx].macAddress) {
            if let decPrimary = BlanketProtocol.decryptPayload(cipherBytes: data, secretKey: macPair.primary, altKey: nil),
               BlanketProtocol.knownPrefixes.contains(where: { decPrimary.hasPrefix($0) }) {
                matchedHex = decPrimary
                verifiedWorkingKeys[deviceID] = macPair.primary
            } else if let decFallback = BlanketProtocol.decryptPayload(cipherBytes: data, secretKey: macPair.alt, altKey: nil),
                      BlanketProtocol.knownPrefixes.contains(where: { decFallback.hasPrefix($0) }) {
                matchedHex = decFallback
                verifiedWorkingKeys[deviceID] = macPair.alt
            }
        }

        guard let decryptedHex = matchedHex else { return }
        let tlv = BlanketProtocol.parseTLVData(hexString: decryptedHex)
        guard tlv.hasValidProperty else { return }

        if let writeStart = commandWriteStartTimes[deviceID] {
            let ms = Int(Date().timeIntervalSince(writeStart) * 1000)
            devices[idx].lastCommandLatencyMs = max(5, min(999, ms))
            commandWriteStartTimes.removeValue(forKey: deviceID)
        }

        let prevSnapshot = lastNotifiedStates[deviceID]
        let wasOn = devices[idx].isOn
        let now = Date()

        if wasOn {
            recordGearRuntimeSlice(for: deviceID, upTo: now)
        }

        if let isOn = tlv.isOn {
            if !wasOn && isOn {
                devices[idx].isOn = true
                devices[idx].currentSessionStartDate = now
                lastGearAccountingDates[deviceID] = now
                devices[idx].totalPowerOnCount += 1
                devices[idx].timeOpenHours = 0
                devices[idx].remainingTimeOpenSec = 0
                if tlv.gearLeft == nil { devices[idx].gearLeft = 9 }
                if tlv.gearRight == nil { devices[idx].gearRight = 9 }
                if tlv.timeCloseHours == nil { devices[idx].timeCloseHours = 12 }
                if tlv.mode == nil { devices[idx].mode = .normal }
                if devices[idx].remainingTimeCloseSec == 0 {
                    devices[idx].remainingTimeCloseSec = devices[idx].timeCloseHours * 3600
                }
                scheduleDelayedQuery(for: deviceID, delaySeconds: 0.45)
            } else if wasOn && !isOn {
                finalizeUsageSession(for: deviceID, endDate: now)
                devices[idx].isOn = false
            } else {
                devices[idx].isOn = isOn
            }
        }

        if let mode = tlv.mode {
            let prevMode = devices[idx].mode
            devices[idx].mode = mode
            if mode == .miteRemoval {
                devices[idx].gearLeft = 9
                devices[idx].gearRight = 9
                devices[idx].timeCloseHours = 2
                if devices[idx].remainingTimeCloseSec == 0 || devices[idx].remainingTimeCloseSec > 2 * 3600 {
                    devices[idx].remainingTimeCloseSec = 2 * 3600
                }
                if prevMode != .miteRemoval {
                    devices[idx].totalMiteRemovalCount += 1
                }
            }
        }
        if let gl = tlv.gearLeft {
            devices[idx].gearLeft = gl
            if devices[idx].isOn && !isPoweringOnRestoringMemory.contains(deviceID) {
                devices[idx].savedGearLeft = gl
            }
            if !devices[idx].isOn && tlv.isOn == nil {
                scheduleDelayedQuery(for: deviceID, delaySeconds: 0.25)
            }
        }
        if let gr = tlv.gearRight {
            devices[idx].gearRight = gr
            if devices[idx].isOn && !isPoweringOnRestoringMemory.contains(deviceID) {
                devices[idx].savedGearRight = gr
            }
            if !devices[idx].isOn && tlv.isOn == nil {
                scheduleDelayedQuery(for: deviceID, delaySeconds: 0.25)
            }
        }
        if let tc = tlv.timeCloseHours, tc > 0 {
            devices[idx].timeCloseHours = tc
            if devices[idx].isOn && !isPoweringOnRestoringMemory.contains(deviceID) {
                devices[idx].savedTimeCloseHours = tc
            }
            if devices[idx].remainingTimeCloseSec == 0 && devices[idx].isOn {
                devices[idx].remainingTimeCloseSec = tc * 3600
            }
        }
        if let to = tlv.timeOpenHours {
            devices[idx].timeOpenHours = to
            if to == 0 {
                devices[idx].remainingTimeOpenSec = 0
            }
        }
        if let remOpen = tlv.remainingTimeOpenSec {
            devices[idx].remainingTimeOpenSec = remOpen
        }
        if let remClose = tlv.remainingTimeCloseSec {
            devices[idx].remainingTimeCloseSec = remClose
        }

        devices[idx].lastSyncDate = now
        let updated = devices[idx]

        if !isPoweringOnRestoringMemory.contains(deviceID), let prev = prevSnapshot {
            if prev.isOn != updated.isOn {
                if updated.isOn {
                    PushNotificationManager.shared.notifyDeviceStateChanged(
                        title: "🔥 \(updated.name) 已开启加热",
                        body: "当前模式：\(updated.mode.title) · 左温区 \(updated.gearLeft)挡 (\(updated.temperatureLeft)°C) / 右温区 \(updated.gearRight)挡 (\(updated.temperatureRight)°C)"
                    )
                } else {
                    PushNotificationManager.shared.notifyDeviceStateChanged(
                        title: "❄️ \(updated.name) 已关机",
                        body: "电热毯已停止加热并进入待机状态。"
                    )
                }
            } else if updated.isOn && (prev.gearLeft != updated.gearLeft || prev.gearRight != updated.gearRight) {
                PushNotificationManager.shared.notifyDeviceStateChanged(
                    title: "🎛 \(updated.name) 温区挡位已更新",
                    body: "左温区：\(updated.gearLeft)挡 (\(updated.temperatureLeft)°C) · 右温区：\(updated.gearRight)挡 (\(updated.temperatureRight)°C)"
                )
            } else if updated.isOn && prev.mode != updated.mode {
                PushNotificationManager.shared.notifyDeviceStateChanged(
                    title: "🔄 \(updated.name) 模式已切换",
                    body: "当前工作模式已切换为：\(updated.mode.title)"
                )
            }
        }

        lastNotifiedStates[deviceID] = (updated.isOn, updated.gearLeft, updated.gearRight, updated.mode, updated.timeCloseHours)
        PushNotificationManager.shared.scheduleBackgroundHardwareTimerNotifications(for: updated)
        Task { @MainActor in
            await LiveActivityManager.shared.syncActivityState(for: updated)
        }
    }
}

// MARK: - CBCentralManagerDelegate & CBPeripheralDelegate
extension BlanketBLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.bluetoothState = state
            if state == .poweredOn,
                !self.isAppInBackground,
                let activeID = self.activeDeviceID {
                Task { @MainActor in
                    await self.ensureConnected(deviceID: activeID)
                }
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let serviceDataDict = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]

        let isNameJ = localName.uppercased().hasPrefix("J")
        let has5700UUID = serviceUUIDs.contains {
            let u = $0.uuidString.uppercased()
            return u.contains("5700") || u.contains("5703") || u.contains("5704") || u.contains("1218")
        }
        let has5700Data = serviceDataDict.keys.contains {
            let u = $0.uuidString.uppercased()
            return u.contains("5700") || u.contains("5704") || u.contains("1218")
        }

        // 1. 优先从 0x5700 Service Data (14 字节) 执行 CRC16 校验并提取 pid 与 rawMacHex (deviceManufactCode)
        var parsedAdv: BlanketProtocol.ParsedAdvertisementInfo?
        var serviceHex: String?
        for (_, data) in serviceDataDict {
            if let info = BlanketProtocol.parseServiceData5700(data) {
                parsedAdv = info
                serviceHex = data.hexEncodedString()
                break
            }
        }

        // 2. 仅当存在 0x5703/0x5678/0x5679 格式且通过 checkCrc16(mfgData.dropFirst()) 校验时才从 ManufacturerData 提取
        if parsedAdv == nil,
           let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           let info = BlanketProtocol.parseVerifiedManufacturerData(mfgData) {
            parsedAdv = info
            serviceHex = mfgData.hexEncodedString()
        }

        let isJingHe = (parsedAdv != nil) || has5700UUID || has5700Data || isNameJ
        let rssiVal = RSSI.intValue
        let pID = peripheral.identifier

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.discoveredPeripheralObjects[pID] = peripheral

            if let info = parsedAdv {
                self.peripheralBroadcastKeys[pID] = info.exactSecretKey
                self.peripheralProductIDs[pID] = info.productId
                self.peripheralDisplayMACs[pID] = info.displayMAC
            }

            // 【核心修复 Requirement 8】：
            // 扫描回调仅匹配：
            //   (A) 已明确绑定了该 peripheral.identifier 的已保存设备，或
            //   (B) 广播包 0x5700 CRC16 解析出的硬件 MAC 与用户已保存设备的 `dev.macAddress` 完全一致的设备！
            // 绝不因为 `connectionPhases[dev.id] == .connecting` 就把周边其他未添加蓝牙设备的 MAC 覆盖到用户已保存设备上！
            if isJingHe,
               let matchedIdx = self.devices.firstIndex(where: { dev in
                   if let boundUUID = dev.peripheralUUIDString, boundUUID == pID.uuidString {
                       return true
                   }
                   if let info = parsedAdv, self.isMatchingSavedMAC(dev.macAddress, advertisementInfo: info) {
                       return true
                   }
                   return false
               }) {
                let targetID = self.devices[matchedIdx].id
                if let info = parsedAdv, self.isMatchingSavedMAC(self.devices[matchedIdx].macAddress, advertisementInfo: info) {
                    self.verifiedWorkingKeys[targetID] = info.exactSecretKey
                    self.deviceProductIDs[targetID] = info.productId
                }
                if self.connectionPhases[targetID] == .connecting && self.activePeripherals[targetID]?.state != .connected {
                    self.bindAndConnect(peripheral: peripheral, to: targetID)
                }
            }

            guard !localName.isEmpty || isJingHe else { return }

            let existing = self.discoveredPeripherals.first(where: { $0.id == pID })
            let mergedName: String = {
                if !localName.isEmpty { return localName }
                if let prevName = existing?.name, !prevName.isEmpty { return prevName }
                return "晶合蓝牙电热毯"
            }()
            let mergedMAC = parsedAdv?.displayMAC ?? self.peripheralDisplayMACs[pID] ?? existing?.extractedMAC
            let mergedServiceHex = serviceHex ?? existing?.serviceDataHex
            let mergedIsJingHe = isJingHe || (existing?.isJingHeBlanket ?? false)

            let item = DiscoveredBLEBlanket(
                id: pID,
                name: mergedName,
                extractedMAC: mergedMAC,
                rssi: (rssiVal == 127 ? (existing?.rssi ?? -65) : rssiVal),
                isJingHeBlanket: mergedIsJingHe,
                serviceDataHex: mergedServiceHex,
                lastSeen: Date()
            )

            if let existingIndex = self.discoveredPeripherals.firstIndex(where: { $0.id == pID }) {
                self.discoveredPeripherals[existingIndex] = item
            } else {
                self.discoveredPeripherals.append(item)
            }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let pID = peripheral.identifier
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let deviceID = self.peripheralToDeviceMap[pID] else { return }
            self.controlCharacteristics.removeValue(forKey: deviceID)
            self.hasCompletedNotifyHandshake.remove(deviceID)
            peripheral.delegate = self
            peripheral.readRSSI()
            peripheral.discoverServices(nil)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let pID = peripheral.identifier
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let deviceID = self.peripheralToDeviceMap[pID] else { return }
            self.connectionPhases[deviceID] = .failed
            let list = self.connectionContinuations.removeValue(forKey: deviceID) ?? []
            for cont in list { cont.resume(returning: false) }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let pID = peripheral.identifier
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let deviceID = self.peripheralToDeviceMap[pID] else { return }
            self.notifyReadyFallbackTasks[deviceID]?.cancel()
            self.hasCompletedNotifyHandshake.remove(deviceID)
            self.controlCharacteristics.removeValue(forKey: deviceID)
            self.connectionPhases[deviceID] = .disconnected

            if !self.isAppInBackground {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard let self = self, !self.isAppInBackground else { return }
                    await self.ensureConnected(deviceID: deviceID)
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristics = service.characteristics else { return }
        let pID = peripheral.identifier
        for characteristic in characteristics {
            let uuidUpper = characteristic.uuid.uuidString.uppercased()
            if uuidUpper.contains("4A486201") || uuidUpper == "6201" {
                peripheral.setNotifyValue(true, for: characteristic)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let deviceID = self.peripheralToDeviceMap[pID] else { return }
                    self.controlCharacteristics[deviceID] = characteristic

                    self.notifyReadyFallbackTasks[deviceID]?.cancel()
                    self.notifyReadyFallbackTasks[deviceID] = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 380_000_000)
                        guard !Task.isCancelled, let self = self else { return }
                        if !self.hasCompletedNotifyHandshake.contains(deviceID) {
                            self.completeConnectionReady(for: deviceID)
                        }
                    }
                }
            }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let pID = peripheral.identifier
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let deviceID = self.peripheralToDeviceMap[pID] else { return }
            let uuidUpper = characteristic.uuid.uuidString.uppercased()
            guard uuidUpper.contains("4A486201") || uuidUpper == "6201" else { return }

            Task { @MainActor [weak self] in
                self?.completeConnectionReady(for: deviceID)
            }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let pID = peripheral.identifier
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let deviceID = self.peripheralToDeviceMap[pID] else { return }
            self.handleIncomingNotification(data: data, for: deviceID)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let pID = peripheral.identifier
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let deviceID = self.peripheralToDeviceMap[pID] else { return }
            if error == nil {
                self.hasConfirmedWriteResponse.insert(deviceID)
            } else if characteristic.properties.contains(.writeWithoutResponse),
                      let fallbackData = self.lastWrittenCipherPayloads[deviceID] {
                self.preferWriteWithoutResponse.insert(deviceID)
                peripheral.writeValue(fallbackData, for: characteristic, type: .withoutResponse)
            }
            if let writeStart = self.commandWriteStartTimes[deviceID] {
                let ms = Int(Date().timeIntervalSince(writeStart) * 1000)
                if let idx = self.devices.firstIndex(where: { $0.id == deviceID }) {
                    self.devices[idx].lastCommandLatencyMs = max(5, min(999, ms))
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let rssiVal = RSSI.intValue
        let pID = peripheral.identifier
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let deviceID = self.peripheralToDeviceMap[pID],
                  let idx = self.devices.firstIndex(where: { $0.id == deviceID }),
                  rssiVal < 0 else { return }
            self.devices[idx].lastRSSI = rssiVal
        }
    }
}
