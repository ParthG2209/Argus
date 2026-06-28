import Foundation
import CoreAudio

var defaultOutputDeviceID = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

let status = AudioObjectGetPropertyData(UInt32(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultOutputDeviceID)

if status == noErr {
    print("Device ID: \(defaultOutputDeviceID)")
    var balance: Float32 = 0.0
    var balanceSize = UInt32(MemoryLayout<Float32>.size)
    var balanceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMasterBalance,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
        
    AudioObjectGetPropertyData(defaultOutputDeviceID, &balanceAddress, 0, nil, &balanceSize, &balance)
    print("Current Balance: \(balance)")
} else {
    print("Error: \(status)")
}
