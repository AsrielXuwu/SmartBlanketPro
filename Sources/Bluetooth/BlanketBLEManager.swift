import Foundation
import CoreBluetooth
import Combine
import SwiftUI

/// 高速 CoreBluetooth 点对点缓存直连与双向状态同步引擎
/// 严格对照原版微信小程序源码 (`behaviors/bleBehaviors.js`, `utils/ble/helper.js`, `utils/ble/CRC.js`, `utils/des.js`, `subpkgs/blepanelA/pages/blanket/blanket.js`, `subpkgs/blepanelA/pages/blanketto/blanketto.js`) 修复控制与状态同步：
/// 1. **100% 复刻小程序 0x5700 广播包 CRC16 校验与密钥提取 (`parseServiceData5700`)**：
///    - 严格对 `0x5700` Service Data (14 字节) 执行 `checkCrc16` 校验（多项式 `0x8408 = 33800`），提取 `pid` (字节 0~5) 与原始 6 字节 `deviceManufactCode` (字节 6~11)；
///    - 直接按小程序公式 `secretKey = deviceManufactCode + "5700"` 锁定 8 字节 DES 密钥，彻底杜绝从非 `0x5700` 的 `ManufacturerData` 误提取乱码字节覆盖 MAC 地址；
///    - 升级持久化存储键至 `v3`，自动清理旧版本可能被 `ManufacturerData` 污染的缓存 MAC；
/// 2. **严格遵循小程序 `notifyReadWrite` 时序**：
///    - 发现 `4A486201` 特征值后先调用 `setNotifyValue(true)`，必须等待 `didUpdateNotificationStateFor` (CCCD `0x2902` 订阅生效) 完成后才标记 `.connected`、唤醒等待队列并下发状态查询指令，杜绝 CCCD 写入与特征值写入并发冲突；
/// 3. **移除 160ms 错误密钥双发干扰，精准单通道加密通信**：
///    - 移除在 160ms 后补发反向密钥密文的逻辑，避免向杰理 MCU 注入无法解析的乱码块导致指令被丢弃；
/// 4. **前台实时监听物理按键 + 切入后台自动断连**：
///    - 前台保持 BLE Notify 订阅，电热毯实体按钮开关机或调挡时实时解密 TLV 状态流并更新 UI；切入后台时自动断开蓝牙释放连接。
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

    /// 切入后台时是否立即断开蓝牙连接（默认开启）
    @Published public var disconnectWhenEnteringBackground: Bool = (UserDefaults.standard.object(forKey: "com.smartblanketpro.bg_disconnect") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(disconnectWhenEnteringBackground, forKey: "com.smartblanketpro.bg_disconnect") }
    }

    // MARK: - Point-to-Point Cache (外设对象缓存 + 特征值缓存 + 广播精确密钥缓存 + 已验证密钥锁定)
    private var centralManager: CBCentralManager?
    private var isBluetoothActivated: Bool = false
    private var activePeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredPeripheralObjects: [UUID: CBPeripheral] = [:] // CBPeripheral.identifier -> CBPeripheral
    private var controlCharacteristics: [UUID: CBCharacteristic] = [:]
    private var cachedSecretKeys: [String: (primary: Data, alt: Data)] = [:]
    /// 从经过 CRC16 校验的 0x5700 广播包直接提取的 8 字节精确密钥 (deviceManufactCode + "5700")
    private var peripheralBroadcastKeys: [UUID: Data] = [:] // CBPeripheral.identifier -> 8-byte DES Key
    private var peripheralProductIDs: [UUID: String] = [:]  // CBPeripheral.identifier -> 12-char Product ID
    private var peripheralDisplayMACs: [UUID: String] = [:] // CBPeripheral.identifier -> XX:XX:XX:XX:XX:XX
    /// 一旦硬件 Notify 验证通过或广播 CRC16 验证通过，锁定该设备 100% 正确的 8 字节 DES 密钥
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
    private var pendingScanConnectTasks: [UUID: Task<Void, Never>] = [:]
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var delayedQueryTasks: [UUID: Task<Void, Never>] = [:]
    private var isPoweringOnRestoringMemory: Set<UUID> = []
    private var hasCompletedNotifyHandshake: Set<UUID> = []
    private var lastNotifiedStates: [UUID: (isOn: Bool, gearLeft: Int, gearRight: Int, mode: BlanketHeatingMode, timeClose: Int)] = [:]
    private var isAppInBackground: Bool = false
    private var runtimeTicker: AnyCancellable?
    private var pollCounter: Int = 0

    /// 升级存储 Key 至 v3，确保旧版被 ManufacturerData 覆盖的错误 MAC 缓存被彻底清除并重置为正确配置
    public static let storageKey = "com.smartblanketpro.saved_devices.v3"

    private override init() {
        super.init()
        loadDevicesFromDisk()
        warmUpKeyCache()
        startRuntimeAndCountdownTicker()
    }

    // MARK: - Dual-Endian Key Cache
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

    /// 获取某个设备当前最权威的 8 字节 DES 密钥（优先顺序：已验证/广播 CRC16 精确密钥 -> MAC 派生小端密钥 -> 默认密钥）
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

    // MARK: - App ScenePhase Lifecycle (切入后台自动断连 & 回到前台极速同步状态变化)
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
            for dev in devices {
                PushNotificationManager.shared.scheduleBackgroundHardwareTimerNotifications(for: dev)
            }
            if disconnectWhenEnteringBackground {
                for dev in devices {
                    disconnect(deviceID: dev.id)
                }
            }

        case .inactive:
            break
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
        for dev in loaded {
            lastNotifiedStates[dev.id] = (dev.isOn, dev.gearLeft, dev.gearRight, dev.mode, dev.timeCloseHours)
        }
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
        // 优先采用从 0x5700 Service Data CRC16 校验提取出的真实硬件 MAC，避免被手填输入框的默认占位符覆盖
        let normalizedMAC = discovered.extractedMAC
            ?? peripheralDisplayMACs[discovered.id]
            ?? BlanketProtocol.normalizeMAC(manualMAC)
            ?? "8E:B2:D6:64:F8:60"
        _ = getCachedKeys(for: normalizedMAC)

        if let idx = devices.firstIndex(where: {
            $0.peripheralUUIDString == discovered.id.uuidString ||
            $0.macAddress.caseInsensitiveCompare(normalizedMAC) == .orderedSame ||
            (devices.count == 1 && $0.peripheralUUIDString == nil)
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
    }

    public func updateDeviceMetadata(deviceID: UUID, name: String, roomName: String, macAddress: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        devices[idx].roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanMAC = BlanketProtocol.normalizeMAC(macAddress) {
            devices[idx].macAddress = cleanMAC
            verifiedWorkingKeys.removeValue(forKey: deviceID)
            _ = getCachedKeys(for: cleanMAC)
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

    // MARK: - Point-to-Point Cached Direct Connection Engine (对标小程序 startConnectDevice)
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

        // 2. 如果当前设备已经通过 0x5700 广播包 CRC16 或硬件 Notify 锁定了 verifiedWorkingKeys，
        //    则可直接通过 retrievePeripherals 零扫描极速复连；
        //    如果尚未锁定广播密钥（例如首次启动），则启动扫描以捕获 0x5700 Service Data 中的精确密钥与 PID（严格对齐小程序 startConnectDevice）
        var targetPeripheral: CBPeripheral? = activePeripherals[deviceID]

        if targetPeripheral == nil,
           let uuidStr = device.peripheralUUIDString,
           let pUUID = UUID(uuidString: uuidStr),
           (verifiedWorkingKeys[deviceID] != nil || peripheralBroadcastKeys[pUUID] != nil) {
            targetPeripheral = discoveredPeripheralObjects[pUUID]
                ?? central.retrievePeripherals(withIdentifiers: [pUUID]).first
        }

        if targetPeripheral == nil,
           let discoveredMatch = discoveredPeripherals.first(where: { $0.isJingHeBlanket && $0.extractedMAC != nil }),
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
            // 启动扫描以获取 0x5700 广播包中的 CRC16 校验 PID 与 MAC
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
        pendingScanConnectTasks[deviceID]?.cancel()
        pendingScanConnectTasks.removeValue(forKey: deviceID)

        activePeripherals[deviceID] = peripheral
        discoveredPeripheralObjects[peripheral.identifier] = peripheral
        peripheralToDeviceMap[peripheral.identifier] = deviceID

        if let bKey = peripheralBroadcastKeys[peripheral.identifier] {
            verifiedWorkingKeys[deviceID] = bKey
        }
        if let pid = peripheralProductIDs[peripheral.identifier] {
            deviceProductIDs[deviceID] = pid
        }

        if let idx = devices.firstIndex(where: { $0.id == deviceID }) {
            if devices[idx].peripheralUUIDString != peripheral.identifier.uuidString {
                devices[idx].peripheralUUIDString = peripheral.identifier.uuidString
            }
            if let cleanMAC = peripheralDisplayMACs[peripheral.identifier],
               devices[idx].macAddress != cleanMAC {
                devices[idx].macAddress = cleanMAC
                _ = getCachedKeys(for: cleanMAC)
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
        delayedQueryTasks[deviceID]?.cancel()
        notifyReadyFallbackTasks[deviceID]?.cancel()
        pendingScanConnectTasks[deviceID]?.cancel()
        hasCompletedNotifyHandshake.remove(deviceID)
        if let peripheral = activePeripherals[deviceID], peripheral.state != .disconnected {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        controlCharacteristics.removeValue(forKey: deviceID)
        connectionPhases[deviceID] = .disconnected
    }

    // MARK: - High-Speed Point-to-Point Command Pipeline (严格对齐小程序 blanket.js & blanketto.js)
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

        // 严格对齐微信小程序 wx.writeBLECharacteristicValue 与 blanket_client.py：
        // 若已知该外设需要无应答写入、或特征值仅支持 .writeWithoutResponse，则直接用 .withoutResponse；
        // 若特征值支持 .write，则发送 .withResponse，同时如果 200ms 内未收到 didWriteValueFor 确认且特征值也支持 .writeWithoutResponse，自动无感兼容切换
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

    /// 延时主动拉取硬件真实状态确认
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

    // MARK: - User & AppIntent Control Actions (严格对齐小程序 blanket.js / blanketto.js & ha_mqtt_bridge.py)

    /// 1. 开关电热毯电源（内置开机后恢复上次挡位与定时记忆，并在操作后主动查询硬件状态）
    @MainActor
    public func setPower(isOn: Bool, for deviceID: UUID) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let wasOn = devices[idx].isOn

        devices[idx].isOn = isOn
        if isOn && !wasOn {
            devices[idx].currentSessionStartDate = Date()
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
            if let start = devices[idx].currentSessionStartDate {
                let elapsed = max(0, Date().timeIntervalSince(start))
                devices[idx].accumulatedRuntimeSeconds += elapsed
            }
            devices[idx].currentSessionStartDate = nil
            devices[idx].remainingTimeCloseSec = 0
        }

        if isOn {
            isPoweringOnRestoringMemory.insert(deviceID)
            let ok = await sendCommand(BlanketProtocol.cmdPower(isOn: true), to: deviceID)
            if ok, let currentIdx = devices.firstIndex(where: { $0.id == deviceID }),
               devices[currentIdx].restoreMemoryOnPowerOn {
                let targetLeft = devices[currentIdx].savedGearLeft
                let targetRight = devices[currentIdx].savedGearRight
                let targetClose = devices[currentIdx].savedTimeCloseHours

                // 留出 450ms 避开电热毯通电复位与初始状态 Notify 包突发，随后依序恢复左右温区挡位与定时
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
                self.devices[cIdx].isOn = true
                if self.devices[cIdx].currentSessionStartDate == nil {
                    self.devices[cIdx].currentSessionStartDate = Date()
                }
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
                self.devices[cIdx].isOn = true
                if self.devices[cIdx].currentSessionStartDate == nil {
                    self.devices[cIdx].currentSessionStartDate = Date()
                }
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
        devices[idx].mode = mode
        if mode == .miteRemoval {
            devices[idx].gearLeft = 9
            devices[idx].gearRight = 9
            devices[idx].timeCloseHours = 2
            devices[idx].remainingTimeCloseSec = 2 * 3600
        }
        if !devices[idx].isOn {
            devices[idx].isOn = true
            if devices[idx].currentSessionStartDate == nil {
                devices[idx].currentSessionStartDate = Date()
            }
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

    /// 7. 主动查询硬件实时状态（严格对齐小程序 blanket.js / blanketto.js 的 notifyReadWrite 查询逻辑）
    @MainActor
    public func queryStatus(for deviceID: UUID) async {
        let pid = deviceProductIDs[deviceID]
        let primaryQueryCmd = BlanketProtocol.queryCommand(forProductId: pid)
        let syncBefore = devices.first(where: { $0.id == deviceID })?.lastSyncDate

        await sendCommand(primaryQueryCmd, to: deviceID, useAltKey: false)

        // 如果 450ms 内未收到任何硬件状态回包（例如固件仅识别 5 属性查询指令 000400050152979899，或用户手动输入了正序 MAC），自动回退探测
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

    // MARK: - 1-Second Runtime & Foreground Live Sync Ticker
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
                if devices[idx].remainingTimeCloseSec == 0 {
                    Task { @MainActor [weak self] in
                        await self?.queryStatus(for: devID)
                    }
                }
            }
            if !devices[idx].isOn && devices[idx].timeOpenHours > 0 && devices[idx].remainingTimeOpenSec > 0 {
                devices[idx].remainingTimeOpenSec = max(0, devices[idx].remainingTimeOpenSec - 1)
                if devices[idx].remainingTimeOpenSec == 0 {
                    Task { @MainActor [weak self] in
                        await self?.queryStatus(for: devID)
                    }
                }
            }
        }

        // 在前台期间，每 15 秒发送一次状态查询保活并同步物理线控状态（加上 Notify 实时推送双保障）
        if !isAppInBackground && pollCounter >= 15 {
            pollCounter = 0
            if let activeID = activeDeviceID, connectionPhases[activeID] == .connected {
                Task { @MainActor [weak self] in
                    await self?.queryStatus(for: activeID)
                }
            }
        }
    }

    // MARK: - Complete Notify Handshake & Trigger Initial Status Query (严格复刻小程序 notifyReadWrite)
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
                // 留出 60ms 让恢复的 continuation（若为 sendCommand 控制调用）先行发送，避免与初始 queryStatus 并发碰撞
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

    // MARK: - Handle Decrypted Notification Payload & Lock Verified DES Key (严格复刻小程序 setBleData)
    private func handleIncomingNotification(data: Data, for deviceID: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }),
              let resolvedKeys = resolveActiveSecretKey(for: deviceID) else { return }

        // 1. 先尝试当前激活密钥（广播 CRC16 精确密钥或小端反转密钥），再尝试备用正序密钥，一旦匹配已知 TLV 前缀立即锁定 verifiedWorkingKeys
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

        if let isOn = tlv.isOn {
            devices[idx].isOn = isOn
            if !wasOn && isOn {
                // 物理线控手动开机（对应小程序 setDefaultState(1)）：默认重置为普通模式、左右温区 9 挡、定时 12 小时，并主动拉取最新状态
                devices[idx].currentSessionStartDate = Date()
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
                if let start = devices[idx].currentSessionStartDate {
                    devices[idx].accumulatedRuntimeSeconds += max(0, Date().timeIntervalSince(start))
                }
                devices[idx].currentSessionStartDate = nil
                devices[idx].remainingTimeCloseSec = 0
            }
        }

        if let mode = tlv.mode {
            devices[idx].mode = mode
            // 对应小程序 setMiteState(1)：切换至除螨模式时，自动同步为 2 小时定时与左右 9 挡
            if mode == .miteRemoval {
                devices[idx].gearLeft = 9
                devices[idx].gearRight = 9
                devices[idx].timeCloseHours = 2
                if devices[idx].remainingTimeCloseSec == 0 || devices[idx].remainingTimeCloseSec > 2 * 3600 {
                    devices[idx].remainingTimeCloseSec = 2 * 3600
                }
            }
        }
        if let gl = tlv.gearLeft {
            devices[idx].gearLeft = gl
            if devices[idx].isOn && !isPoweringOnRestoringMemory.contains(deviceID) {
                devices[idx].savedGearLeft = gl
            }
            // 若用户在实体按键上调节了挡位（仅开机状态可调挡），而本地状态尚未同步为开机，则立即触发一次全状态查询
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

        devices[idx].lastSyncDate = Date()
        let updated = devices[idx]

        // 当检测到物理线控按键或定时触发导致状态变化时，及时推送通知
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

        // 严格复刻微信小程序 behaviors/bleBehaviors.js -> filterDeviceList：
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

        // 2. 仅当存在 0x5703/0x5678/0x5679 格式且通过 checkCrc16(mfgData.dropFirst()) 校验时才从 ManufacturerData 提取，绝不盲目截取普通厂商数据！
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

            // 缓存从 CRC16 广播包提取出的 100% 精确 DES 密钥、PID 与标准 MAC
            if let info = parsedAdv {
                self.peripheralBroadcastKeys[pID] = info.exactSecretKey
                self.peripheralProductIDs[pID] = info.productId
                self.peripheralDisplayMACs[pID] = info.displayMAC
            }

            // 匹配正在等待连接的设备（严格遵循小程序 startConnectDevice 的 MAC/ServiceData 匹配原则）
            if isJingHe,
               let waitingIdx = self.devices.firstIndex(where: { dev in
                   if let info = parsedAdv {
                       let devCleanMac = dev.macAddress.replacingOccurrences(of: ":", with: "").lowercased()
                       if devCleanMac == info.rawMacHex || dev.macAddress.caseInsensitiveCompare(info.displayMAC) == .orderedSame {
                           return true
                       }
                   }
                   return self.connectionPhases[dev.id] == .connecting ||
                          dev.peripheralUUIDString == pID.uuidString ||
                          dev.peripheralUUIDString == nil
               }) {
                let targetID = self.devices[waitingIdx].id

                if let info = parsedAdv {
                    // 收到通过 CRC16 校验的 0x5700 Service Data：立即锁定精确 DES 密钥与 PID 并建立连接
                    self.devices[waitingIdx].macAddress = info.displayMAC
                    self.verifiedWorkingKeys[targetID] = info.exactSecretKey
                    self.deviceProductIDs[targetID] = info.productId
                    _ = self.getCachedKeys(for: info.displayMAC)

                    if self.activePeripherals[targetID]?.state != .connected {
                        self.bindAndConnect(peripheral: peripheral, to: targetID)
                    }
                } else if (has5700UUID || has5700Data),
                          self.activePeripherals[targetID]?.state != .connected,
                          self.pendingScanConnectTasks[targetID] == nil {
                    // 当前仅收到 ADV_IND 主广播包，留出 320ms 等待包含 0x5700 Service Data 的 SCAN_RSP 扫描响应包到达后再连接
                    self.pendingScanConnectTasks[targetID] = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 320_000_000)
                        guard !Task.isCancelled,
                              let self = self,
                              self.activePeripherals[targetID]?.state != .connected else { return }
                        self.bindAndConnect(peripheral: peripheral, to: targetID)
                    }
                }
            }

            guard !localName.isEmpty || isJingHe else { return }

            // 合并同一外设的 ADV_IND 与 SCAN_RSP 广播信息，绝不用不含 ServiceData 的广播帧覆盖已提取的 MAC
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

            // 只要 App 处于前台激活状态，意外断开时自动在 1.2s 后静默恢复连接以继续接收电热毯实体按键事件
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
                // 严格对齐微信小程序 notifyReadWrite：先开启特征值 Notify 订阅，等待 didUpdateNotificationStateFor 完成后再下发指令
                peripheral.setNotifyValue(true, for: characteristic)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let deviceID = self.peripheralToDeviceMap[pID] else { return }
                    self.controlCharacteristics[deviceID] = characteristic

                    // 保底定时器：若 iOS 缓存了 CCCD 状态未在 380ms 内触发 didUpdateNotificationStateFor，则自动完成握手
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
                // 若带应答写入 (.withResponse) 报错，立即自动回退为无应答写入 (.withoutResponse) 并记忆该偏好
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
