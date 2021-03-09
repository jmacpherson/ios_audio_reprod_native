//
//  ContentView.swift
//  audio-reprod
//
//  Created by John MacPherson on 2021-02-25.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    var body: some View {
        VStack {
            Text("Audio Reprod").font(.title)
            Button("Load", action: initAudioPlayer)
                .padding()
                .buttonStyle(PlainButtonStyle())
            Button("Play", action: startAudioPlayer)
                .padding()
                .buttonStyle(PlainButtonStyle())
            Button("Stop", action: stopAudioPlayer)
                .padding()
                .buttonStyle(PlainButtonStyle())

        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

func initAudioPlayer() {
    let session = AVAudioSession.sharedInstance()
    if session.recordPermission != AVAudioSession.RecordPermission.granted {
        session.requestRecordPermission { (response: Bool) in
            NSLog("ContentView::requestRecordPermission => granted: \(response)")
        }
    }
    
    if !AudioDeviceHost.loaded,
       let audioDevice = AudioDeviceHost.audioDevice {
        let resource = "confirmation-alert.wav"
        guard let assetPath = Bundle.main.path(forResource: resource, ofType: nil) else {
            NSLog("ContentView::initAudioPlayer => Load error. Error finding path for resource \(resource).")
            return
        }
        let url: URL = URL(fileURLWithPath: assetPath)
        let fileForPlayback: AVAudioFile?

        do {
            fileForPlayback = try AVAudioFile(forReading: url)
        } catch let error {
            NSLog("ContentView::initAudioPlayer => Load error. Error opening file \(url) for reading \(error).")
            return
        }

        if let file = fileForPlayback {
            audioDevice.addMusicNode(0, file, true, 1.0)
            NSLog("ContentView::initAudioPlayer => Load complete. Added music node for \(url).")
            AudioDeviceHost.loaded = true
        } else {
            NSLog("ContentView::initAudioPlayer => Load error. File not found \(url).")
        }
    }
}

func startAudioPlayer() {
    if AudioDeviceHost.loaded, let audioDevice = AudioDeviceHost.audioDevice {
        audioDevice.playMusic(0)
    }
}

func stopAudioPlayer() {
    if AudioDeviceHost.loaded, let audioDevice = AudioDeviceHost.audioDevice {
        audioDevice.stopMusic(0)
    }
}
