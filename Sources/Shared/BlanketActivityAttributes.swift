import Foundation
import ActivityKit
import SwiftUI

/// 电热毯灵动岛与实时活动共享数据模型 (`ActivityAttributes`)
/// 同时被主 App (`SmartBlanketPro`) 与实时活动扩展 (`SmartBlanketProWidget`) 编译引用
public struct BlanketActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isOn: Bool
        public var modeRawValue: Int // 0 = 普通加热, 1 = 除螨模式
        public var gearLeft: Int
        public var gearRight: Int
        public var tempLeft: Int
        public var tempRight: Int
        public var syncDualZones: Bool
        public var sessionStartDate: Date?
        public var autoOffEndDate: Date?
        public var lastUpdated: Date

        public init(
            isOn: Bool,
            modeRawValue: Int,
            gearLeft: Int,
            gearRight: Int,
            tempLeft: Int,
            tempRight: Int,
            syncDualZones: Bool,
            sessionStartDate: Date?,
            autoOffEndDate: Date?,
            lastUpdated: Date = Date()
        ) {
            self.isOn = isOn
            self.modeRawValue = modeRawValue
            self.gearLeft = gearLeft
            self.gearRight = gearRight
            self.tempLeft = tempLeft
            self.tempRight = tempRight
            self.syncDualZones = syncDualZones
            self.sessionStartDate = sessionStartDate
            self.autoOffEndDate = autoOffEndDate
            self.lastUpdated = lastUpdated
        }

        public var isMiteRemoval: Bool {
            modeRawValue == 1
        }

        public var dominantGear: Int {
            max(gearLeft, gearRight)
        }

        /// 严格对齐主 App 的挡位色彩体系（1-2蓝 / 3-5绿 / 6-8橙 / 9或除螨红）
        public var themeColor: Color {
            guard isOn else { return .secondary }
            return Self.gearColor(for: dominantGear, isMiteRemoval: isMiteRemoval)
        }

        public static func gearColor(for gear: Int, isMiteRemoval: Bool = false) -> Color {
            if isMiteRemoval || gear >= 9 {
                return .red
            }
            switch gear {
            case 1...2: return .blue
            case 3...5: return .green
            case 6...8: return .orange
            default:    return .red
            }
        }
    }

    public var deviceID: String
    public var deviceName: String
    public var roomName: String

    public init(deviceID: String, deviceName: String, roomName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.roomName = roomName
    }
}
