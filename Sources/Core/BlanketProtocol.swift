import Foundation
import CommonCrypto

/// 晶合物联 (JingHe IoT) 蓝牙电热毯核心通信协议与 DES-ECB 加解密引擎
/// 完整复刻并增强自 Home Assistant `blanket_protocol.py` 实现
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

    // MARK: - TLV Property Headers
    public static let propPower      = "01010001" // 电源开关 (1 byte: 00 关, 01 开)
    public static let propTimeOpen   = "1f020004" // 预约开机定时 (4 bytes: 小时数 0~12, 0 为关闭)
    public static let propMode       = "52020004" // 工作模式 (4 bytes: 0 普通加热, 1 高温除螨)
    public static let propGearLeft   = "97020004" // 左温区挡位 (4 bytes: 1~9)
    public static let propGearRight  = "98020004" // 右温区挡位 (4 bytes: 1~9)
    public static let propTimeClose  = "99020004" // 自动关机定时 (4 bytes: 小时数 1~12)
    public static let propRemOpen    = "9a020004" // 剩余预约开机秒数 (4 bytes: 只读秒数)
    public static let propRemClose   = "9b020004" // 剩余自动关机秒数 (4 bytes: 只读秒数)

    /// 全状态查询指令（一次性请求全部 8 个属性：01, 1f, 52, 97, 98, 99, 9a, 9b）
    public static let queryAllStatusCmd = "00040008011f529798999a9b"
    /// 核心 5 属性查询指令（兼容旧固件：01, 52, 97, 98, 99）
    public static let queryCoreStatusCmd = "000400050152979899"

    public static let knownPrefixes: [String] = [
        propPower, propMode, propGearLeft, propGearRight,
        propTimeClose, propTimeOpen, propRemOpen, propRemClose
    ]

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

    /// 从 BLE 广播的 0x5700 Service Data (14 字节) 或 Manufacturer Data 中自动提取 6 字节硬件 MAC 地址
    /// 广播 Service Data 结构：字节 0~5 为 Product ID，字节 6~11 为 MAC 地址，字节 12~13 为 CRC16
    public static func extractMACFromAdvertisement(serviceData: Data) -> String? {
        if serviceData.count >= 12 {
            let macSlice = serviceData.subdata(in: 6..<12)
            // 广播包内通常为小端字节序或正序，我们将其格式化为标准 MAC（在 getSecretKey 中同时支持正反双向验证）
            let reversedBytes = Data(macSlice.reversed())
            let hex = reversedBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            return hex
        } else if serviceData.count == 6 {
            let hex = serviceData.map { String(format: "%02X", $0) }.joined(separator: ":")
            return hex
        }
        return nil
    }

    // MARK: - Dynamic DES Key Derivation
    /// 从设备 MAC 地址派生 8 字节 DES 密钥
    /// - Parameters:
    ///   - macAddress: 设备硬件 MAC（如 `8E:B2:D6:64:F8:60`）
    ///   - reverseMac: 是否按小端序翻转 6 字节 MAC（默认 `true`，即 `60f864d6b28e5700`）
    public static func getSecretKey(macAddress: String, reverseMac: Bool = true) -> Data? {
        let clean = macAddress
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
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

    // MARK: - DES-ECB Encryption & Decryption (CommonCrypto)
    /// 封装控制指令：追加 2 字节随机盐 -> 8 字符 Hex 对齐 -> 8 字节 ZeroPadding -> DES-ECB 加密
    public static func encryptPayload(cmdHex: String, secretKey: Data) -> Data? {
        let randomSalt = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        var payloadHex = cmdHex.lowercased() + randomSalt

        let remHex = payloadHex.count % 8
        if remHex != 0 {
            payloadHex += String(repeating: "0", count: 8 - remHex)
        }

        guard var rawBytes = Data(hexString: payloadHex) else {
            return nil
        }

        // Zero-pad to 8-byte DES block boundary
        let remBytes = rawBytes.count % kCCBlockSizeDES
        if remBytes != 0 {
            rawBytes.append(Data(repeating: 0x00, count: kCCBlockSizeDES - remBytes))
        }

        return performDES(operation: CCOperation(kCCEncrypt), input: rawBytes, key: secretKey)
    }

    /// 解密电热毯上报的 Notify 密文，自动校验 TLV 前缀并在需要时回退至备用正序密钥 `altKey`
    public static func decryptPayload(cipherBytes: Data, secretKey: Data, altKey: Data? = nil) -> String? {
        guard let decrypted = performDES(operation: CCOperation(kCCDecrypt), input: cipherBytes, key: secretKey) else {
            return nil
        }
        let decHex = decrypted.hexEncodedString()

        if knownPrefixes.contains(where: { decHex.hasPrefix($0) }) {
            return decHex
        }

        if let altKey = altKey,
           let altDecrypted = performDES(operation: CCOperation(kCCDecrypt), input: cipherBytes, key: altKey) {
            let altHex = altDecrypted.hexEncodedString()
            if knownPrefixes.contains(where: { altHex.hasPrefix($0) }) {
                return altHex
            }
        }

        return decHex
    }

    /// 原生 CommonCrypto DES-ECB 运算（无外部库依赖，编译速度极快）
    private static func performDES(operation: CCOperation, input: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeDES, !input.isEmpty else { return nil }

        // 确保输入为 8 字节整数倍
        var paddedInput = input
        let rem = paddedInput.count % kCCBlockSizeDES
        if rem != 0 {
            paddedInput.append(Data(repeating: 0x00, count: kCCBlockSizeDES - rem))
        }

        let outLength = paddedInput.count
        var outBytes = [UInt8](repeating: 0, count: outLength)
        var numBytesProcessed: size_t = 0

        let status = paddedInput.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmDES),
                    CCOptions(kCCOptionECBMode), // ZeroPadding 已由业务层精确处理
                    keyBytes.baseAddress,
                    kCCKeySizeDES,
                    nil,
                    inputBytes.baseAddress,
                    paddedInput.count,
                    &outBytes,
                    outLength,
                    &numBytesProcessed
                )
            }
        }

        guard status == kCCSuccess else { return nil }
        return Data(outBytes.prefix(numBytesProcessed))
    }

    // MARK: - TLV Stream Parser
    /// 解析解密后的 TLV 十六进制状态流
    public static func parseTLVData(hexString: String) -> BlanketTLVUpdate {
        var update = BlanketTLVUpdate()
        let hex = hexString.lowercased()
        let chars = Array(hex)
        var i = 0

        while i + 8 <= chars.count {
            let propID = String(chars[i..<(i + 2)])
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

            switch propID {
            case "01":
                update.isOn = (val == 1)
                update.hasValidProperty = true
            case "52":
                update.mode = (val == 1) ? .miteRemoval : .normal
                update.hasValidProperty = true
            case "97":
                if (1...9).contains(val) {
                    update.gearLeft = val
                }
                update.hasValidProperty = true
            case "98":
                if (1...9).contains(val) {
                    update.gearRight = val
                }
                update.hasValidProperty = true
            case "99":
                if (0...24).contains(val) {
                    update.timeCloseHours = val
                }
                update.hasValidProperty = true
            case "1f":
                if (0...24).contains(val) {
                    update.timeOpenHours = val
                }
                update.hasValidProperty = true
            case "9a":
                update.remainingTimeOpenSec = max(0, val)
                update.hasValidProperty = true
            case "9b":
                update.remainingTimeCloseSec = max(0, val)
                update.hasValidProperty = true
            default:
                break
            }

            i = valEnd
        }

        return update
    }

    // MARK: - Command Generators
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
