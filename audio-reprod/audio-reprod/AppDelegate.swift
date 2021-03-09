//
//  AppDelegate.swift
//  audio-reprod
//
//  Created by John MacPherson on 2021-03-08.
//

import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
//    var audioDevice: AVAudioEngineDevice
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        AudioDeviceHost.audioDevice = AVAudioEngineDevice()
        AudioDeviceHost.audioDevice?.initialize()
        return true
    }
}


class AudioDeviceHost {
    static var loaded = false
    static var audioDevice: AVAudioEngineDevice?
}
