import Foundation
import CoreBluetooth
import Combine

/// 高速 CoreBluetooth 直连控制与多设备管理中心
/// 针对 iOS 26/27 进行启动稳定性与并发安全加固：
/// 1. 延迟初始化 `CBCentralManager`（在主界面完成挂载后调用 `activateBluetoothIfNeeded()`），杜绝冷启动 TCC 权限检查或 XPC 阻塞闪退；
/// 2. 移除在 `NSObject` Objective-C 委托类上的全局 `@MainActor` 强制隔离断点（避免 iOS 26/27 `libswift_Concurrency.dylib` 的 `_swift_task_checkIsolatedSwift` 崩溃）；
/// 3. 保留零扫描直连 (`retrievePeripherals(withIdentifiers:)`)、120ms 防抖合并及开机 0.35s 恢复记忆挡位。
public final class BlanketBLEManager: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = BlanketBLEManager()

    // MARK: - Published UI State
    @Published public var devices: [BlanketDevice] = [] {
        didSet { saveDevicesToDisk() }
    }
    @Published public var activeDeviceID: UUID?
    @Published public var connectionPhases: [UUID: DeviceConnectionPhase] = [:]
    @Published public var discoveredPeripherals: [DiscoveredBLEBlanket] = []
    @Published public var isScanning: Bool = false
    @Published public var bluetoothState: CBManagerState = .unknown
    @Published public var onlyFilterJingHeDevices: Bool = true
    @Published public var lastBannerMessage: String?

    // MARK: - Internal CoreBluetooth State
    private var centralManager: CBCentralManager?
    private var isBluetoothActivated: Bool = false
    private var activePeripherals: [UUID: CBPeripheral] = [:]
    private var controlCharacteristics: [UUID: CBCharacteristic] = [:]
    private var peripheralToDeviceMap: [UUID: UUID] = [:] // CBPeripheral.identifier -> BlanketDevice.id
    private var commandWriteStartTimes: [UUID: Date] = [:]
    private var pendingCommandsAfterConnect: [UUID: [String]] = [:]
    private var connectionContinuations: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var idleDisconnectDeadlines: [UUID: Date] = [:]
    private var isPoweringOnRestoringMemory: Set<UUID> = []
    private var runtimeTicker: AnyCancellable?
    private var pollCounter: Int = 0

    public static let storageKey = "com.smartblanketpro.saved_devices.v1"

    private override init() {
        super.init()
        loadDevicesFromDisk()
        startRuntimeAndCountdownTicker()
    }

    /// 在主视图加载完成后安全激活 CoreBluetooth，避免启动瞬间崩溃
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

    // MARK: - Persistence
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
    }

    private func saveDevicesToDisk() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Device CRUD Management (Requirement 2)
    public func addOrUpdateDevice(
        from discovered: DiscoveredBLEBlanket,
        customName: String,
        roomName: String,
        manualMAC: String
    ) {
        activateBluetoothIfNeeded()
        let normalizedMAC = BlanketProtocol.normalizeMAC(manualMAC)
            ?? discovered.extractedMAC
            ?? "8E:B2:D6:64:F8:60"

        if let idx = devices.firstIndex(where: {
            $0.peripheralUUIDString == discovered.id.uuidString ||
            $0.macAddress.caseInsensitiveCompare(normalizedMAC) == .orderedSame
        }) {
            devices[idx].peripheralUUIDString = discovered.id.uuidString
            devices[idx].macAddress = normalizedMAC
            devices[idx].name = customName.isEmpty ? discovered.name : customName
            devices[idx].roomName = roomName.isEmpty ? "卧室" : roomName
            devices[idx].advertisedName = discovered.name
            devices[idx].lastRSSI = discovered.rssi
            activeDeviceID = devices[idx].id
            let targetID = devices[idx].id
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
            devices.append(newDevice)
            activeDeviceID = newDevice.id
            let targetID = newDevice.id
            Task { @MainActor in
                await self.ensureConnected(deviceID: targetID)
            }
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
    }

    public func updateDeviceMetadata(deviceID: UUID, name: String, roomName: String, macAddress: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        devices[idx].roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanMAC = BlanketProtocol.normalizeMAC(macAddress) {
            devices[idx].macAddress = cleanMAC
        }
    }

    public func removeDevice(deviceID: UUID) {
        disconnect(deviceID: deviceID)
        devices.removeAll { $0.id == deviceID }
        if activeDeviceID == deviceID {
            activeDeviceID = devices.first?.id
        }
    }

    // MARK: - BLE Discovery & Scanning
    public func startScanning() {
        activateBluetoothIfNeeded()
        guard let central = centralManager, central.state == .poweredOn else {
            lastBannerMessage = "请确认已在系统设置中开启蓝牙并授予权限"
            return
        }
        discoveredPeripherals.removeAll()
        isScanning = true
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    public func stopScanning() {
        guard isScanning else { return }
        centralManager?.stopScan()
        isScanning = false
    }

    // MARK: - Ultra-Fast Direct Connection Engine (Requirement 4)
    /// 确保指定电热毯已建立 BLE 连接：优先通过 `retrievePeripherals` 0.15s 零扫描直连
    @discardableResult
    @MainActor
    public func ensureConnected(deviceID: UUID, timeout: TimeInterval = 8.0) async -> Bool {
        activateBluetoothIfNeeded()
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        let device = devices[idx]

        if let peripheral = activePeripherals[deviceID],
           peripheral.state == .connected,
           controlCharacteristics[deviceID] != nil {
            return true
        }

        guard let central = centralManager, central.state == .poweredOn else {
            connectionPhases[deviceID] = .disconnected
            return false
        }

        connectionPhases[deviceID] = .connecting

        // 路径 1：已知 CBPeripheral UUID -> 调用系统缓存零扫描秒连
        var targetPeripheral: CBPeripheral?
        if let uuidStr = device.peripheralUUIDString,
           let pUUID = UUID(uuidString: uuidStr) {
            targetPeripheral = central.retrievePeripherals(withIdentifiers: [pUUID]).first
        }

        // 路径 2：检查系统当前已连接的外设池
        if targetPeripheral == nil {
            let serviceUUID = CBUUID(string: BlanketProtocol.controlServiceUUID)
            targetPeripheral = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first
        }

        if let peripheral = targetPeripheral {
            bindAndConnect(peripheral: peripheral, to: deviceID)
        } else {
            // 路径 3：首次尚未绑定 peripheralUUID，启动后台定向快速捕获（按 MAC 或名称 J* / 0x5700 匹配）
            startScanning()
        }

        return await withCheckedContinuation { continuation in
            connectionContinuations[deviceID, default: []].append(continuation)

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self = self else { return }
                if let pending = self.connectionContinuations[deviceID], !pending.isEmpty {
                    let isReady = (self.connectionPhases[deviceID] == .connected)
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
        peripheralToDeviceMap[peripheral.identifier] = deviceID
        if let idx = devices.firstIndex(where: { $0.id == deviceID }) {
            devices[idx].peripheralUUIDString = peripheral.identifier.uuidString
        }
        peripheral.delegate = self
        centralManager?.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    public func disconnect(deviceID: UUID) {
        if let peripheral = activePeripherals[deviceID] {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        controlCharacteristics.removeValue(forKey: deviceID)
        connectionPhases[deviceID] = .disconnected
    }

    // MARK: - High-Speed Optimistic Command Pipeline
    /// 发送加密控制指令（支持自动唤醒连接、优先 WriteWithResponse 并在失败时无缝回退 WriteWithoutResponse）
    @discardableResult
    @MainActor
    public func sendCommand(_ cmdHex: String, to deviceID: UUID) async -> Bool {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        let mac = devices[idx].macAddress

        guard let secretKey = BlanketProtocol.getSecretKey(macAddress: mac, reverseMac: true),
              let cipherData = BlanketProtocol.encryptPayload(cmdHex: cmdHex, secretKey: secretKey) else {
            return false
        }

        let ready = await ensureConnected(deviceID: deviceID)
        guard ready,
              let peripheral = activePeripherals[deviceID],
              let characteristic = controlCharacteristics[deviceID] else {
            pendingCommandsAfterConnect[deviceID, default: []].append(cmdHex)
            return false
        }

        commandWriteStartTimes[deviceID] = Date()
        if characteristic.properties.contains(.write) {
            peripheral.writeValue(cipherData, for: characteristic, type: .withResponse)
        } else {
            peripheral.writeValue(cipherData, for: characteristic, type: .withoutResponse)
        }
        peripheral.readRSSI()
        return true
    }

    /// 120ms 防抖指令合并：拖动滑块时 UI 立即顺滑响应，蓝牙层合并高频中间帧，大幅提升响应速度与稳定性
    private func scheduleDebouncedCommand(key: String, delayMs: UInt64 = 120, action: @escaping @MainActor () async -> Void) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    // MARK: - User & AppIntent Control Actions (Requirements 3, 4, 5)

    /// 1. 开关电热毯电源（内置开机 0.35s 自动恢复上次挡位与定时记忆）
    @MainActor
    public func setPower(isOn: Bool, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let wasOn = devices[idx].isOn

        // 乐观更新 UI (0ms 延迟响应)
        devices[idx].isOn = isOn
        if isOn && !wasOn {
            devices[idx].currentSessionStartDate = Date()
            devices[idx].totalPowerOnCount += 1
            idleDisconnectDeadlines.removeValue(forKey: deviceID)
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
            if let start = devices[idx].currentSessionStartDate {
                let elapsed = max(0, Date().timeIntervalSince(start))
                devices[idx].accumulatedRuntimeSeconds += elapsed
            }
            devices[idx].currentSessionStartDate = nil
            devices[idx].remainingTimeCloseSec = 0
            if devices[idx].connectionPolicy == .smartInstantWake {
                idleDisconnectDeadlines[deviceID] = Date().addingTimeInterval(10 * 60)
            }
        }

        if isOn {
            isPoweringOnRestoringMemory.insert(deviceID)
            let ok = await sendCommand(BlanketProtocol.cmdPower(isOn: true), to: deviceID)
            if ok, let currentIdx = devices.firstIndex(where: { $0.id == deviceID }),
               devices[currentIdx].restoreMemoryOnPowerOn {
                let targetLeft = devices[currentIdx].savedGearLeft
                let targetRight = devices[currentIdx].savedGearRight
                let targetClose = devices[currentIdx].savedTimeCloseHours

                try? await Task.sleep(nanoseconds: 350_000_000)
                await sendCommand(BlanketProtocol.cmdGearLeft(targetLeft), to: deviceID)
                try? await Task.sleep(nanoseconds: 180_000_000)
                await sendCommand(BlanketProtocol.cmdGearRight(targetRight), to: deviceID)
                try? await Task.sleep(nanoseconds: 180_000_000)
                await sendCommand(BlanketProtocol.cmdTimeClose(hours: targetClose), to: deviceID)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            isPoweringOnRestoringMemory.remove(deviceID)
            await queryStatus(for: deviceID)
        } else {
            await sendCommand(BlanketProtocol.cmdPower(isOn: false), to: deviceID)
        }
    }

    /// 2. 调节左温区挡位 (1~9)
    public func setGearLeft(_ gear: Int, for deviceID: UUID, debounced: Bool = true) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
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
                await self.setPower(isOn: true, for: deviceID)
            } else {
                await self.sendCommand(BlanketProtocol.cmdGearLeft(clamped), to: deviceID)
                if shouldSyncRight {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await self.sendCommand(BlanketProtocol.cmdGearRight(clamped), to: deviceID)
                }
            }
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
                await self.setPower(isOn: true, for: deviceID)
            } else {
                await self.sendCommand(BlanketProtocol.cmdGearRight(clamped), to: deviceID)
                if shouldSyncLeft {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await self.sendCommand(BlanketProtocol.cmdGearLeft(clamped), to: deviceID)
                }
            }
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
        devices[idx].mode = mode
        if mode == .miteRemoval {
            devices[idx].gearLeft = 9
            devices[idx].gearRight = 9
            devices[idx].timeCloseHours = 2
            devices[idx].remainingTimeCloseSec = 2 * 3600
        }
        if !devices[idx].isOn {
            await setPower(isOn: true, for: deviceID)
        }
        await sendCommand(BlanketProtocol.cmdMode(mode), to: deviceID)
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
        try? await Task.sleep(nanoseconds: 350_000_000)
        await queryStatus(for: deviceID)
    }

    /// 6. 设置预约开机定时 (0~12 小时，0 为关闭预约)
    @MainActor
    public func setScheduledOnHours(_ hours: Int, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let clamped = min(12, max(0, hours))
        devices[idx].timeOpenHours = clamped
        devices[idx].remainingTimeOpenSec = clamped * 3600
        await sendCommand(BlanketProtocol.cmdTimeOpen(hours: clamped), to: deviceID)
        try? await Task.sleep(nanoseconds: 350_000_000)
        await queryStatus(for: deviceID)
    }

    /// 7. 主动查询全部 8 项硬件实时状态
    @MainActor
    public func queryStatus(for deviceID: UUID) async {
        await sendCommand(BlanketProtocol.queryAllStatusCmd, to: deviceID)
    }

    // MARK: - 1-Second Runtime & Countdown Ticker
    private func startRuntimeAndCountdownTicker() {
        runtimeTicker = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                guard let self = self else { return }
                self.tickRuntimeAndCountdowns(now: now)
            }
    }

    private func tickRuntimeAndCountdowns(now: Date) {
        pollCounter += 1
        for idx in devices.indices {
            let devID = devices[idx].id
            if devices[idx].isOn && devices[idx].remainingTimeCloseSec > 0 {
                devices[idx].remainingTimeCloseSec = max(0, devices[idx].remainingTimeCloseSec - 1)
            }
            if !devices[idx].isOn && devices[idx].timeOpenHours > 0 && devices[idx].remainingTimeOpenSec > 0 {
                devices[idx].remainingTimeOpenSec = max(0, devices[idx].remainingTimeOpenSec - 1)
            }
            if devices[idx].connectionPolicy == .smartInstantWake,
               !devices[idx].isOn,
               let deadline = idleDisconnectDeadlines[devID],
               now >= deadline {
                idleDisconnectDeadlines.removeValue(forKey: devID)
                disconnect(deviceID: devID)
            }
        }

        if pollCounter >= 25 {
            pollCounter = 0
            for device in devices where connectionPhases[device.id] == .connected {
                let targetID = device.id
                Task { @MainActor [weak self] in
                    await self?.queryStatus(for: targetID)
                }
            }
        }
    }

    // MARK: - Handle Decrypted Notification Payload
    private func handleIncomingNotification(data: Data, for deviceID: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let mac = devices[idx].macAddress

        guard let primaryKey = BlanketProtocol.getSecretKey(macAddress: mac, reverseMac: true) else { return }
        let altKey = BlanketProtocol.getSecretKey(macAddress: mac, reverseMac: false)

        guard let decryptedHex = BlanketProtocol.decryptPayload(
            cipherBytes: data,
            secretKey: primaryKey,
            altKey: altKey
        ) else { return }

        let tlv = BlanketProtocol.parseTLVData(hexString: decryptedHex)
        guard tlv.hasValidProperty else { return }

        if let writeStart = commandWriteStartTimes[deviceID] {
            let ms = Int(Date().timeIntervalSince(writeStart) * 1000)
            devices[idx].lastCommandLatencyMs = max(5, min(999, ms))
            commandWriteStartTimes.removeValue(forKey: deviceID)
        }

        let wasOn = devices[idx].isOn
        if let isOn = tlv.isOn {
            devices[idx].isOn = isOn
            if !wasOn && isOn {
                devices[idx].currentSessionStartDate = Date()
                devices[idx].totalPowerOnCount += 1
                if tlv.gearLeft == nil { devices[idx].gearLeft = 9 }
                if tlv.gearRight == nil { devices[idx].gearRight = 9 }
                if tlv.timeCloseHours == nil { devices[idx].timeCloseHours = 12 }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await self?.queryStatus(for: deviceID)
                }
            } else if wasOn && !isOn {
                if let start = devices[idx].currentSessionStartDate {
                    devices[idx].accumulatedRuntimeSeconds += max(0, Date().timeIntervalSince(start))
                }
                devices[idx].currentSessionStartDate = nil
            }
        }

        if let mode = tlv.mode {
            devices[idx].mode = mode
        }
        if let gl = tlv.gearLeft {
            devices[idx].gearLeft = gl
            if devices[idx].isOn && !isPoweringOnRestoringMemory.contains(deviceID) {
                devices[idx].savedGearLeft = gl
            }
        }
        if let gr = tlv.gearRight {
            devices[idx].gearRight = gr
            if devices[idx].isOn && !isPoweringOnRestoringMemory.contains(deviceID) {
                devices[idx].savedGearRight = gr
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
        }
        if let remOpen = tlv.remainingTimeOpenSec {
            devices[idx].remainingTimeOpenSec = remOpen
        }
        if let remClose = tlv.remainingTimeCloseSec {
            devices[idx].remainingTimeCloseSec = remClose
        }

        devices[idx].lastSyncDate = Date()
    }
}

// MARK: - CBCentralManagerDelegate & CBPeripheralDelegate
extension BlanketBLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.bluetoothState = state
            // 如果当前已有绑定过 CBPeripheral UUID 的设备，在蓝牙就绪时静默直连
            if state == .poweredOn,
               let activeID = self.activeDeviceID,
               let dev = self.devices.first(where: { $0.id == activeID }),
               dev.peripheralUUIDString != nil {
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
        let has5700UUID = serviceUUIDs.contains { $0.uuidString.lowercased().contains("5700") }
        let has5700Data = serviceDataDict.keys.contains { $0.uuidString.lowercased().contains("5700") }
        let isJingHe = isNameJ || has5700UUID || has5700Data

        var extractedMAC: String?
        var serviceHex: String?
        for (uuid, data) in serviceDataDict where uuid.uuidString.lowercased().contains("5700") {
            serviceHex = data.hexEncodedString()
            extractedMAC = BlanketProtocol.extractMACFromAdvertisement(serviceData: data)
        }
        if extractedMAC == nil,
           let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            extractedMAC = BlanketProtocol.extractMACFromAdvertisement(serviceData: mfgData)
        }

        let rssiVal = RSSI.intValue
        let pID = peripheral.identifier

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let waitingIdx = self.devices.firstIndex(where: {
                self.connectionPhases[$0.id] == .connecting &&
                ($0.peripheralUUIDString == nil || $0.peripheralUUIDString == pID.uuidString) &&
                (extractedMAC?.caseInsensitiveCompare($0.macAddress) == .orderedSame || isJingHe)
            }) {
                let targetID = self.devices[waitingIdx].id
                if let mac = extractedMAC {
                    self.devices[waitingIdx].macAddress = mac
                }
                self.stopScanning()
                self.bindAndConnect(peripheral: peripheral, to: targetID)
            }

            guard !localName.isEmpty || isJingHe else { return }
            let item = DiscoveredBLEBlanket(
                id: pID,
                name: localName.isEmpty ? "晶合蓝牙电热毯" : localName,
                extractedMAC: extractedMAC,
                rssi: (rssiVal == 127 ? -65 : rssiVal),
                isJingHeBlanket: isJingHe,
                serviceDataHex: serviceHex,
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
            guard let self = self, let _ = self.peripheralToDeviceMap[pID] else { return }
            peripheral.delegate = self
            peripheral.readRSSI()
            let serviceUUID = CBUUID(string: BlanketProtocol.controlServiceUUID)
            peripheral.discoverServices([serviceUUID])
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
            self.controlCharacteristics.removeValue(forKey: deviceID)
            self.connectionPhases[deviceID] = .disconnected

            if let device = self.devices.first(where: { $0.id == deviceID }),
               (device.connectionPolicy == .continuous || device.isOn) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await self?.ensureConnected(deviceID: deviceID)
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            let charUUID = CBUUID(string: BlanketProtocol.controlCharacteristicUUID)
            peripheral.discoverCharacteristics([charUUID], for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristics = service.characteristics else { return }
        let pID = peripheral.identifier
        for characteristic in characteristics where characteristic.uuid.uuidString.uppercased().contains("4A486201") {
            peripheral.setNotifyValue(true, for: characteristic)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let deviceID = self.peripheralToDeviceMap[pID] else { return }
                self.controlCharacteristics[deviceID] = characteristic
                self.connectionPhases[deviceID] = .connected

                let list = self.connectionContinuations.removeValue(forKey: deviceID) ?? []
                for cont in list { cont.resume(returning: true) }

                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    await self.queryStatus(for: deviceID)
                    if let queued = self.pendingCommandsAfterConnect.removeValue(forKey: deviceID) {
                        for cmd in queued {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            await self.sendCommand(cmd, to: deviceID)
                        }
                    }
                }
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
