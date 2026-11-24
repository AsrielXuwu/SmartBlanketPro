import Foundation
import CommonCrypto

/// 晶合物联 (JingHe IoT) 蓝牙电热毯核心通信协议与 DES-ECB 加解密引擎
/// 严格对照原版微信小程序源码 (`utils/des.js`, `utils/ble/helper.js`, `utils/ble/CRC.js`, `behaviors/bleBehaviors.js`, `subpkgs/blepanelA/pages/blanket/blanket.js`, `subpkgs/blepanelA/pages/blanketto/blanketto.js`) 完整对齐
public enum BlanketProtocol {

    // MARK: - BLE GATT UUID Constants
    /// 广播发现服务 UUID (16-bit: 0x5700)
    public static let advertisementServiceUUID = "5700"
    public static let advertisementFullServiceUUID = "00005700-0000-1000-8000-00805F9B34FB"

    /// 核心控制服务与特征值 UUID
    public static let controlServiceUUID = "4A485200-4A48-1000-8000-00805F9B34FB"
    public static let controlCharacteristicUUID = "4A486201-4A48-1000-8000-00805F9B34FB"

    /// 固件版本服务与特征值 UUID (可选读取)
    public static let versionServiceUUID = "4A485100-4A48-1000-8000-00805F9B34FB"
    public static let versionCharacteristicUUID = "4A486101-4A48-1000-8000-00805F9B34FB"

    // MARK: - TLV Property Headers (严格对齐小程序 blanket.js / blanketto.js)
    public static let propPower      = "01010001" // 电源开关 (1 byte: 00 关, 01 开)
    public static let propTimeOpen   = "1f020004" // 预约开机定时 (4 bytes: 小时数 0~12, 0 为关闭)
    public static let propMode       = "52020004" // 工作模式 (4 bytes: 0 普通加热, 1 高温除螨)
    public static let propGearLeft   = "97020004" // 左温区挡位 (4 bytes: 1~9)
    public static let propGearRight  = "98020004" // 右温区挡位 (4 bytes: 1~9)
    public static let propTimeClose  = "99020004" // 自动关机定时 (4 bytes: 小时数 1~12)
    public static let propRemOpen    = "9a020004" // 剩余预约开机秒数 (4 bytes: 只读秒数)
    public static let propRemClose   = "9b020004" // 剩余自动关机秒数 (4 bytes: 只读秒数)

    /// 全状态 8 属性查询指令（对应小程序 `blanketto.js` 默认查询：`01, 1f, 52, 97, 98, 99, 9a, 9b`）
    public static let queryAllStatusCmd = "00040008011f529798999a9b"
    /// 6 属性查询指令（对应小程序 `productId == "230714000008"`：`01, 1f, 52, 97, 98, 99`）
    public static let querySixStatusCmd = "00040006011f52979899"
    /// 核心 5 属性查询指令（对应小程序 `productId == "230713000003"` 及 HA `blanket_protocol.py`：`01, 52, 97, 98, 99`）
    public static let queryCoreStatusCmd = "000400050152979899"

    public static let knownPrefixes: [String] = [
        propPower, propMode, propGearLeft, propGearRight,
        propTimeClose, propTimeOpen, propRemOpen, propRemClose
    ]

    /// 防重放随机盐历史队列（严格复刻小程序 `writeRandom: ["0000"]`，保留最近 20 个随机数，禁止出现 `"0000"` 或重复值）
    private static var writeRandomHistory: [String] = ["0000"]
    private static let randomLock = NSLock()

    /// 根据小程序 `blanketto.js` 的 `productId` 返回匹配的查询指令
    public static func queryCommand(forProductId pid: String?) -> String {
        guard let pid = pid, !pid.isEmpty else {
            return queryCoreStatusCmd
        }
        if pid == "230713000003" {
            return queryCoreStatusCmd
        } else if pid == "230714000008" {
            return querySixStatusCmd
        } else {
            return queryAllStatusCmd
        }
    }

