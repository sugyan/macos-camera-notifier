// Camera Monitor - Real-time camera usage detection for macOS
// Uses CoreMediaIO framework to monitor camera device status changes

import Foundation
import CoreMediaIO

// Get system object ID for CoreMediaIO queries
let systemObjectID = CMIOObjectID(kCMIOObjectSystemObject)
var dataSize: UInt32 = 0

// Configure property address for device list retrieval
var deviceListAddress = CMIOObjectPropertyAddress(
    mSelector: UInt32(kCMIOHardwarePropertyDevices),
    mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
    mElement: UInt32(kCMIOObjectPropertyElementMain)
)

// Get the size of device list data
guard CMIOObjectGetPropertyDataSize(systemObjectID, &deviceListAddress, 0, nil, &dataSize) == noErr else {
    print("Failed to get device list size.")
    exit(1)
}

// Calculate number of devices and prepare array to store device IDs
let numberOfDevices = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
var deviceIDs = [CMIOObjectID](repeating: 0, count: numberOfDevices)
var dataUsed: UInt32 = 0

// Retrieve the actual device ID list
guard CMIOObjectGetPropertyData(systemObjectID, &deviceListAddress, 0, nil, dataSize, &dataUsed, &deviceIDs) == noErr else {
    print("Failed to get device list.")
    exit(1)
}

// Function to check if any camera device is currently running
func isAnyCameraRunning(deviceIDs: [CMIOObjectID]) -> (Bool, String?) {
    for deviceID in deviceIDs {
        // Get device name
        var nameAddress = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIOObjectPropertyName),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var deviceName: Unmanaged<CFString>?
        var nameUsed: UInt32 = 0
        let nameStatus = CMIOObjectGetPropertyData(deviceID, &nameAddress, 0, nil, UInt32(MemoryLayout<CFString?>.size), &nameUsed, &deviceName)
        let nameStr = (nameStatus == noErr && deviceName != nil) ? deviceName!.takeRetainedValue() as String : "(Name not available)"

        // Check if device is currently running
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

// Main monitoring loop
print("Camera Monitor started. Monitoring camera status changes...")
var lastState: Bool? = nil

while true {
    let (isRunning, runningName) = isAnyCameraRunning(deviceIDs: deviceIDs)
    
    // Only print status changes to avoid spam
    if lastState == nil || lastState != isRunning {
        if isRunning {
            print("📷 Camera started: \(runningName ?? "Unknown device")")
        } else {
            print("📷 All cameras stopped")
        }
        lastState = isRunning
    }
    
    sleep(1)
}