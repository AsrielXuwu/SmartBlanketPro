import Foundation
import CoreBluetooth
import Combine
import SwiftUI

/// 高速 CoreBluetooth 点对点缓存直连与双向状态同步引擎
/// 异步多线程架构：
/// - 所有 CoreBluetooth 扫描/连接/特征值读写、DES 加解密、CRC16 校验与 TLV 解析均在专用高优先级后台串行队列 (`bleQueue`) 执行；
/// - 主线程仅负责轻量 UI 乐观状态更新，绝不阻塞主线程或触发高频无效 `@Published` 全量重绘；
/// - 收到硬件状态回包时先在后台完成解密与差异比对，仅当 UI 可见状态确实发生变化时才派发回主线程刷新界面。
public final class BlanketBLEManager: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = BlanketBLEManager()

    // MARK: - Published UI State (Main Thread Only)
    @Published public var devices: [BlanketDevice] = [] {
        didSet { scheduleSaveDevicesToDisk() }
    }
    @Published public var activeDeviceID: UUID? {
        didSet {
            let id = activeDeviceID
            bleQueue.async { [weak self] in
                self?.bleActiveDeviceID = id
            }
        }
    }
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

    // MARK: - Dedicated BLE Background Queue & Isolated State (bleQueue Only)
    private let bleQueue = DispatchQueue(label: "com.smartblanketpro.ble.queue", qos: .userInitiated)
    private var centralManager: CBCentralManager?
    private var isBluetoothActivated: Bool = false
    private var bleIsScanning: Bool = false
    private var bleIsAppInBackground: Bool = false
    private var bleActiveDeviceID: UUID?
    private var bleConnectionPhases: [UUID: DeviceConnectionPhase] = [:]
    private var bleDeviceRecords: [UUID: (mac: String, peripheralUUID: String?)] = [:]

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

    private var commandWriteStartTimes: [UUID: Date] = [:]
    private var pendingCommandsAfterConnect: [UUID: [String]] = [:]
    private var connectionContinuations: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    private var notifyReadyFallbackItems: [UUID: DispatchWorkItem] = [:]
    private var delayedQueryWorkItems: [UUID: DispatchWorkItem] = [:]
    private var hasCompletedNotifyHandshake: Set<UUID> = []
    private var lastDiscoveredUIUpdateDates: [UUID: Date] = [:]
    private var lastDiscoveredCache: [UUID: DiscoveredBLEBlanket] = [:]
    private var lastReportedRSSI: [UUID: Int] = [:]
    private var lastLatencyReport: [UUID: (ms: Int, date: Date)] = [:]
    private var lastBLEProcessedSyncDates: [UUID: Date] = [:]

    // MARK: - Main-Thread Lifecycle & Persistence Tracking
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var saveDiskDebounceTask: Task<Void, Never>?
    private var isPoweringOnRestoringMemory: Set<UUID> = []
    private var isExitingMiteRestoringState: Set<UUID> = []
    private var lastGearAccountingDates: [UUID: Date] = [:]
    private var lastNotifiedStates: [UUID: (isOn: Bool, gearLeft: Int, gearRight: Int, mode: BlanketHeatingMode, timeClose: Int)] = [:]
    private var isAppInBackground: Bool = false
    private var runtimeTicker: AnyCancellable?

    public static let storageKey = "com.smartblanketpro.saved_devices.v3"

    private override init() {
        super.init()
        loadDevicesFromDisk()
        syncDeviceRecordsToBLEQueue()
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

    private func syncDeviceRecordsToBLEQueue() {
        var snapshot: [UUID: (mac: String, peripheralUUID: String?)] = [:]
        for dev in devices {
            snapshot[dev.id] = (mac: dev.macAddress, peripheralUUID: dev.peripheralUUIDString)
        }
        let activeID = activeDeviceID
        bleQueue.async { [weak self] in
            self?.bleDeviceRecords = snapshot
            self?.bleActiveDeviceID = activeID
        }
    }

    // MARK: - Dual-Endian Key Cache & Strict MAC Matching (bleQueue)
    private func warmUpKeyCache() {
        let macs = devices.map { $0.macAddress }
        bleQueue.async { [weak self] in
            for mac in macs {
                _ = self?.getCachedKeysOnBLEQueue(for: mac)
            }
        }
    }

    private func getCachedKeysOnBLEQueue(for mac: String) -> (primary: Data, alt: Data)? {
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

    private func resolveActiveSecretKeyOnBLEQueue(for deviceID: UUID) -> (active: Data, alt: Data)? {
        guard let record = bleDeviceRecords[deviceID] else { return nil }
        let pair = getCachedKeysOnBLEQueue(for: record.mac)

        if let verified = verifiedWorkingKeys[deviceID] {
            return (active: verified, alt: pair?.alt ?? verified)
        }
        if let p = activePeripherals[deviceID], let bKey = peripheralBroadcastKeys[p.identifier] {
            verifiedWorkingKeys[deviceID] = bKey
            return (active: bKey, alt: pair?.alt ?? bKey)
        }
        if let uuidStr = record.peripheralUUID,
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

    private func setConnectionPhaseOnBLEQueue(_ phase: DeviceConnectionPhase, for deviceID: UUID) {
        if bleConnectionPhases[deviceID] == phase { return }
        bleConnectionPhases[deviceID] = phase
        DispatchQueue.main.async { [weak self] in
            self?.connectionPhases[deviceID] = phase
        }
    }

    /// 在后台蓝牙队列安全激活 CoreBluetooth，绝不阻塞主线程启动与滚动
    public func activateBluetoothIfNeeded() {
        bleQueue.async { [weak self] in
            guard let self = self, !self.isBluetoothActivated else { return }
            self.isBluetoothActivated = true
            self.centralManager = CBCentralManager(delegate: self, queue: self.bleQueue)
        }
    }

    // MARK: - App ScenePhase Lifecycle
    @MainActor
    public func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isAppInBackground = false
            bleQueue.async { [weak self] in
                self?.bleIsAppInBackground = false
            }
            activateBluetoothIfNeeded()
            if let activeID = activeDeviceID {
                Task.detached(priority: .userInitiated) { [weak self] in
                    await self?.ensureConnected(deviceID: activeID)
                }
            }

        case .background:
            isAppInBackground = true
            bleQueue.async { [weak self] in
                self?.bleIsAppInBackground = true
            }
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

    public func performQuickBackgroundStatusSync(for deviceID: UUID) async {
        let connected = await ensureConnected(deviceID: deviceID, timeout: 4.5)
        if connected {
            await queryStatus(for: deviceID)
            try? await Task.sleep(nanoseconds: 650_000_000)
        }
        let shouldDisconnect = await MainActor.run {
            self.isAppInBackground && self.disconnectWhenEnteringBackground
        }
        if shouldDisconnect {
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
        saveDiskDebounceTask?.cancel()
        saveDiskDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self = self else { return }
            let snapshot = self.devices
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) {
                    UserDefaults.standard.set(data, forKey: Self.storageKey)
                }
            }
        }
    }

    private func saveDevicesToDiskImmediately() {
        saveDiskDebounceTask?.cancel()
        let snapshot = devices
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        }
    }

    // MARK: - Runtime & Per-Gear Accounting + History Clearing
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
        devices[idx].autoOffTargetDate = nil
    }

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

    // MARK: - Device CRUD Management
    public func addOrUpdateDevice(
        from discovered: DiscoveredBLEBlanket,
        customName: String,
        roomName: String,
        manualMAC: String
    ) {
        activateBluetoothIfNeeded()
        let normalizedMAC = discovered.extractedMAC
            ?? BlanketProtocol.normalizeMAC(manualMAC)
            ?? "8E:B2:D6:64:F8:60"

        let targetID: UUID
        if let idx = devices.firstIndex(where: {
            $0.peripheralUUIDString == discovered.id.uuidString ||
            $0.macAddress.caseInsensitiveCompare(normalizedMAC) == .orderedSame
        }) {
            targetID = devices[idx].id
            devices[idx].peripheralUUIDString = discovered.id.uuidString
            devices[idx].macAddress = normalizedMAC
            devices[idx].name = customName.isEmpty ? discovered.name : customName
            devices[idx].roomName = roomName.isEmpty ? "卧室" : roomName
            devices[idx].advertisedName = discovered.name
            devices[idx].lastRSSI = discovered.rssi
            activeDeviceID = targetID
        } else {
            let newDevice = BlanketDevice(
                peripheralUUIDString: discovered.id.uuidString,
                macAddress: normalizedMAC,
                name: customName.isEmpty ? discovered.name : customName,
                roomName: roomName.isEmpty ? "卧室" : roomName,
                advertisedName: discovered.name,
                lastRSSI: discovered.rssi
            )
            targetID = newDevice.id
            devices.append(newDevice)
            activeDeviceID = targetID
        }

        syncDeviceRecordsToBLEQueue()
        saveDevicesToDiskImmediately()

        let discoveredPID = discovered.id
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.getCachedKeysOnBLEQueue(for: normalizedMAC)
            if let exactKey = self.peripheralBroadcastKeys[discoveredPID] {
                self.verifiedWorkingKeys[targetID] = exactKey
            } else {
                self.verifiedWorkingKeys.removeValue(forKey: targetID)
            }
            if let pid = self.peripheralProductIDs[discoveredPID] {
                self.deviceProductIDs[targetID] = pid
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.ensureConnected(deviceID: targetID)
        }
    }

    public func addManualDevice(name: String, roomName: String, macAddress: String) {
        activateBluetoothIfNeeded()
        let normalizedMAC = BlanketProtocol.normalizeMAC(macAddress) ?? "8E:B2:D6:64:F8:60"
        let newDevice = BlanketDevice(
            macAddress: normalizedMAC,
            name: name.isEmpty ? "智能蓝牙电热毯" : name,
            roomName: roomName.isEmpty ? "主卧" : roomName
        )
        devices.append(newDevice)
        activeDeviceID = newDevice.id
        syncDeviceRecordsToBLEQueue()
        saveDevicesToDiskImmediately()
        bleQueue.async { [weak self] in
            _ = self?.getCachedKeysOnBLEQueue(for: normalizedMAC)
        }
    }

    public func updateDeviceMetadata(deviceID: UUID, name: String, roomName: String, macAddress: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        devices[idx].roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        var changedMAC: String?
        if let cleanMAC = BlanketProtocol.normalizeMAC(macAddress),
           devices[idx].macAddress.caseInsensitiveCompare(cleanMAC) != .orderedSame {
            devices[idx].macAddress = cleanMAC
            changedMAC = cleanMAC
        }
        syncDeviceRecordsToBLEQueue()
        saveDevicesToDiskImmediately()
        if let cleanMAC = changedMAC {
            bleQueue.async { [weak self] in
                self?.verifiedWorkingKeys.removeValue(forKey: deviceID)
                _ = self?.getCachedKeysOnBLEQueue(for: cleanMAC)
            }
        }
    }

    @MainActor
    public func removeDevice(deviceID: UUID) {
        disconnect(deviceID: deviceID)
        lastGearAccountingDates.removeValue(forKey: deviceID)
        lastNotifiedStates.removeValue(forKey: deviceID)
        connectionPhases.removeValue(forKey: deviceID)

        let nextActiveID: UUID? = {
            if activeDeviceID == deviceID {
                return devices.first(where: { $0.id != deviceID })?.id
            }
            return activeDeviceID
        }()
        activeDeviceID = nextActiveID
        devices.removeAll { $0.id == deviceID }
        syncDeviceRecordsToBLEQueue()
        saveDevicesToDiskImmediately()

        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.activePeripherals.removeValue(forKey: deviceID)
            self.verifiedWorkingKeys.removeValue(forKey: deviceID)
            self.deviceProductIDs.removeValue(forKey: deviceID)
            self.bleConnectionPhases.removeValue(forKey: deviceID)
            self.peripheralToDeviceMap = self.peripheralToDeviceMap.filter { $0.value != deviceID }
        }
    }

    // MARK: - BLE Discovery & Scanning (bleQueue)
    public func startScanning() {
        activateBluetoothIfNeeded()
        bleQueue.async { [weak self] in
            self?.startScanningOnBLEQueue(showBannerIfNotReady: true)
        }
    }

    private func startScanningOnBLEQueue(showBannerIfNotReady: Bool) {
        guard let central = centralManager, central.state == .poweredOn else {
            if showBannerIfNotReady {
                DispatchQueue.main.async { [weak self] in
                    self?.lastBannerMessage = "请确认已在系统设置中开启蓝牙并授予权限"
                }
            }
            return
        }
        if !bleIsScanning {
            bleIsScanning = true
            DispatchQueue.main.async { [weak self] in
                self?.isScanning = true
            }
        }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    public func stopScanning() {
        bleQueue.async { [weak self] in
            self?.stopScanningOnBLEQueue()
        }
    }

    private func stopScanningOnBLEQueue() {
        let hasConnectingWaitingForScan = bleDeviceRecords.keys.contains {
            bleConnectionPhases[$0] == .connecting && activePeripherals[$0] == nil
        }
        guard bleIsScanning, !hasConnectingWaitingForScan else { return }
        centralManager?.stopScan()
        bleIsScanning = false
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
        }
    }

    // MARK: - Point-to-Point Cached Direct Connection Engine (100% Off Main Thread)
    @discardableResult
    public func ensureConnected(deviceID: UUID, timeout: TimeInterval = 7.5) async -> Bool {
        activateBluetoothIfNeeded()

        return await withCheckedContinuation { continuation in
            bleQueue.async { [weak self] in
                guard let self = self,
                      let record = self.bleDeviceRecords[deviceID] else {
                    continuation.resume(returning: false)
                    return
                }

                // 1. 当前已连接且特征值与 Notify 订阅均已就绪 -> 0ms 直接命中返回
                if let peripheral = self.activePeripherals[deviceID],
                   peripheral.state == .connected,
                   self.controlCharacteristics[deviceID] != nil,
                   self.hasCompletedNotifyHandshake.contains(deviceID) {
                    self.setConnectionPhaseOnBLEQueue(.connected, for: deviceID)
                    continuation.resume(returning: true)
                    return
                }

                guard let central = self.centralManager, central.state == .poweredOn else {
                    self.setConnectionPhaseOnBLEQueue(.disconnected, for: deviceID)
                    continuation.resume(returning: false)
                    return
                }

                self.setConnectionPhaseOnBLEQueue(.connecting, for: deviceID)

                // 2. 优先使用该设备已绑定的 peripheralUUIDString 定向取回 CBPeripheral
                var targetPeripheral: CBPeripheral? = self.activePeripherals[deviceID]

                if targetPeripheral == nil,
                   let uuidStr = record.peripheralUUID,
                   let pUUID = UUID(uuidString: uuidStr) {
                    targetPeripheral = self.discoveredPeripheralObjects[pUUID]
                        ?? central.retrievePeripherals(withIdentifiers: [pUUID]).first
                }

                // 3. 若尚未记录 peripheralUUIDString，仅从已发现缓存中匹配 MAC 一致的设备
                if targetPeripheral == nil,
                   let discoveredMatch = self.lastDiscoveredCache.values.first(where: {
                       guard let extMAC = $0.extractedMAC else { return false }
                       return extMAC.caseInsensitiveCompare(record.mac) == .orderedSame
                   }),
                   let cachedObj = self.discoveredPeripheralObjects[discoveredMatch.id] {
                    targetPeripheral = cachedObj
                }

                if let peripheral = targetPeripheral {
                    if let bKey = self.peripheralBroadcastKeys[peripheral.identifier] {
                        self.verifiedWorkingKeys[deviceID] = bKey
                    }
                    if let pid = self.peripheralProductIDs[peripheral.identifier] {
                        self.deviceProductIDs[deviceID] = pid
                    }
                    self.bindAndConnectOnBLEQueue(peripheral: peripheral, to: deviceID)
                } else {
                    self.startScanningOnBLEQueue(showBannerIfNotReady: false)
                }

                self.connectionContinuations[deviceID, default: []].append(continuation)

                self.bleQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self = self else { return }
                    if let pending = self.connectionContinuations[deviceID], !pending.isEmpty {
                        let isReady = (self.bleConnectionPhases[deviceID] == .connected && self.controlCharacteristics[deviceID] != nil)
                        if !isReady {
                            self.setConnectionPhaseOnBLEQueue(.failed, for: deviceID)
                        }
                        let list = self.connectionContinuations.removeValue(forKey: deviceID) ?? []
                        for cont in list {
                            cont.resume(returning: isReady)
                        }
                    }
                }
            }
        }
    }

    private func bindAndConnectOnBLEQueue(peripheral: CBPeripheral, to deviceID: UUID) {
        activePeripherals[deviceID] = peripheral
        discoveredPeripheralObjects[peripheral.identifier] = peripheral
        peripheralToDeviceMap[peripheral.identifier] = deviceID

        if let bKey = peripheralBroadcastKeys[peripheral.identifier] {
            verifiedWorkingKeys[deviceID] = bKey
        }
        if let pid = peripheralProductIDs[peripheral.identifier] {
            deviceProductIDs[deviceID] = pid
        }

        let pUUIDStr = peripheral.identifier.uuidString
        if bleDeviceRecords[deviceID]?.peripheralUUID != pUUIDStr {
            bleDeviceRecords[deviceID]?.peripheralUUID = pUUIDStr
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let idx = self.devices.firstIndex(where: { $0.id == deviceID }),
                      self.devices[idx].peripheralUUIDString != pUUIDStr else { return }
                self.devices[idx].peripheralUUIDString = pUUIDStr
            }
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
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.delayedQueryWorkItems[deviceID]?.cancel()
            self.delayedQueryWorkItems.removeValue(forKey: deviceID)
            self.notifyReadyFallbackItems[deviceID]?.cancel()
            self.notifyReadyFallbackItems.removeValue(forKey: deviceID)
            self.hasCompletedNotifyHandshake.remove(deviceID)
            if let peripheral = self.activePeripherals[deviceID], peripheral.state != .disconnected {
                self.centralManager?.cancelPeripheralConnection(peripheral)
            }
            self.controlCharacteristics.removeValue(forKey: deviceID)
            self.setConnectionPhaseOnBLEQueue(.disconnected, for: deviceID)
        }
    }

    // MARK: - High-Speed Point-to-Point Command Pipeline (100% Off Main Thread)
    @discardableResult
    public func sendCommand(_ cmdHex: String, to deviceID: UUID, useAltKey: Bool = false) async -> Bool {
        let ready = await ensureConnected(deviceID: deviceID)

        return await withCheckedContinuation { continuation in
            bleQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }
                guard ready,
                      let peripheral = self.activePeripherals[deviceID],
                      let characteristic = self.controlCharacteristics[deviceID],
                      let resolvedKeys = self.resolveActiveSecretKeyOnBLEQueue(for: deviceID) else {
                    self.pendingCommandsAfterConnect[deviceID, default: []].append(cmdHex)
                    continuation.resume(returning: false)
                    return
                }

                let targetKey = useAltKey ? resolvedKeys.alt : resolvedKeys.active
                guard let cipherData = BlanketProtocol.encryptPayload(cmdHex: cmdHex, secretKey: targetKey) else {
                    continuation.resume(returning: false)
                    return
                }

                self.writeCipherDataOnBLEQueue(cipherData, to: peripheral, characteristic: characteristic, deviceID: deviceID)
                continuation.resume(returning: true)
            }
        }
    }

    private func writeCipherDataOnBLEQueue(_ cipherData: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic, deviceID: UUID) {
        commandWriteStartTimes[deviceID] = Date()
        lastWrittenCipherPayloads[deviceID] = cipherData

        if preferWriteWithoutResponse.contains(deviceID) && characteristic.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(cipherData, for: characteristic, type: .withoutResponse)
        } else if characteristic.properties.contains(.write) {
            peripheral.writeValue(cipherData, for: characteristic, type: .withResponse)
            if !hasConfirmedWriteResponse.contains(deviceID) && characteristic.properties.contains(.writeWithoutResponse) {
                bleQueue.asyncAfter(deadline: .now() + 0.22) { [weak self] in
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

    private func scheduleDelayedQueryOnBLEQueue(for deviceID: UUID, delaySeconds: Double = 0.55) {
        delayedQueryWorkItems[deviceID]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.bleConnectionPhases[deviceID] == .connected else { return }
            self.sendQueryOnBLEQueue(for: deviceID)
        }
        delayedQueryWorkItems[deviceID] = item
        bleQueue.asyncAfter(deadline: .now() + delaySeconds, execute: item)
    }

    private func scheduleDebouncedCommand(key: String, delayMs: UInt64 = 140, action: @escaping @Sendable () async -> Void) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    // MARK: - User & AppIntent Control Actions (UI 立即乐观响应 + BLE 全异步后台执行)

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
            let effSec = devices[idx].effectiveTimeCloseHours * 3600
            devices[idx].remainingTimeCloseSec = effSec
            devices[idx].autoOffTargetDate = now.addingTimeInterval(TimeInterval(effSec))
            devices[idx].timeOpenHours = 0
            devices[idx].remainingTimeOpenSec = 0
            devices[idx].scheduledOnTargetDate = nil
        } else if !isOn && wasOn {
            finalizeUsageSession(for: deviceID, endDate: now)
            devices[idx].isOn = false
        } else {
            devices[idx].isOn = isOn
        }

        let restoreMemory = devices[idx].restoreMemoryOnPowerOn
        let targetLeft = devices[idx].savedGearLeft
        let targetRight = devices[idx].savedGearRight
        let targetClose = devices[idx].savedTimeCloseHours
        let updatedSnapshot = devices[idx]

        if isOn {
            isPoweringOnRestoringMemory.insert(deviceID)
        }

        // 所有蓝牙连接、加密与发送均脱离主线程在后台执行，UI 零等待
        await runPowerBLEPipeline(
            isOn: isOn,
            deviceID: deviceID,
            restoreMemory: restoreMemory,
            targetLeft: targetLeft,
            targetRight: targetRight,
            targetClose: targetClose
        )

        if isOn {
            isPoweringOnRestoringMemory.remove(deviceID)
        }
        await LiveActivityManager.shared.syncActivityState(for: updatedSnapshot)
    }

    private nonisolated func runPowerBLEPipeline(
        isOn: Bool,
        deviceID: UUID,
        restoreMemory: Bool,
        targetLeft: Int,
        targetRight: Int,
        targetClose: Int
    ) async {
        if isOn {
            let ok = await sendCommand(BlanketProtocol.cmdPower(isOn: true), to: deviceID)
            if ok && restoreMemory {
                try? await Task.sleep(nanoseconds: 450_000_000)
                await sendCommand(BlanketProtocol.cmdGearLeft(targetLeft), to: deviceID)
                try? await Task.sleep(nanoseconds: 220_000_000)
                await sendCommand(BlanketProtocol.cmdGearRight(targetRight), to: deviceID)
                try? await Task.sleep(nanoseconds: 220_000_000)
                await sendCommand(BlanketProtocol.cmdTimeClose(hours: targetClose), to: deviceID)
            }
            bleQueue.async { [weak self] in
                self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.65)
            }
        } else {
            await sendCommand(BlanketProtocol.cmdPower(isOn: false), to: deviceID)
            bleQueue.async { [weak self] in
                self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.55)
            }
        }
    }

    /// 2. 调节左温区挡位 (1~9) — 关机状态下仅在 App 本地记忆，不会同时开机或下发蓝牙指令
    public func setGearLeft(_ gear: Int, for deviceID: UUID, debounced: Bool = true) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }),
              devices[idx].mode != .miteRemoval else { return }
        let clamped = min(9, max(1, gear))
        devices[idx].gearLeft = clamped
        devices[idx].savedGearLeft = clamped
        let shouldSyncRight = devices[idx].syncDualZones
        if shouldSyncRight {
            devices[idx].gearRight = clamped
            devices[idx].savedGearRight = clamped
        }

        guard devices[idx].isOn else { return }
        recordGearRuntimeSlice(for: deviceID)

        let taskAction: @Sendable () async -> Void = { [weak self] in
            guard let self = self else { return }
            await self.sendCommand(BlanketProtocol.cmdGearLeft(clamped), to: deviceID)
            if shouldSyncRight {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self.sendCommand(BlanketProtocol.cmdGearRight(clamped), to: deviceID)
            }
            self.bleQueue.async { [weak self] in
                self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.55)
            }
        }

        if debounced {
            scheduleDebouncedCommand(key: "gearLeft_\(deviceID)", action: taskAction)
        } else {
            Task.detached(priority: .userInitiated) { await taskAction() }
        }
    }

    /// 3. 调节右温区挡位 (1~9) — 关机状态下仅在 App 本地记忆，不会同时开机或下发蓝牙指令
    public func setGearRight(_ gear: Int, for deviceID: UUID, debounced: Bool = true) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }),
              devices[idx].mode != .miteRemoval else { return }
        let clamped = min(9, max(1, gear))
        devices[idx].gearRight = clamped
        devices[idx].savedGearRight = clamped
        let shouldSyncLeft = devices[idx].syncDualZones
        if shouldSyncLeft {
            devices[idx].gearLeft = clamped
            devices[idx].savedGearLeft = clamped
        }

        guard devices[idx].isOn else { return }
        recordGearRuntimeSlice(for: deviceID)

        let taskAction: @Sendable () async -> Void = { [weak self] in
            guard let self = self else { return }
            await self.sendCommand(BlanketProtocol.cmdGearRight(clamped), to: deviceID)
            if shouldSyncLeft {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self.sendCommand(BlanketProtocol.cmdGearLeft(clamped), to: deviceID)
            }
            self.bleQueue.async { [weak self] in
                self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.55)
            }
        }

        if debounced {
            scheduleDebouncedCommand(key: "gearRight_\(deviceID)", action: taskAction)
        } else {
            Task.detached(priority: .userInitiated) { await taskAction() }
        }
    }

    /// 4. 切换工作模式（普通加热 / 2小时高温除螨模式）
    /// 开启或关闭除螨模式均保持当前 UI 界面已选挡位与定时不变；关闭除螨模式时自动忽略硬件回退的默认 9挡/12h 上报并将当前 UI 挡位与定时重新下发给设备
    @MainActor
    public func setMode(_ mode: BlanketHeatingMode, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        recordGearRuntimeSlice(for: deviceID)
        let now = Date()
        let prevMode = devices[idx].mode
        devices[idx].mode = mode
        if mode == .miteRemoval && prevMode != .miteRemoval {
            devices[idx].totalMiteRemovalCount += 1
        }
        let needsPowerOn = !devices[idx].isOn
        if needsPowerOn {
            devices[idx].isOn = true
            if devices[idx].currentSessionStartDate == nil {
                devices[idx].currentSessionStartDate = now
                devices[idx].totalPowerOnCount += 1
            }
            lastGearAccountingDates[deviceID] = now
            devices[idx].timeOpenHours = 0
            devices[idx].remainingTimeOpenSec = 0
            devices[idx].scheduledOnTargetDate = nil
        }

        // 原版小程序除螨模式下硬件固定锁死 2 小时后关机；退出除螨模式后恢复为用户选择的 timeCloseHours 倒计时
        if mode == .miteRemoval {
            devices[idx].remainingTimeCloseSec = 2 * 3600
            devices[idx].autoOffTargetDate = now.addingTimeInterval(TimeInterval(2 * 3600))
        } else {
            let closeSec = devices[idx].timeCloseHours * 3600
            devices[idx].remainingTimeCloseSec = closeSec
            devices[idx].autoOffTargetDate = now.addingTimeInterval(TimeInterval(closeSec))
        }
        PushNotificationManager.shared.scheduleBackgroundHardwareTimerNotifications(for: devices[idx])

        let targetLeft = devices[idx].gearLeft
        let targetRight = devices[idx].gearRight
        let targetClose = devices[idx].timeCloseHours
        let shouldRestoreAfterExitMite = (prevMode == .miteRemoval && mode == .normal)

        if shouldRestoreAfterExitMite {
            isExitingMiteRestoringState.insert(deviceID)
        }

        await runModeBLEPipeline(
            mode: mode,
            needsPowerOn: needsPowerOn,
            shouldRestoreAfterExitMite: shouldRestoreAfterExitMite,
            targetLeft: targetLeft,
            targetRight: targetRight,
            targetClose: targetClose,
            deviceID: deviceID
        )

        if shouldRestoreAfterExitMite {
            isExitingMiteRestoringState.remove(deviceID)
        }
        if let updatedSnapshot = devices.first(where: { $0.id == deviceID }) {
            await LiveActivityManager.shared.syncActivityState(for: updatedSnapshot)
        }
    }

    private nonisolated func runModeBLEPipeline(
        mode: BlanketHeatingMode,
        needsPowerOn: Bool,
        shouldRestoreAfterExitMite: Bool,
        targetLeft: Int,
        targetRight: Int,
        targetClose: Int,
        deviceID: UUID
    ) async {
        if needsPowerOn {
            await sendCommand(BlanketProtocol.cmdPower(isOn: true), to: deviceID)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        await sendCommand(BlanketProtocol.cmdMode(mode), to: deviceID)
        if shouldRestoreAfterExitMite {
            // 等待设备完成模式切换并上报默认 9挡/12h 状态（在此期间 applyParsedTLVToUI 会忽略该默认上报）
            try? await Task.sleep(nanoseconds: 350_000_000)
            await sendCommand(BlanketProtocol.cmdGearLeft(targetLeft), to: deviceID)
            try? await Task.sleep(nanoseconds: 220_000_000)
            await sendCommand(BlanketProtocol.cmdGearRight(targetRight), to: deviceID)
            try? await Task.sleep(nanoseconds: 220_000_000)
            await sendCommand(BlanketProtocol.cmdTimeClose(hours: targetClose), to: deviceID)
        }
        bleQueue.async { [weak self] in
            self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.65)
        }
    }

    private nonisolated func restoreUIGearAndTimerAfterMiteExit(
        targetLeft: Int,
        targetRight: Int,
        targetClose: Int,
        deviceID: UUID
    ) async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        await sendCommand(BlanketProtocol.cmdGearLeft(targetLeft), to: deviceID)
        try? await Task.sleep(nanoseconds: 220_000_000)
        await sendCommand(BlanketProtocol.cmdGearRight(targetRight), to: deviceID)
        try? await Task.sleep(nanoseconds: 220_000_000)
        await sendCommand(BlanketProtocol.cmdTimeClose(hours: targetClose), to: deviceID)
        bleQueue.async { [weak self] in
            self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.65)
        }
    }

    /// 5. 设置自动关机定时 (1~12 小时) — 关机状态下仅在 App 本地记忆，已选预约开机时不可调节
    @MainActor
    public func setAutoOffHours(_ hours: Int, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }),
              devices[idx].mode != .miteRemoval,
              devices[idx].isOn || devices[idx].timeOpenHours == 0 else { return }
        let clamped = min(12, max(1, hours))
        devices[idx].timeCloseHours = clamped
        devices[idx].savedTimeCloseHours = clamped
        devices[idx].remainingTimeCloseSec = clamped * 3600

        guard devices[idx].isOn else { return }
        devices[idx].autoOffTargetDate = Date().addingTimeInterval(TimeInterval(clamped * 3600))
        let snapshot = devices[idx]
        Task { @MainActor in
            await LiveActivityManager.shared.syncActivityState(for: snapshot)
        }

        PushNotificationManager.shared.scheduleBackgroundHardwareTimerNotifications(for: snapshot)
        await runTimerCommandBLEPipeline(cmdHex: BlanketProtocol.cmdTimeClose(hours: clamped), deviceID: deviceID)
    }

    /// 6. 设置预约开机定时 (0~12 小时，0 为关闭预约) — 仅在设备关机且非除螨模式下可用
    @MainActor
    public func setScheduledOnHours(_ hours: Int, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }),
              devices[idx].mode != .miteRemoval,
              !devices[idx].isOn else { return }
        let clamped = min(12, max(0, hours))
        devices[idx].timeOpenHours = clamped
        devices[idx].remainingTimeOpenSec = clamped * 3600
        devices[idx].scheduledOnTargetDate = clamped > 0 ? Date().addingTimeInterval(TimeInterval(clamped * 3600)) : nil
        let snapshot = devices[idx]

        PushNotificationManager.shared.scheduleBackgroundHardwareTimerNotifications(for: snapshot)
        await runTimerCommandBLEPipeline(cmdHex: BlanketProtocol.cmdTimeOpen(hours: clamped), deviceID: deviceID)
    }

    private nonisolated func runTimerCommandBLEPipeline(cmdHex: String, deviceID: UUID) async {
        await sendCommand(cmdHex, to: deviceID)
        bleQueue.async { [weak self] in
            self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.55)
        }
    }

    /// 7. 主动查询硬件实时状态（全后台执行）
    public func queryStatus(for deviceID: UUID) async {
        let ready = await ensureConnected(deviceID: deviceID)
        guard ready else { return }
        bleQueue.async { [weak self] in
            self?.sendQueryOnBLEQueue(for: deviceID)
        }
    }

    private func sendQueryOnBLEQueue(for deviceID: UUID) {
        guard let peripheral = activePeripherals[deviceID],
              peripheral.state == .connected,
              let characteristic = controlCharacteristics[deviceID],
              let resolvedKeys = resolveActiveSecretKeyOnBLEQueue(for: deviceID) else {
            return
        }
        let pid = deviceProductIDs[deviceID]
        let primaryQueryCmd = BlanketProtocol.queryCommand(forProductId: pid)
        let syncBefore = lastBLEProcessedSyncDates[deviceID]

        if let cipherData = BlanketProtocol.encryptPayload(cmdHex: primaryQueryCmd, secretKey: resolvedKeys.active) {
            writeCipherDataOnBLEQueue(cipherData, to: peripheral, characteristic: characteristic, deviceID: deviceID)
        }

        bleQueue.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self,
                  self.bleConnectionPhases[deviceID] == .connected,
                  let p = self.activePeripherals[deviceID],
                  p.state == .connected,
                  let c = self.controlCharacteristics[deviceID],
                  let keys = self.resolveActiveSecretKeyOnBLEQueue(for: deviceID) else { return }

            if self.lastBLEProcessedSyncDates[deviceID] == syncBefore {
                if primaryQueryCmd != BlanketProtocol.queryCoreStatusCmd {
                    if let fallbackCipher = BlanketProtocol.encryptPayload(cmdHex: BlanketProtocol.queryCoreStatusCmd, secretKey: keys.active) {
                        self.writeCipherDataOnBLEQueue(fallbackCipher, to: p, characteristic: c, deviceID: deviceID)
                    }
                } else if self.verifiedWorkingKeys[deviceID] == nil {
                    if let altCipher = BlanketProtocol.encryptPayload(cmdHex: BlanketProtocol.queryCoreStatusCmd, secretKey: keys.alt) {
                        self.writeCipherDataOnBLEQueue(altCipher, to: p, characteristic: c, deviceID: deviceID)
                    }
                }
            }
        }
    }

    // MARK: - Low-Overhead 15-Second Runtime & Foreground Live Sync Ticker
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
                let remClose = devices[idx].effectiveRemainingCloseSeconds(at: now)
                if devices[idx].remainingTimeCloseSec != remClose {
                    devices[idx].remainingTimeCloseSec = remClose
                }
                if remClose == 0 {
                    Task.detached(priority: .utility) { [weak self] in
                        await self?.queryStatus(for: devID)
                    }
                }
            } else if devices[idx].timeOpenHours > 0 {
                let remOpen = devices[idx].effectiveRemainingOpenSeconds(at: now)
                if devices[idx].remainingTimeOpenSec != remOpen {
                    devices[idx].remainingTimeOpenSec = remOpen
                }
                if remOpen == 0 {
                    Task.detached(priority: .utility) { [weak self] in
                        await self?.queryStatus(for: devID)
                    }
                }
            }
        }

        if !isAppInBackground,
           let activeID = activeDeviceID,
           connectionPhases[activeID] == .connected {
            Task.detached(priority: .utility) { [weak self] in
                await self?.queryStatus(for: activeID)
            }
        }
    }

    // MARK: - Complete Notify Handshake & Trigger Initial Status Query (bleQueue)
    private func completeConnectionReadyOnBLEQueue(for deviceID: UUID) {
        notifyReadyFallbackItems[deviceID]?.cancel()
        notifyReadyFallbackItems.removeValue(forKey: deviceID)

        let isFirstHandshake = !hasCompletedNotifyHandshake.contains(deviceID)
        hasCompletedNotifyHandshake.insert(deviceID)
        setConnectionPhaseOnBLEQueue(.connected, for: deviceID)
        stopScanningOnBLEQueue()

        let list = connectionContinuations.removeValue(forKey: deviceID) ?? []
        for cont in list {
            cont.resume(returning: true)
        }

        if isFirstHandshake {
            bleQueue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self = self else { return }
                if let queued = self.pendingCommandsAfterConnect.removeValue(forKey: deviceID), !queued.isEmpty {
                    Task.detached(priority: .userInitiated) { [weak self] in
                        for cmd in queued {
                            await self?.sendCommand(cmd, to: deviceID)
                            try? await Task.sleep(nanoseconds: 180_000_000)
                        }
                    }
                }
                if let lastWrite = self.commandWriteStartTimes[deviceID],
                   Date().timeIntervalSince(lastWrite) < 0.25 {
                    self.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.5)
                } else {
                    self.sendQueryOnBLEQueue(for: deviceID)
                }
            }
        }
    }

    // MARK: - Handle Decrypted Notification Payload on bleQueue, Minimal UI Diff Dispatch
    private func handleIncomingNotificationOnBLEQueue(data: Data, for deviceID: UUID) {
        guard let record = bleDeviceRecords[deviceID],
              let resolvedKeys = resolveActiveSecretKeyOnBLEQueue(for: deviceID) else { return }

        var matchedHex: String?
        if let decActive = BlanketProtocol.decryptPayload(cipherBytes: data, secretKey: resolvedKeys.active, altKey: nil),
           BlanketProtocol.knownPrefixes.contains(where: { decActive.hasPrefix($0) }) {
            matchedHex = decActive
            verifiedWorkingKeys[deviceID] = resolvedKeys.active
        } else if let decAlt = BlanketProtocol.decryptPayload(cipherBytes: data, secretKey: resolvedKeys.alt, altKey: nil),
                  BlanketProtocol.knownPrefixes.contains(where: { decAlt.hasPrefix($0) }) {
            matchedHex = decAlt
            verifiedWorkingKeys[deviceID] = resolvedKeys.alt
        } else if let macPair = getCachedKeysOnBLEQueue(for: record.mac) {
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

        let now = Date()
        lastBLEProcessedSyncDates[deviceID] = now

        var measuredLatency: Int?
        if let writeStart = commandWriteStartTimes[deviceID] {
            let ms = max(5, min(999, Int(now.timeIntervalSince(writeStart) * 1000)))
            measuredLatency = ms
            commandWriteStartTimes.removeValue(forKey: deviceID)
            lastLatencyReport[deviceID] = (ms, now)
        }

        let needDelayedQueryForPowerOn = (tlv.isOn == nil && (tlv.gearLeft != nil || tlv.gearRight != nil))

        DispatchQueue.main.async { [weak self] in
            self?.applyParsedTLVToUI(
                tlv,
                measuredLatency: measuredLatency,
                now: now,
                needDelayedQueryForGear: needDelayedQueryForPowerOn,
                for: deviceID
            )
        }
    }

    @MainActor
    private func applyParsedTLVToUI(
        _ tlv: BlanketTLVUpdate,
        measuredLatency: Int?,
        now: Date,
        needDelayedQueryForGear: Bool,
        for deviceID: UUID
    ) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }

        var draft = devices[idx]
        let prevSnapshot = lastNotifiedStates[deviceID]
        let wasOn = draft.isOn
        var stateChanged = false
        var timerChanged = false
        var liveActivityRelevantChanged = false

        if let ms = measuredLatency {
            let oldMs = draft.lastCommandLatencyMs ?? -100
            if abs(oldMs - ms) >= 20 {
                draft.lastCommandLatencyMs = ms
                stateChanged = true
            }
        }

        if let isOn = tlv.isOn {
            if !wasOn && isOn {
                draft.isOn = true
                draft.currentSessionStartDate = now
                lastGearAccountingDates[deviceID] = now
                draft.totalPowerOnCount += 1
                draft.timeOpenHours = 0
                draft.remainingTimeOpenSec = 0
                draft.scheduledOnTargetDate = nil
                if tlv.gearLeft == nil { draft.gearLeft = 9 }
                if tlv.gearRight == nil { draft.gearRight = 9 }
                if tlv.timeCloseHours == nil { draft.timeCloseHours = 12 }
                if tlv.mode == nil { draft.mode = .normal }
                let effSec = draft.effectiveTimeCloseHours * 3600
                draft.remainingTimeCloseSec = effSec
                draft.autoOffTargetDate = now.addingTimeInterval(TimeInterval(effSec))
                stateChanged = true
                timerChanged = true
                liveActivityRelevantChanged = true
                bleQueue.async { [weak self] in
                    self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.45)
                }
            } else if wasOn && !isOn {
                finalizeUsageSession(for: deviceID, endDate: now)
                draft = devices[idx]
                draft.isOn = false
                stateChanged = true
                timerChanged = true
                liveActivityRelevantChanged = true
            } else if draft.isOn != isOn {
                draft.isOn = isOn
                stateChanged = true
                liveActivityRelevantChanged = true
            }
        }

        var hardwareJustExitedMiteRemoval = false
        if let mode = tlv.mode, draft.mode != mode {
            let prevMode = draft.mode
            draft.mode = mode
            stateChanged = true
            timerChanged = true
            liveActivityRelevantChanged = true
            if mode == .miteRemoval && prevMode != .miteRemoval {
                draft.totalMiteRemovalCount += 1
                draft.remainingTimeCloseSec = 2 * 3600
                draft.autoOffTargetDate = now.addingTimeInterval(TimeInterval(2 * 3600))
            } else if prevMode == .miteRemoval && mode == .normal {
                hardwareJustExitedMiteRemoval = true
                let closeSec = draft.timeCloseHours * 3600
                draft.remainingTimeCloseSec = closeSec
                draft.autoOffTargetDate = now.addingTimeInterval(TimeInterval(closeSec))
            }
        }

        // 除螨模式运行期间、或刚退出除螨模式正在恢复用户 UI 挡位/定时期间，忽略设备上报的固定 9挡/2h 或退出除螨回退的默认 9挡/12h，保持 UI 挡位与定时不动
        let shouldIgnoreMiteGearAndTimeReport = (draft.mode == .miteRemoval)
            || isExitingMiteRestoringState.contains(deviceID)
            || hardwareJustExitedMiteRemoval

        if hardwareJustExitedMiteRemoval && !isExitingMiteRestoringState.contains(deviceID) {
            let restoreLeft = draft.gearLeft
            let restoreRight = draft.gearRight
            let restoreClose = draft.timeCloseHours
            isExitingMiteRestoringState.insert(deviceID)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.restoreUIGearAndTimerAfterMiteExit(
                    targetLeft: restoreLeft,
                    targetRight: restoreRight,
                    targetClose: restoreClose,
                    deviceID: deviceID
                )
                self.isExitingMiteRestoringState.remove(deviceID)
            }
        }

        if let gl = tlv.gearLeft, !shouldIgnoreMiteGearAndTimeReport {
            if draft.gearLeft != gl {
                draft.gearLeft = gl
                stateChanged = true
                liveActivityRelevantChanged = true
            }
            if draft.isOn && !isPoweringOnRestoringMemory.contains(deviceID) && draft.savedGearLeft != gl {
                draft.savedGearLeft = gl
                stateChanged = true
            }
            if !draft.isOn && needDelayedQueryForGear {
                bleQueue.async { [weak self] in
                    self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.25)
                }
            }
        }
        if let gr = tlv.gearRight, !shouldIgnoreMiteGearAndTimeReport {
            if draft.gearRight != gr {
                draft.gearRight = gr
                stateChanged = true
                liveActivityRelevantChanged = true
            }
            if draft.isOn && !isPoweringOnRestoringMemory.contains(deviceID) && draft.savedGearRight != gr {
                draft.savedGearRight = gr
                stateChanged = true
            }
            if !draft.isOn && needDelayedQueryForGear {
                bleQueue.async { [weak self] in
                    self?.scheduleDelayedQueryOnBLEQueue(for: deviceID, delaySeconds: 0.25)
                }
            }
        }
        if let tc = tlv.timeCloseHours, tc > 0, !shouldIgnoreMiteGearAndTimeReport {
            if draft.timeCloseHours != tc {
                draft.timeCloseHours = tc
                if draft.isOn {
                    draft.remainingTimeCloseSec = tc * 3600
                    draft.autoOffTargetDate = now.addingTimeInterval(TimeInterval(tc * 3600))
                }
                stateChanged = true
                timerChanged = true
                liveActivityRelevantChanged = true
            }
            if draft.isOn && !isPoweringOnRestoringMemory.contains(deviceID) && draft.savedTimeCloseHours != tc {
                draft.savedTimeCloseHours = tc
                stateChanged = true
            }
            if draft.autoOffTargetDate == nil && draft.isOn {
                let elapsed = draft.currentSessionStartDate.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0
                let rem = max(0, tc * 3600 - elapsed)
                draft.remainingTimeCloseSec = rem
                draft.autoOffTargetDate = now.addingTimeInterval(TimeInterval(rem))
                stateChanged = true
                timerChanged = true
            }
        }
        if let to = tlv.timeOpenHours {
            if draft.timeOpenHours != to {
                draft.timeOpenHours = to
                draft.remainingTimeOpenSec = to * 3600
                draft.scheduledOnTargetDate = to > 0 ? now.addingTimeInterval(TimeInterval(to * 3600)) : nil
                stateChanged = true
                timerChanged = true
            }
            if to == 0 && (draft.remainingTimeOpenSec != 0 || draft.scheduledOnTargetDate != nil) {
                draft.remainingTimeOpenSec = 0
                draft.scheduledOnTargetDate = nil
                stateChanged = true
                timerChanged = true
            }
        }
        if let remOpen = tlv.remainingTimeOpenSec, remOpen > 0 {
            let currentRemOpen = draft.effectiveRemainingOpenSeconds(at: now)
            if abs(currentRemOpen - remOpen) >= 60 {
                draft.remainingTimeOpenSec = remOpen
                draft.scheduledOnTargetDate = now.addingTimeInterval(TimeInterval(remOpen))
                stateChanged = true
                timerChanged = true
            }
        }
        // 当硬件上报精确的剩余关机秒数（9b020004）时（无论普通模式还是除螨模式，只要不处于退出除螨恢复过程中），同步校准倒计时截止时间
        if let remClose = tlv.remainingTimeCloseSec, remClose > 0, !isExitingMiteRestoringState.contains(deviceID) && !hardwareJustExitedMiteRemoval {
            let currentRemClose = draft.effectiveRemainingCloseSeconds(at: now)
            if abs(currentRemClose - remClose) >= 60 {
                draft.remainingTimeCloseSec = remClose
                draft.autoOffTargetDate = now.addingTimeInterval(TimeInterval(remClose))
                stateChanged = true
                timerChanged = true
                liveActivityRelevantChanged = true
            }
        }

        let syncStale = draft.lastSyncDate.map { now.timeIntervalSince($0) >= 15.0 } ?? true
        if stateChanged || syncStale {
            draft.lastSyncDate = now
            devices[idx] = draft
        }

        if !isPoweringOnRestoringMemory.contains(deviceID), let prev = prevSnapshot {
            if prev.isOn != draft.isOn {
                if draft.isOn {
                    PushNotificationManager.shared.notifyDeviceStateChanged(
                        title: "🔥 \(draft.name) 已开启加热",
                        body: "当前模式：\(draft.mode.title) · 左温区 \(draft.gearLeft)挡 (\(draft.temperatureLeft)°C) / 右温区 \(draft.gearRight)挡 (\(draft.temperatureRight)°C)"
                    )
                } else {
                    PushNotificationManager.shared.notifyDeviceStateChanged(
                        title: "❄️ \(draft.name) 已关机",
                        body: "电热毯已停止加热并进入待机状态。"
                    )
                }
            } else if draft.isOn && (prev.gearLeft != draft.gearLeft || prev.gearRight != draft.gearRight) {
                PushNotificationManager.shared.notifyDeviceStateChanged(
                    title: "🎛 \(draft.name) 温区挡位已更新",
                    body: "左温区：\(draft.gearLeft)挡 (\(draft.temperatureLeft)°C) · 右温区：\(draft.gearRight)挡 (\(draft.temperatureRight)°C)"
                )
            } else if draft.isOn && prev.mode != draft.mode {
                PushNotificationManager.shared.notifyDeviceStateChanged(
                    title: "🔄 \(draft.name) 模式已切换",
                    body: "当前工作模式已切换为：\(draft.mode.title)"
                )
            }
        }

        lastNotifiedStates[deviceID] = (draft.isOn, draft.gearLeft, draft.gearRight, draft.mode, draft.timeCloseHours)

        if timerChanged {
            PushNotificationManager.shared.scheduleBackgroundHardwareTimerNotifications(for: draft)
        }
        if liveActivityRelevantChanged {
            Task { @MainActor in
                await LiveActivityManager.shared.syncActivityState(for: draft)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate & CBPeripheralDelegate (100% Executed on bleQueue)
extension BlanketBLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        let shouldAutoConnect = (state == .poweredOn && !bleIsAppInBackground)
        let activeID = bleActiveDeviceID

        DispatchQueue.main.async { [weak self] in
            self?.bluetoothState = state
        }

        if shouldAutoConnect, let activeID = activeID {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.ensureConnected(deviceID: activeID)
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

        var parsedAdv: BlanketProtocol.ParsedAdvertisementInfo?
        var serviceHex: String?
        for (_, data) in serviceDataDict {
            if let info = BlanketProtocol.parseServiceData5700(data) {
                parsedAdv = info
                serviceHex = data.hexEncodedString()
                break
            }
        }

        if parsedAdv == nil,
           let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           let info = BlanketProtocol.parseVerifiedManufacturerData(mfgData) {
            parsedAdv = info
            serviceHex = mfgData.hexEncodedString()
        }

        let isJingHe = (parsedAdv != nil) || has5700UUID || has5700Data || isNameJ
        let rssiVal = RSSI.intValue
        let pID = peripheral.identifier

        discoveredPeripheralObjects[pID] = peripheral

        if let info = parsedAdv {
            peripheralBroadcastKeys[pID] = info.exactSecretKey
            peripheralProductIDs[pID] = info.productId
            peripheralDisplayMACs[pID] = info.displayMAC
        }

        if isJingHe,
           let matchedEntry = bleDeviceRecords.first(where: { _, record in
               if let boundUUID = record.peripheralUUID, boundUUID == pID.uuidString {
                   return true
               }
               if let info = parsedAdv, isMatchingSavedMAC(record.mac, advertisementInfo: info) {
                   return true
               }
               return false
           }) {
            let targetID = matchedEntry.key
            if let info = parsedAdv, isMatchingSavedMAC(matchedEntry.value.mac, advertisementInfo: info) {
                verifiedWorkingKeys[targetID] = info.exactSecretKey
                deviceProductIDs[targetID] = info.productId
            }
            if bleConnectionPhases[targetID] == .connecting && activePeripherals[targetID]?.state != .connected {
                bindAndConnectOnBLEQueue(peripheral: peripheral, to: targetID)
            }
        }

        guard !localName.isEmpty || isJingHe else { return }

        let existing = lastDiscoveredCache[pID]
        let mergedName: String = {
            if !localName.isEmpty { return localName }
            if let prevName = existing?.name, !prevName.isEmpty { return prevName }
            return "晶合蓝牙电热毯"
        }()
        let mergedMAC = parsedAdv?.displayMAC ?? peripheralDisplayMACs[pID] ?? existing?.extractedMAC
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
        lastDiscoveredCache[pID] = item

        let now = Date()
        let lastUIUpdate = lastDiscoveredUIUpdateDates[pID] ?? .distantPast
        let isNewItem = (existing == nil)
        let macChanged = (existing?.extractedMAC != item.extractedMAC)

        // 节流：仅新增设备、MAC 解析更新或距上次 UI 刷新 >= 1.0 秒时才派发到主线程，彻底消除自动连接期间主线程卡顿
        if isNewItem || macChanged || now.timeIntervalSince(lastUIUpdate) >= 1.0 {
            lastDiscoveredUIUpdateDates[pID] = now
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let idx = self.discoveredPeripherals.firstIndex(where: { $0.id == pID }) {
                    self.discoveredPeripherals[idx] = item
                } else {
                    self.discoveredPeripherals.append(item)
                }
            }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let pID = peripheral.identifier
        guard let deviceID = peripheralToDeviceMap[pID] else { return }
        controlCharacteristics.removeValue(forKey: deviceID)
        hasCompletedNotifyHandshake.remove(deviceID)
        peripheral.delegate = self
        peripheral.readRSSI()
        peripheral.discoverServices(nil)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let pID = peripheral.identifier
        guard let deviceID = peripheralToDeviceMap[pID] else { return }
        setConnectionPhaseOnBLEQueue(.failed, for: deviceID)
        let list = connectionContinuations.removeValue(forKey: deviceID) ?? []
        for cont in list { cont.resume(returning: false) }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let pID = peripheral.identifier
        guard let deviceID = peripheralToDeviceMap[pID] else { return }
        notifyReadyFallbackItems[deviceID]?.cancel()
        notifyReadyFallbackItems.removeValue(forKey: deviceID)
        hasCompletedNotifyHandshake.remove(deviceID)
        controlCharacteristics.removeValue(forKey: deviceID)
        setConnectionPhaseOnBLEQueue(.disconnected, for: deviceID)

        if !bleIsAppInBackground {
            bleQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, !self.bleIsAppInBackground else { return }
                Task.detached(priority: .userInitiated) { [weak self] in
                    await self?.ensureConnected(deviceID: deviceID)
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
        guard let deviceID = peripheralToDeviceMap[pID] else { return }

        for characteristic in characteristics {
            let uuidUpper = characteristic.uuid.uuidString.uppercased()
            if uuidUpper.contains("4A486201") || uuidUpper == "6201" {
                peripheral.setNotifyValue(true, for: characteristic)
                controlCharacteristics[deviceID] = characteristic

                notifyReadyFallbackItems[deviceID]?.cancel()
                let fallbackItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if !self.hasCompletedNotifyHandshake.contains(deviceID) {
                        self.completeConnectionReadyOnBLEQueue(for: deviceID)
                    }
                }
                notifyReadyFallbackItems[deviceID] = fallbackItem
                bleQueue.asyncAfter(deadline: .now() + 0.38, execute: fallbackItem)
            }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let pID = peripheral.identifier
        guard let deviceID = peripheralToDeviceMap[pID] else { return }
        let uuidUpper = characteristic.uuid.uuidString.uppercased()
        guard uuidUpper.contains("4A486201") || uuidUpper == "6201" else { return }
        completeConnectionReadyOnBLEQueue(for: deviceID)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let pID = peripheral.identifier
        guard let deviceID = peripheralToDeviceMap[pID] else { return }
        handleIncomingNotificationOnBLEQueue(data: data, for: deviceID)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let pID = peripheral.identifier
        guard let deviceID = peripheralToDeviceMap[pID] else { return }
        if error == nil {
            hasConfirmedWriteResponse.insert(deviceID)
        } else if characteristic.properties.contains(.writeWithoutResponse),
                  let fallbackData = lastWrittenCipherPayloads[deviceID] {
            preferWriteWithoutResponse.insert(deviceID)
            peripheral.writeValue(fallbackData, for: characteristic, type: .withoutResponse)
        }
        if let writeStart = commandWriteStartTimes[deviceID] {
            let now = Date()
            let ms = max(5, min(999, Int(now.timeIntervalSince(writeStart) * 1000)))
            let prev = lastLatencyReport[deviceID]
            let shouldPushToUI = prev == nil || (now.timeIntervalSince(prev!.date) >= 2.0 && abs(prev!.ms - ms) >= 20)
            if shouldPushToUI {
                lastLatencyReport[deviceID] = (ms, now)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self,
                          let idx = self.devices.firstIndex(where: { $0.id == deviceID }) else { return }
                    self.devices[idx].lastCommandLatencyMs = ms
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let rssiVal = RSSI.intValue
        guard rssiVal < 0 else { return }
        let pID = peripheral.identifier
        guard let deviceID = peripheralToDeviceMap[pID] else { return }
        let prev = lastReportedRSSI[deviceID] ?? 0
        guard abs(prev - rssiVal) >= 8 else { return }
        lastReportedRSSI[deviceID] = rssiVal
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let idx = self.devices.firstIndex(where: { $0.id == deviceID }) else { return }
            self.devices[idx].lastRSSI = rssiVal
        }
    }
}