    // MARK: - Gear <-> Temperature Calibration (18°C ~ 45°C)
    public static let gearToTempMap: [Int: Int] = [
        1: 18,
        2: 21,
        3: 25,
        4: 28,
        5: 32,
        6: 35,
        7: 38,
        8: 42,
        9: 45
    ]

    /// 根据硬件挡位 (1~9) 获取标称摄氏温度 (18°C~45°C)
    public static func gearToTemp(_ gear: Int) -> Int {
        let clamped = min(9, max(1, gear))
        return gearToTempMap[clamped] ?? 32
    }

    /// 根据摄氏温度换算硬件挡位 (1~9)
    public static func tempToGear(_ temp: Double) -> Int {
        if temp <= 18.0 { return 1 }
        if temp >= 45.0 { return 9 }
        let mapped = Int(round(1.0 + (temp - 18.0) * 8.0 / (45.0 - 18.0)))
        return min(9, max(1, mapped))
    }

    // MARK: - WeChat MiniProgram CRC16 (`utils/ble/CRC.js`)
    /// 严格复刻微信小程序 `utils/ble/CRC.js` 的 CRC16 算法（多项式 `33800` = `0x8408`，初值 `0`）
    public static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 33800
                } else {
                    crc = crc >> 1
                }
            }
        }
        return crc & 0xFFFF
    }

    /// 严格复刻微信小程序 `checkCrc16(e)`：校验末尾 2 字节大端 CRC16 是否与前 N-2 字节匹配
    public static func checkCrc16(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return false }
        let calc = crc16(bytes[0..<(bytes.count - 2)])
        let expected = (UInt16(bytes[bytes.count - 2]) << 8) | UInt16(bytes[bytes.count - 1])
        return calc == expected
    }

    // MARK: - WeChat MiniProgram Advertisement Parsing (`utils/ble/helper.js` -> `getPidAndMac`)
    public struct ParsedAdvertisementInfo: Sendable {
        /// 6 字节产品 ID 十六进制字符串（如 `"230713000003"`）
        public let productId: String
        /// 广播包原始 6 字节 `deviceManufactCode` 小写十六进制（如 `"60f864d6b28e"`，小程序直接用 `rawMacHex + "5700"` 作为 DES 密钥）
        public let rawMacHex: String
        /// 人类可读标准冒号分隔 MAC 地址（如 `"8E:B2:D6:64:F8:60"`）
        public let displayMAC: String
        /// 100% 匹配微信小程序 `this.data.productInfo.deviceManufactCode + "5700"` 的 8 字节 DES 密钥
        public let exactSecretKey: Data
    }

    /// 严格按照微信小程序 `filterDeviceList` + `getPidAndMac` 从 `0x5700` Service Data (14 字节) 解析 `pid`、`mac` 与 8 字节 DES 密钥
    public static func parseServiceData5700(_ serviceData: Data) -> ParsedAdvertisementInfo? {
        guard serviceData.count >= 12 else { return nil }
        // 若长度为完整 14 字节，执行与小程序完全一致的 checkCrc16 校验，杜绝脏数据
        if serviceData.count >= 14 {
            let packet14 = serviceData.prefix(14)
            guard checkCrc16(packet14) else { return nil }
        }

        let pidSlice = serviceData.subdata(in: 0..<6)
        let macSlice = serviceData.subdata(in: 6..<12)

        let pidHex = pidSlice.hexEncodedString().lowercased()
        let rawMacHex = macSlice.hexEncodedString().lowercased()

        // 小程序密钥公式：secretKey = deviceManufactCode + "5700"，即 macSlice 原始 6 字节直接拼接 [0x57, 0x00]
        var secretKey = Data(macSlice)
        secretKey.append(contentsOf: [0x57, 0x00])

        // 广播中的 6 字节为小端序，反转为标准大端显示格式（如 60:F8:64:D6:B2:8E -> 8E:B2:D6:64:F8:60）
        let reversedBytes = Data(macSlice.reversed())
        let displayMAC = reversedBytes.map { String(format: "%02X", $0) }.joined(separator: ":")

        return ParsedAdvertisementInfo(
            productId: pidHex,
            rawMacHex: rawMacHex,
            displayMAC: displayMAC,
            exactSecretKey: secretKey
        )
    }

    /// 严格按照微信小程序 `filterDeviceList` 从 `0x5703` / `0x5678` / `0x5679` 的 `advertisData` (ManufacturerData) 解析
    /// 注意：必须通过 `checkCrc16(data.dropFirst())` 校验才允许提取，绝不从普通厂商数据中盲目截取字节！
    public static func parseVerifiedManufacturerData(_ mfgData: Data) -> ParsedAdvertisementInfo? {
        guard mfgData.count >= 15 else { return nil }
        let payloadWithCrc = mfgData.subdata(in: 1..<15)
        guard checkCrc16(payloadWithCrc) else { return nil }

        let pidSlice = mfgData.subdata(in: 1..<7)
        let macSlice = mfgData.subdata(in: 7..<13)

        let pidHex = pidSlice.hexEncodedString().lowercased()
        let rawMacHex = macSlice.hexEncodedString().lowercased()

        var secretKey = Data(macSlice)
        secretKey.append(contentsOf: [0x57, 0x00])

        let reversedBytes = Data(macSlice.reversed())
        let displayMAC = reversedBytes.map { String(format: "%02X", $0) }.joined(separator: ":")

        return ParsedAdvertisementInfo(
            productId: pidHex,
            rawMacHex: rawMacHex,
            displayMAC: displayMAC,
            exactSecretKey: secretKey
        )
    }

    // MARK: - MAC Address Normalization & Extraction
    /// 规范化 MAC 地址为 `XX:XX:XX:XX:XX:XX` 大写格式
    public static func normalizeMAC(_ raw: String) -> String? {
        let clean = raw
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard clean.count == 12, clean.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        var parts: [String] = []
        var idx = clean.startIndex
        for _ in 0..<6 {
            let nextIdx = clean.index(idx, offsetBy: 2)
            parts.append(String(clean[idx..<nextIdx]))
            idx = nextIdx
        }
        return parts.joined(separator: ":")
    }

    /// 从 BLE 广播的 0x5700 Service Data (14 字节) 中安全提取 6 字节硬件 MAC 地址
    public static func extractMACFromAdvertisement(serviceData: Data) -> String? {
        if let parsed = parseServiceData5700(serviceData) {
            return parsed.displayMAC
        }
        return nil
    }

    // MARK: - Dynamic DES Key Derivation
    /// 从设备 MAC 地址派生 8 字节 DES 密钥
    /// - Parameters:
    ///   - macAddress: 设备硬件 MAC（如 `8E:B2:D6:64:F8:60` 或广播原始 `60:F8:64:D6:B2:8E`）
    ///   - reverseMac: 是否按小端序翻转 6 字节 MAC（默认 `true`，将 `8E:B2:D6:64:F8:60` 转换为 `60f864d6b28e5700`）
    public static func getSecretKey(macAddress: String, reverseMac: Bool = true) -> Data? {
        let clean = macAddress
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard clean.count == 12, let macData = Data(hexString: clean), macData.count == 6 else {
            return nil
        }

        let targetMacData = reverseMac ? Data(macData.reversed()) : macData
        var keyData = targetMacData
        // 拼接固定后缀 0x57, 0x00 -> 恰好 8 字节 (64-bit DES Key)
        keyData.append(contentsOf: [0x57, 0x00])
        return keyData
    }

    /// 生成不重复的 4 位十六进制防重放随机盐（严格复刻小程序 `getSendData` 的 `writeRandom` 队列逻辑）
    private static func nextRandomSaltHex() -> String {
        randomLock.lock()
        defer { randomLock.unlock() }

        var candidate = "ffff"
        for _ in 0..<100 {
            let randVal = UInt16.random(in: 1...0xFFFE)
            let hex = String(format: "%04x", randVal)
            if !writeRandomHistory.contains(hex) {
                candidate = hex
                break
            }
        }
        writeRandomHistory.append(candidate)
        if writeRandomHistory.count > 20 {
            writeRandomHistory.removeFirst()
        }
        return candidate
    }

    // MARK: - DES-ECB Encryption & Decryption (CommonCrypto, 严格复刻 utils/des.js)
    /// 封装控制指令：追加 2 字节不重复随机盐 -> 8 字符 Hex 对齐 -> 8 字节 ZeroPadding -> DES-ECB 加密
    public static func encryptPayload(cmdHex: String, secretKey: Data) -> Data? {
        let randomSalt = nextRandomSaltHex()
        var payloadHex = cmdHex.lowercased() + randomSalt

        let remHex = payloadHex.count % 8
        if remHex != 0 {
            payloadHex += String(repeating: "0", count: 8 - remHex)
        }

        guard var rawBytes = Data(hexString: payloadHex) else {
            return nil
        }

        // Zero-pad to 8-byte DES block boundary (CryptoJS.pad.ZeroPadding)
        let remBytes = rawBytes.count % kCCBlockSizeDES
        if remBytes != 0 {
            rawBytes.append(Data(repeating: 0x00, count: kCCBlockSizeDES - remBytes))
        }

        return performDES(operation: CCOperation(kCCEncrypt), input: rawBytes, key: secretKey)
    }

    /// 解密电热毯上报的 Notify 密文，自动校验 TLV 头部并在需要时回退至备用密钥 `altKey`
    public static func decryptPayload(cipherBytes: Data, secretKey: Data, altKey: Data? = nil) -> String? {
        guard let decrypted = performDES(operation: CCOperation(kCCDecrypt), input: cipherBytes, key: secretKey) else {
            return nil
        }
        let decHex = decrypted.hexEncodedString().lowercased()

        if knownPrefixes.contains(where: { decHex.hasPrefix($0) }) {
            return decHex
        }

        if let altKey = altKey,
           let altDecrypted = performDES(operation: CCOperation(kCCDecrypt), input: cipherBytes, key: altKey) {
            let altHex = altDecrypted.hexEncodedString().lowercased()
            if knownPrefixes.contains(where: { altHex.hasPrefix($0) }) {
                return altHex
            }
        }

        return decHex
    }

    /// 原生 CommonCrypto DES-ECB 运算
    private static func performDES(operation: CCOperation, input: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeDES, !input.isEmpty else { return nil }

        var paddedInput = Data(input)
        let rem = paddedInput.count % kCCBlockSizeDES
        if rem != 0 {
            paddedInput.append(Data(repeating: 0x00, count: kCCBlockSizeDES - rem))
        }

        let outLength = paddedInput.count
        var outBytes = [UInt8](repeating: 0, count: outLength)
        var numBytesProcessed: size_t = 0

        let inputArray = [UInt8](paddedInput)
        let keyArray = [UInt8](key)

        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode),
            keyArray,
            kCCKeySizeDES,
            nil,
            inputArray,
            inputArray.count,
            &outBytes,
            outLength,
            &numBytesProcessed
        )

        guard status == kCCSuccess else { return nil }
        return Data(outBytes.prefix(numBytesProcessed))
    }

    // MARK: - TLV Stream Parser (严格复刻小程序 blanket.js / blanketto.js 的 handleBleData & setBleData)
    /// 解析解密后的 TLV 十六进制状态流
    /// 小程序逻辑：
    /// `for (; e.length >= 10;) { var t = 2 * parseInt(e.slice(7, 8)) + 8; this.setBleData(e.slice(0, t)), e = e.slice(t) }`
    public static func parseTLVData(hexString: String) -> BlanketTLVUpdate {
        var update = BlanketTLVUpdate()
        let hex = hexString.lowercased()
        let chars = Array(hex)
        var i = 0

        while i + 10 <= chars.count {
            let header = String(chars[i..<(i + 8)])
            // 严格校验 8 字符 TLV 头部是否属于已知属性标识（防止将末尾 2 字节随机盐误解析为属性）
            guard knownPrefixes.contains(header) else {
                break
            }

            let lenHex = String(chars[(i + 4)..<(i + 8)])
            guard let valLen = Int(lenHex, radix: 16), valLen > 0, valLen <= 16 else {
                break
            }

            let valStart = i + 8
            let valEnd = valStart + (2 * valLen)
            guard valEnd <= chars.count else {
                break
            }

            let valHex = String(chars[valStart..<valEnd])
            guard let val = Int(valHex, radix: 16) else {
                break
            }

            switch header {
            case propPower:
                update.isOn = (val == 1)
                update.hasValidProperty = true
            case propMode:
                update.mode = (val == 1) ? .miteRemoval : .normal
                update.hasValidProperty = true
            case propGearLeft:
                if val >= 1 {
                    update.gearLeft = min(9, max(1, val))
                }
                update.hasValidProperty = true
            case propGearRight:
                if val >= 1 {
                    update.gearRight = min(9, max(1, val))
                }
                update.hasValidProperty = true
            case propTimeClose:
                if (0...24).contains(val) {
                    update.timeCloseHours = val
                }
                update.hasValidProperty = true
            case propTimeOpen:
                if (0...24).contains(val) {
                    update.timeOpenHours = val
                }
                update.hasValidProperty = true
            case propRemOpen:
                update.remainingTimeOpenSec = max(0, val)
                update.hasValidProperty = true
            case propRemClose:
                update.remainingTimeCloseSec = max(0, val)
                update.hasValidProperty = true
            default:
                break
            }

            i = valEnd
        }

        return update
    }

    // MARK: - Command Generators (严格对齐小程序 blanket.js / blanketto.js)
    public static func cmdPower(isOn: Bool) -> String {
        String(format: "%@%02x", propPower, isOn ? 1 : 0)
    }

    public static func cmdMode(_ mode: BlanketHeatingMode) -> String {
        String(format: "%@%08x", propMode, mode.rawValue)
    }

    public static func cmdGearLeft(_ gear: Int) -> String {
        let clamped = min(9, max(1, gear))
        return String(format: "%@%08x", propGearLeft, clamped)
    }

    public static func cmdGearRight(_ gear: Int) -> String {
        let clamped = min(9, max(1, gear))
        return String(format: "%@%08x", propGearRight, clamped)
    }

    public static func cmdTimeClose(hours: Int) -> String {
        let clamped = min(12, max(1, hours))
        return String(format: "%@%08x", propTimeClose, clamped)
    }

    public static func cmdTimeOpen(hours: Int) -> String {
        let clamped = min(12, max(0, hours))
        return String(format: "%@%08x", propTimeOpen, clamped)
    }
}

// MARK: - Heating Mode & Parsed TLV Update Struct
public enum BlanketHeatingMode: Int, Codable, CaseIterable, Identifiable, Sendable {
    case normal = 0
    case miteRemoval = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .normal: return "普通加热"
        case .miteRemoval: return "除螨模式"
        }
    }

    public var subtitle: String {
        switch self {
        case .normal: return "双温区 1~9 挡独立恒温"
        case .miteRemoval: return "2 小时 45°C 高温深层除螨"
        }
    }

    public var symbolName: String {
        switch self {
        case .normal: return "flame.fill"
        case .miteRemoval: return "sparkles"
        }
    }
}

public struct BlanketTLVUpdate: Sendable {
    public var hasValidProperty: Bool = false
    public var isOn: Bool?
    public var mode: BlanketHeatingMode?
    public var gearLeft: Int?
    public var gearRight: Int?
    public var timeCloseHours: Int?
    public var timeOpenHours: Int?
    public var remainingTimeOpenSec: Int?
    public var remainingTimeCloseSec: Int?
}

// MARK: - Data Hex Extensions
extension Data {
    public init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let nextIndex = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    public func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
