// 必要なフレームワークをインポート
import Foundation
import CoreMediaIO


// システムオブジェクトIDを取得
let systemObjectID = CMIOObjectID(kCMIOObjectSystemObject)
// デバイスリストのサイズを格納する変数
var dataSize: UInt32 = 0


// デバイスリスト取得用のプロパティアドレスを設定
var deviceListAddress = CMIOObjectPropertyAddress(
    mSelector: UInt32(kCMIOHardwarePropertyDevices), // デバイス一覧
    mScope: UInt32(kCMIOObjectPropertyScopeGlobal),  // グローバルスコープ
    mElement: UInt32(kCMIOObjectPropertyElementMain) // メイン要素
)


// デバイスリストのサイズを取得
let status1 = CMIOObjectGetPropertyDataSize(systemObjectID, &deviceListAddress, 0, nil, &dataSize)
guard status1 == noErr else {
    print("Failed to get device list size.") // 失敗時
    exit(1)
}


// デバイス数を計算し、ID格納用配列を用意
let numberOfDevices = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
var deviceIDs = [CMIOObjectID](repeating: 0, count: numberOfDevices)
// 実際に使用されたデータサイズ
var dataUsed: UInt32 = 0


// デバイスID一覧を取得
let status2 = CMIOObjectGetPropertyData(systemObjectID, &deviceListAddress, 0, nil, dataSize, &dataUsed, &deviceIDs)
guard status2 == noErr else {
    print("Failed to get device list.") // 失敗時
    exit(1)
}


// デバイス一覧を表示
print("Device List: (numberOfDevices=\(numberOfDevices))")
for deviceID in deviceIDs {
    // デバイス名取得用のプロパティアドレスを設定
    var nameAddress = CMIOObjectPropertyAddress(
        mSelector: UInt32(kCMIOObjectPropertyName), // デバイス名
        mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
        mElement: UInt32(kCMIOObjectPropertyElementMain)
    )
    // デバイス名を格納する変数
    var deviceName: Unmanaged<CFString>?
    let nameSize = UInt32(MemoryLayout<CFString?>.size)
    var nameUsed: UInt32 = 0
    // デバイス名を取得
    let nameStatus = CMIOObjectGetPropertyData(deviceID, &nameAddress, 0, nil, nameSize, &nameUsed, &deviceName)
    let nameStr: String
    if nameStatus == noErr, let cfStr = deviceName?.takeRetainedValue() {
        nameStr = cfStr as String
    } else {
        nameStr = "(Name not available)" // 取得失敗時
    }

    // デバイスが使用中かどうかのプロパティアドレスを設定
    var isRunningAddress = CMIOObjectPropertyAddress(
        mSelector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere), // 使用中判定
        mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
        mElement: UInt32(kCMIOObjectPropertyElementMain)
    )
    // 使用中かどうかの値を格納する変数
    var isRunning: UInt32 = 0
    let isRunningSize = UInt32(MemoryLayout<UInt32>.size)
    var isRunningUsed: UInt32 = 0
    // デバイスが使用中かどうかを取得
    let isRunningStatus = CMIOObjectGetPropertyData(deviceID, &isRunningAddress, 0, nil, isRunningSize, &isRunningUsed, &isRunning)

    // デバイスID・名前・使用中かどうかを表示
    print("Device ID \(deviceID): \(nameStr) | isRunningSomewhere=\(isRunning) (status=\(isRunningStatus))")
}
