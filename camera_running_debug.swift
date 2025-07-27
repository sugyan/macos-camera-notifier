// 必要なフレームワークをインポート

import Foundation
import CoreMediaIO


// システムオブジェクトIDを取得
// デバイスリストのサイズを格納する変数
let systemObjectID = CMIOObjectID(kCMIOObjectSystemObject)
var dataSize: UInt32 = 0


// デバイスリスト取得用のプロパティアドレスを設定
var deviceListAddress = CMIOObjectPropertyAddress(
    mSelector: UInt32(kCMIOHardwarePropertyDevices),
    mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
    mElement: UInt32(kCMIOObjectPropertyElementMain)
)


// デバイスリストのサイズを取得
guard CMIOObjectGetPropertyDataSize(systemObjectID, &deviceListAddress, 0, nil, &dataSize) == noErr else {
    print("Failed to get device list size.")
    exit(1)
}


// デバイス数を計算し、ID格納用配列を用意
// 実際に使用されたデータサイズ
let numberOfDevices = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
var deviceIDs = [CMIOObjectID](repeating: 0, count: numberOfDevices)
var dataUsed: UInt32 = 0


// デバイスID一覧を取得
guard CMIOObjectGetPropertyData(systemObjectID, &deviceListAddress, 0, nil, dataSize, &dataUsed, &deviceIDs) == noErr else {
    print("Failed to get device list.")
    exit(1)
}


// デバイス一覧を表示


func isAnyCameraRunning(deviceIDs: [CMIOObjectID]) -> (Bool, String?) {
    for deviceID in deviceIDs {
        var nameAddress = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIOObjectPropertyName),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var deviceName: Unmanaged<CFString>?
        var nameUsed: UInt32 = 0
        let nameStatus = CMIOObjectGetPropertyData(deviceID, &nameAddress, 0, nil, UInt32(MemoryLayout<CFString?>.size), &nameUsed, &deviceName)
        let nameStr = (nameStatus == noErr && deviceName != nil) ? deviceName!.takeRetainedValue() as String : "(Name not available)"

        var isRunningAddress = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var isRunning: UInt32 = 0
        var isRunningUsed: UInt32 = 0
        let isRunningStatus = CMIOObjectGetPropertyData(deviceID, &isRunningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &isRunningUsed, &isRunning)
        if isRunningStatus == noErr && isRunning != 0 {
            return (true, nameStr)
        }
    }
    return (false, nil)
}

var lastState: Bool? = nil
while true {
    let (isRunning, runningName) = isAnyCameraRunning(deviceIDs: deviceIDs)
    if lastState == nil || lastState != isRunning {
        if isRunning {
            print("カメラ使用中になりました: \(runningName ?? "Unknown")")
        } else {
            print("カメラが全て未使用になりました")
        }
        lastState = isRunning
    }
    sleep(1)
}
