// swiftlint:disable file_length

import Foundation
import AVFoundation
import UIKit

// swiftlint:disable type_body_length
public class AVAudioEngineDevice: NSObject {
    private let myPropertyQueue: DispatchQueue = DispatchQueue(
        label: "AVAudioEngineDevice_Queue",
        qos: DispatchQoS.utility,
        autoreleaseFrequency: DispatchQueue.AutoreleaseFrequency.workItem,
        target: nil)

    public static let kPreferredIOBufferDuration: Double = 0.01

    // We will use mono playback and recording where available.
    public static let kPreferredNumberOfChannels: UInt32 = 1

    // An audio sample is a signed 16-bit integer.
    public static let kAudioSampleSize: UInt32 = 2
    public static let kPreferredSampleRate: UInt32 = 48000

    /*
     * Calls to AudioUnitInitialize() can fail if called back-to-back after a format change or adding and removing tracks.
     * A fall-back solution is to allow multiple sequential calls with a small delay between each. This factor sets the max
     * number of allowed initialization attempts.
     */
    public static let kMaxNumberOfAudioUnitInitializeAttempts: Int = 5

    // The VoiceProcessingIO audio unit uses bus 0 for ouptut, and bus 1 for input.
    public static let kOutputBus: UInt32 = 0
    public static let kInputBus: UInt32 = 1

    // This is the maximum slice size for VoiceProcessingIO (as observed in the field). We will double check at initialization time.
    public static var kMaximumFramesPerBuffer: UInt32 = 3072

    /// Properties
    var interrupted: Bool = false
    var isStartingRenderer: Bool = false
    var isStoppingRenderer: Bool = false
    var isRendering: Bool = false
    var audioUnit: AudioUnit?
    var captureBufferList: AudioBufferList = AudioBufferList()

    var renderingContext: AudioRendererContext
    var capturingContext: AudioCapturerContext

    // AudioEngine properties
    var playoutEngine: AVAudioEngine?

    let audioPlayerNodeManager: AVAudioPlayerNodeManager = AVAudioPlayerNodeManager()

    // MARK: Init & Dealloc
    override public init() {
        debug("AVAudioEngineDevice::init => START")
        /*
         * Initialize rendering and capturing context. The deviceContext will be be filled in when startRendering or
         * startCapturing gets called.
         */
        self.renderingContext = AudioRendererContext()
        self.renderingContext.maxFramesPerBuffer = Int(AVAudioEngineDevice.kMaximumFramesPerBuffer)
        self.capturingContext = AudioCapturerContext(
            bufferList: UnsafeMutablePointer<AudioBufferList>(&self.captureBufferList),
            mixedAudioBufferList: UnsafeMutablePointer<AudioBufferList?>.allocate(
                capacity: MemoryLayout<AudioBufferList>.size))
        self.capturingContext.mixedAudioBufferList.initialize(to: nil)
        super.init()

        self.initialize()
        self.renderingContext.maxFramesPerBuffer = Int(AVAudioEngineDevice.kMaximumFramesPerBuffer)
        // Setup the AVAudioEngine along with the rendering context
        if !self.setupPlayoutAudioEngine() {
            debug("Failed to setup AVAudioEngine")
        }

        self.setupAVAudioSession()
        debug("AVAudioEngineDevice::init => END")
    }

    deinit {
        debug("AVAudioEngineDevice::deinit")
        self.disposeAllNodes()
        self.stopRendering()
        self.teardownAudioEngine()
    }

    func description() -> NSString {
        return "AVAudioEngine Audio Mixing"
    }

    /*
     * Determine at runtime the maximum slice size used by VoiceProcessingIO. Setting the stream format and sample rate
     * doesn't appear to impact the maximum size so we prefer to read this value once at initialization time.
     */
    func initialize() {
        debug("AVAudioEngineDevice::initialize")
        var audioUnitDescription: AudioComponentDescription = AVAudioEngineDevice.audioUnitDescription()
        guard let audioComponent: AudioComponent = AudioComponentFindNext(nil, &audioUnitDescription) else {
            debug("Could not retrieve AudioComponents!")
            return
        }
        var audioUnitRaw: AudioUnit?
        var status: OSStatus = AudioComponentInstanceNew(audioComponent, &audioUnitRaw)
        if status != 0 {
            debug("Could not find VoiceProcessingIO AudioComponent instance!")
            return
        }

        guard let audioUnit = audioUnitRaw else {
            debug("Could not find VoiceProcessingIO AudioComponent instance!")
            return
        }

        var framesPerSlice: UInt32 = 0
        var propertySize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        status = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global, AVAudioEngineDevice.kOutputBus,
                                      &framesPerSlice, &propertySize)
        if status != 0 {
            debug("Could not read VoiceProcessingIO AudioComponent instance!")
            AudioComponentInstanceDispose(audioUnit)
            return
        }

        debug("This device uses a maximum slice size of \(framesPerSlice) frames.")
        AVAudioEngineDevice.kMaximumFramesPerBuffer = framesPerSlice
        AudioComponentInstanceDispose(audioUnit)

        var bufferListData = UnsafeMutablePointer<Int8>.allocate(capacity: Int(AVAudioEngineDevice.kMaximumFramesPerBuffer * AVAudioEngineDevice.kPreferredNumberOfChannels * AVAudioEngineDevice.kAudioSampleSize))

        renderingContext.bufferList = AudioBufferList(mNumberBuffers: 1,
                                                      mBuffers: AudioBuffer(
                                                       mNumberChannels: AVAudioEngineDevice.kPreferredNumberOfChannels,
                                                       mDataByteSize: UInt32(0),
                                                       mData: bufferListData))
    }

    // MARK: Private (AVAudioEngine)

    func setupAudioEngine() -> Bool {
        debug("AVAudioEngineDevice::setupAudioEngine")
        return self.setupPlayoutAudioEngine()
    }

    // swiftlint:disable:next function_body_length
    func setupPlayoutAudioEngine() -> Bool {
        debug("AVAudioEngineDevice::setupPlayoutAudioEngine")
        assert(self.playoutEngine == nil, "AVAudioEngine is already configured")

        /*
         * By default AVAudioEngine will render to/from the audio device, and automatically establish connections between
         * nodes, e.g. inputNode -> effectNode -> outputNode.
         */
        self.playoutEngine = AVAudioEngine()

        guard let engine = self.playoutEngine else {
            return false
        }

        var asbd: AudioStreamBasicDescription = streamDescription()
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            return false
        }

        // Switch to manual rendering mode
        engine.stop()
        do {
            debug("AVAudioEngineDevice::setupPlayoutAudioEngine => maximumFrameCount: \(AVAudioEngineDevice.kMaximumFramesPerBuffer)")
            try engine.enableManualRenderingMode(AVAudioEngineManualRenderingMode.realtime, format: format, maximumFrameCount: AVAudioEngineDevice.kMaximumFramesPerBuffer)
        } catch let error {
            debug("Failed to setup manual rendering mode, error = \(error)")
            return false
        }

        /*
         * In manual rendering mode, AVAudioEngine won't receive audio from the microhpone. Instead, it will receive the
         * audio data from the Video SDK and mix it in MainMixerNode. Here we connect the input node to the main mixer node.
         * InputNode -> MainMixer -> OutputNode
         */
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: format)

        /*
         * Attach AVAudioPlayerNode node to play music from a file.
         * AVAudioPlayerNode -> ReverbNode -> AVAudioUnitEQ -> MainMixer -> OutputNode (note: ReverbNode is optional)
         */
        if self.audioPlayerNodeManager.shouldReattachNodes() {
            self.reattachMusicNodes()
        }

        // Set the block to provide input data to engine
        let inputNode: AVAudioInputNode = engine.inputNode
        let success: Bool = inputNode.setManualRenderingInputPCMFormat(format) { [unowned self] (inNumberOfFrames: AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? in
            assert(inNumberOfFrames <= AVAudioEngineDevice.kMaximumFramesPerBuffer)

            let context: AudioRendererContext = self.renderingContext
            let bufferList = context.bufferList

            guard let audioBuffer = self.renderingContext.bufferList.mBuffers.mData?.assumingMemoryBound(to: Int8.self) else {
                return nil
            }

            var audioBufferSizeInBytes: Int = Int(self.renderingContext.bufferList.mBuffers.mDataByteSize)

            /*
             * Return silence when we do not have the playout device context. This is the
             * case when the remote participant has not published an audio track yet.
             * Since the audio graph and audio engine has been setup, we can still play
             * the music file using AVAudioEngine.
             */
            memset(audioBuffer, 0, audioBufferSizeInBytes)

            var result = bufferList
            return UnsafePointer<AudioBufferList>(&result)
        }

        if !success {
            debug("Failed to set the manual rendering block")
            return false
        }

        // The manual rendering block (called in Core Audio's VoiceProcessingIO's playout callback at real time)
        self.renderingContext.renderBlock = engine.manualRenderingBlock

        do {
            debug("AVAudioEngine::setupPlayoutAudioEngine => start engine")
            try engine.start()
        } catch let error {
            debug("Failed to start AVAudioEngine, error = \(error)")
            return false
        }

        debug("AVAudioEngineDevice::setupPlayoutAudioEngine => end")
        return true
    }

    func teardownPlayoutAudioEngine() {
        debug("AVAudioEngineDevice::teardownPlayoutAudioEngine")
        if let engine = self.playoutEngine, engine.isRunning {
            engine.stop()
        }
        self.playoutEngine = nil
    }

    func teardownAudioEngine() {
        debug("AVAudioEngineDevice::teardownAudioEngine")
        self.teardownPlayoutAudioEngine()
    }

    // MARK: Audio File Playback API

    public func playMusic(_ id: Int) {
        safelyPlayMusic {
            debug("AVAudioEngineDevice::playMusic => QUEUE - DispatchQueue.main.async")
            DispatchQueue.main.async {
                debug("AVAudioEngineDevice::playMusic => START - DispatchQueue.main.async id: \(id)")
                self.audioPlayerNodeManager.playNode(id)
                debug("AVAudioEngineDevice::playMusic => END - DispatchQueue.main.async: \(id)")
            }
            debug("AVAudioEngineDevice::playMusic => END")
        }
    }

    func safelyPlayMusic(_ playCallback: @escaping () -> Void) {
        myPropertyQueue.async {
            debug("AVAudioEngineDevice::safelyPlayMusic => START - myPropertyQueue.async")
            debug("AVAudioEngineDevice::playMusic => startingRenderer: \(self.isStartingRenderer), isRendering: \(self.isRendering), stoppingRenderer: \(self.isStoppingRenderer)")

            // Could collapse isRendering/isStartingRenderer/isStoppingRenderer into a single state enum
            if self.isRendering {
                    debug("AVAudioEngineDevice::playMusic => scheduleMusicOnPlayoutEngine => dispatch")
                // Since the engine is already rendering, no need to queue playCallback on myPropertyQueue to ensure that it occurs after rendering is started
                playCallback()
            } else if self.isStartingRenderer {
                self.myPropertyQueue.async {
                    playCallback()
                }
            } else {
                debug("AVAudioEngineDevice::playMusic => startRendering")

                if self.startRenderingInternal() {
                    debug("AVAudioEngineDevice::playMusic => startRendering => scheduleMusicOnPlayoutEngine")
                    self.myPropertyQueue.async {
                        playCallback()
                    }
                } else {
                    debug("AVAudioEngineDevice::playMusic => startRendering failed")
                }
            }
            debug("AVAudioEngineDevice::safelyPlayMusic => END - myPropertyQueue.async")
        }
    }

    public func stopMusic(_ id: Int) {
        debug("AVAudioEngineDevice::stopMusic => \(id)")
        self.audioPlayerNodeManager.stopNode(id)

        if !self.audioPlayerNodeManager.anyPlaying(),
           !self.audioPlayerNodeManager.anyPaused(),
            !self.isStartingRenderer,
            !self.isStoppingRenderer {
            self.stopRendering()
        }
    }

    public func pauseMusic(_ id: Int) {
        debug("AVAudioEngineDevice::pauseNode => \(id)")
        self.audioPlayerNodeManager.pauseNode(id)
    }

    public func resumeMusic(_ id: Int) {
        debug("AVAudioEngineDevice::resumeMusic => \(id)")
        self.audioPlayerNodeManager.resumeNode(id)
    }

    public func setMusicVolume(_ id: Int, _ volume: Double) {
        self.audioPlayerNodeManager.setMusicVolume(id, volume)
    }

    public func seekPosition(_ id: Int, _ positionInMillis: Int) {
        safelyPlayMusic {
            debug("AVAudioEngineDevice::seekPosition => QUEUE - DispatchQueue.main.async")
            DispatchQueue.main.async {
                debug("AVAudioEngineDevice::seekPosition => START - DispatchQueue.main.async")
                debug("AVAudioEngineDevice::seekPosition => id: \(id), positionInMillis: \(positionInMillis)")
                self.audioPlayerNodeManager.seekPosition(id, Int64(positionInMillis))
                debug("AVAudioEngineDevice::seekPosition => END - DispatchQueue.main.async")
            }
        }
    }

    public func getPosition(_ id: Int) -> Int64 {
        debug("AVAudioEngineDevice::getPosition => id: \(id)")
        return self.audioPlayerNodeManager.getPosition(id)
    }

    func disposeAllNodes() {
        self.audioPlayerNodeManager.nodes.keys.forEach { (id) in
            disposeMusicNode(id)
        }
    }

    public func disposeMusicNode(_ id: Int) {
        debug("AVAudioEngineDevice::disposeMusicNode => id: \(id)")
        guard let playoutEngine = self.playoutEngine,
              let node = self.audioPlayerNodeManager.getNode(id) else {
            return
        }

        stopMusic(id)

        playoutEngine.disconnectNodeOutput(node.eq)
        playoutEngine.disconnectNodeOutput(node.reverb)
        playoutEngine.disconnectNodeOutput(node.player)

        playoutEngine.detach(node.eq)
        playoutEngine.detach(node.reverb)
        playoutEngine.detach(node.player)

        self.audioPlayerNodeManager.disposeNode(id)
    }

    public func addMusicNode(_ id: Int, _ file: AVAudioFile, _ loop: Bool, _ volume: Double) {
        if self.playoutEngine == nil {
            self.setupPlayoutAudioEngine()
        }

        let nodeBundle = self.audioPlayerNodeManager.addNode(id, file, loop, volume)
        self.attachMusicNode(nodeBundle)
    }

    func reattachMusicNodes() {
        debug("AVAudioEngineDevice::reattachMusicNodes")
        self.audioPlayerNodeManager.nodes.values.forEach { (_ node: AVAudioPlayerNodeBundle) in
            attachMusicNode(node)
        }
    }

    func attachMusicNode(_ nodeBundle: AVAudioPlayerNodeBundle) {
        debug("AVAudioEngineDevice::attachMusicNode => node: \(nodeBundle.id)")
        guard let playoutEngine = self.playoutEngine else {
            return
        }

        playoutEngine.attach(nodeBundle.player)
        playoutEngine.attach(nodeBundle.reverb)
        playoutEngine.attach(nodeBundle.eq)
        playoutEngine.connect(nodeBundle.player, to: nodeBundle.reverb, format: nodeBundle.file.processingFormat)
        playoutEngine.connect(nodeBundle.reverb, to: nodeBundle.eq, format: nodeBundle.file.processingFormat)
        playoutEngine.connect(nodeBundle.eq, to: playoutEngine.mainMixerNode, format: nodeBundle.file.processingFormat)
    }

    // MARK: TVIAudioDeviceRenderer
    // swiftlint:disable:next function_body_length
    func startRenderingInternal() -> Bool {
        debug("AVAudioEngineDevice::startRenderingInternal => START - current thread main: \(Thread.current.isMainThread)")

        var result = false

        self.isStartingRenderer = true
        self.isRendering = false

        /*
         * We will restart the audio unit if a remote participant adds an audio track after the audio graph is
         * established. Also we will re-establish the audio graph in case the format changes.
         *
         * We will start the audioGraph if playback of an attached audio node is requested while
         * rendering is not already underway.
         */
        if self.audioUnit != nil {
            debug("AVAudioEngineDevice::startRenderingInternal => stop audioUnit")
            self.stopAudioUnit()
            self.teardownAudioUnit()
        }

        debug("AVAudioEngineDevice::startRenderingInternal => QUEUE - DispatchQueue.main.async")
        // We will make sure AVAudioEngine and AVAudioPlayerNode is accessed on the main queue.
        DispatchQueue.main.async {
            debug("AVAudioEngineDevice::startRenderingInternal => START - DispatchQueue.main.async")
            if self.audioPlayerNodeManager.anyPlaying() {
                debug("AVAudioEngineDevice::startRenderingInternal => pause active audio nodes")
                /*
                * Since startRenderingInternal should always be run on the local DispatchQueue
                * we do not need to dispatch this call here. Further, we want to ensure this
                * completes execution prior to stopping the audio unit.
                */
                self.audioPlayerNodeManager.pauseAll(true)
            }

            if let engine = self.playoutEngine {
                if engine.isRunning {
                    debug("AVAudioEngineDevice::startRenderingInternal => stopping engine")
                    engine.stop()
                }

                do {
                    debug("AVAudioEngineDevice::startRenderingInternal => starting engine")
                    try engine.start()
                } catch let error {
                    debug("Failed to start AVAudioEngine, error = \(error)")
                }
            } else {
            /*
             * If the engine is not configured properly we will tear it down,
             * restart it, reattach audio nodes as needed.
             */
                self.teardownPlayoutAudioEngine()
                self.setupPlayoutAudioEngine()
            }

            // Resume playback on audio player nodes that were active prior to engine restart
            if self.audioPlayerNodeManager.anyPaused() {
                /*
                 * ensure fadeIn/resume is happening on the same queue as other
                 * requests to change player state
                 */
                self.myPropertyQueue.async {
                    self.audioPlayerNodeManager.resumeAll()
                }
            }
            debug("AVAudioEngineDevice::startRenderingInternal => END - DispatchQueue.main.async")
        }

        if !self.setupAudioUnitWithRenderContext(renderContext: &self.renderingContext) {
            result = false
            self.isStartingRenderer = false
            self.isRendering = false
            return false
        }

        result = self.startAudioUnit()

        self.isStartingRenderer = false
        self.isRendering = true

        debug("AVAudioEngineDevice::startRenderingInternal => END")

        return result
    }

    public func stopRendering() -> Bool {
        debug("AVAudioEngineDevice::stopRendering => nodes playing: \(self.audioPlayerNodeManager.anyPlaying()), nodes paused: \(self.audioPlayerNodeManager.anyPaused())")
        self.isStoppingRenderer = true
        self.isRendering = false
        myPropertyQueue.async {
            debug("AVAudioEngineDevice::stopRendering => START - myPropertyQueue.async")
            // If the capturer is running, we will not stop the audio unit.
            if !self.audioPlayerNodeManager.anyPlaying(),
               !self.audioPlayerNodeManager.anyPaused() {
                debug("AVAudioEngineDevice::stopRendering => stopAudioUnit")
                self.stopAudioUnit()
                self.teardownAudioUnit()
            }

            if let engine = self.playoutEngine,
               engine.isRunning,
               !self.audioPlayerNodeManager.anyPlaying(),
               !self.audioPlayerNodeManager.anyPaused() {
                debug("AVAudioEngineDevice::stopRendering => QUEUE - DispatchQueue.main.async")
                // We will make sure AVAudioEngine and AVAudioPlayerNode is accessed on the main queue.
                DispatchQueue.main.async {
                    debug("AVAudioEngineDevice::stopRendering => START - DispatchQueue.main.async")

                    // If audio player nodes are in use, we will not stop the engine
                    if let engine = self.playoutEngine {
                        debug("AVAudioEngineDevice::stopRendering => stop playoutEngine")
                        engine.stop()
                    }
                    debug("AVAudioEngineDevice::stopRendering => END - DispatchQueue.main.async")
                    self.isStoppingRenderer = false
                }
            } else {
                self.isStoppingRenderer = false
            }
            debug("AVAudioEngineDevice::stopRendering => END - myPropertyQueue.async")
        }

        return true
    }

    static func audioUnitDescription() -> AudioComponentDescription {
        debug("AVAudioEngineDevice::audioUnitDescription")
        var audioUnitDescription: AudioComponentDescription = AudioComponentDescription()
        audioUnitDescription.componentType = kAudioUnitType_Output
        audioUnitDescription.componentSubType = kAudioUnitSubType_VoiceProcessingIO
        audioUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple
        audioUnitDescription.componentFlags = 0
        audioUnitDescription.componentFlagsMask = 0
        return audioUnitDescription
    }

    func setupAVAudioSession() {
        debug("AVAudioEngineDevice::setupAVAudioSession")
        let session: AVAudioSession = AVAudioSession.sharedInstance()

        do {
            try session.setPreferredSampleRate(Double(AVAudioEngineDevice.kPreferredSampleRate))
            try session.setPreferredOutputNumberOfChannels(Int(AVAudioEngineDevice.kPreferredNumberOfChannels))
            /*
             * We want to be as close as possible to the 10 millisecond buffer size that the media engine needs. If there is
             * a mismatch then TwilioVideo will ensure that appropriately sized audio buffers are delivered.
             */
            try session.setPreferredIOBufferDuration(AVAudioEngineDevice.kPreferredIOBufferDuration)
            try session.setCategory(AVAudioSession.Category.playAndRecord)
            try session.setMode(AVAudioSession.Mode.videoChat)
        } catch let error {
            debug("Error setting up AudioSession: \(error)")
        }

        do {
            try session.setActive(true, options: AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation)
        } catch let error {
            debug("Error activating AVAudioSession: \(error)")
        }

        if session.maximumInputNumberOfChannels > 0 {
            do {
                try session.setPreferredInputNumberOfChannels(1)
            } catch let error {
                debug("Error setting number of input channels: \(error)")
            }
        }
    }
    
    func streamDescription() -> AudioStreamBasicDescription {
        // Taken from configuration used by Twilio
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: 1819304813,
            mFormatFlags: 12,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)
        return asbd
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func setupAudioUnitWithRenderContext(renderContext: inout AudioRendererContext) -> Bool {
        debug("AVAudioEngineDevice::setupAudioUnitWithRenderContext")
        // Find and instantiate the VoiceProcessingIO audio unit.
        var audioUnitDescription: AudioComponentDescription = AVAudioEngineDevice.audioUnitDescription()
        guard let audioComponent: AudioComponent = AudioComponentFindNext(nil, &audioUnitDescription) else {
            debug("Could not find VoiceProcessingIO AudioComponent!")
            return false
        }

        var status: OSStatus = AudioComponentInstanceNew(audioComponent, &self.audioUnit)
        if status != 0 {
            debug("Could not find VoiceProcessingIO AudioComponent instance!")
            return false
        }

        /*
         * Configure the VoiceProcessingIO audio unit. Our rendering format attempts to match what AVAudioSession requires
         * to prevent any additional format conversions after the media engine has mixed our playout audio.
         */
        var asbd: AudioStreamBasicDescription = streamDescription()

        guard let audioUnit = self.audioUnit else {
            debug("Could not find AudioUnit.")
            return false
        }

        var enableOutput: UInt32 = 1
        var enableInput: UInt32 = 1
        let uint32Size = UInt32(MemoryLayout<UInt32>.size)
        let streamDescriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let auRenderCallbackStructSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)

        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, AVAudioEngineDevice.kOutputBus,
                                      &enableOutput, uint32Size)
        if status != 0 {
            debug("Could not enable out bus!")
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
            return false
        }

        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, AVAudioEngineDevice.kInputBus,
                                      &asbd, streamDescriptionSize)
        if status != 0 {
            debug("Could not set stream format on input bus!")
            return false
        }

        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, AVAudioEngineDevice.kOutputBus,
                                      &asbd, streamDescriptionSize)
        if status != 0 {
            debug("Could not set stream format on output bus!")
            return false
        }

        // Enable the microphone input
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, AVAudioEngineDevice.kInputBus, &enableInput,
                                      uint32Size)

        if status != 0 {
            debug("Could not enable input bus!")
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
            return false
        }

        // Setup the rendering callback.
        var renderCallback: AURenderCallbackStruct = AURenderCallbackStruct()
        renderCallback.inputProc = AVAudioEngineDevicePlayoutCallback
        renderCallback.inputProcRefCon = UnsafeMutableRawPointer(&renderContext)
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Output, AVAudioEngineDevice.kOutputBus, &renderCallback,
                                      auRenderCallbackStructSize)
        if status != 0 {
            debug("Could not set rendering callback!")
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
            return false
        }

        // Setup the capturing callback.
        var captureContext = self.capturingContext
        var captureCallback: AURenderCallbackStruct = AURenderCallbackStruct()
        captureCallback.inputProc = AVAudioEngineDeviceRecordCallback
        captureCallback.inputProcRefCon = UnsafeMutableRawPointer(&captureContext)
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Input, AVAudioEngineDevice.kInputBus, &captureCallback,
                                      auRenderCallbackStructSize)
        if status != 0 {
            debug("Could not set capturing callback!")
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
            return false
        }

        var failedInitializeAttempts: NSInteger = 0
        while status != noErr {
            debug("Failed to initialize the Voice Processing I/O unit. Error= \(status).")
            failedInitializeAttempts += 1
            if failedInitializeAttempts == AVAudioEngineDevice.kMaxNumberOfAudioUnitInitializeAttempts {
                break
            }
            debug("Pause 100ms and try audio unit initialization again.")
            Thread.sleep(forTimeInterval: 0.1)
            status = AudioUnitInitialize(audioUnit)
        }

        // Finally, initialize and start the VoiceProcessingIO audio unit.
        if status != 0 {
            debug("Could not initialize the audio unit! => OSStatus: \(status)")
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
            return false
        }

        debug("AVAudioEngineDevice::setupAudioUnitWithRenderContext => setting captureContext audioUnit")

        return true
    }

    func startAudioUnit() -> Bool {
        debug("AVAudioEngineDevice::startAudioUnit => START")
        guard let audioUnitUnwrapped = self.audioUnit else {
            return false
        }

        var result = false
        var failedInitializeAttempts: NSInteger = 0
        while failedInitializeAttempts < AVAudioEngineDevice.kMaxNumberOfAudioUnitInitializeAttempts {
            debug("AVAudioEngineDevice::startAudioUnit => failed attempts: \(failedInitializeAttempts)")
            let status: OSStatus = AudioOutputUnitStart(audioUnitUnwrapped)
            if status == noErr {
                result = true
                break
            }
            debug("Failed to start output on the Voice Processing I/O unit. Error= \(status).")
            failedInitializeAttempts += 1

            debug("Pause 100ms and try audio unit initialization again.")
            Thread.sleep(forTimeInterval: 0.1)
        }

        debug("AVAudioEngineDevice::startAudioUnit => END => started: \(result)")
        return result
    }

    func stopAudioUnit() -> Bool {
        debug("AVAudioEngineDevice::stopAudioUnit")
        guard let audioUnitUnwrapped = self.audioUnit else {
            return false
        }

        let status: OSStatus = AudioOutputUnitStop(audioUnitUnwrapped)
        if status != 0 {
            debug("Could not stop the audio unit!")
            return false
        }
        return true
    }

    func teardownAudioUnit() {
        debug("AVAudioEngineDevice::teardownAudioUnit")
        if let audioUnitUnwrapped = self.audioUnit {
            AudioUnitUninitialize(audioUnitUnwrapped)
            AudioComponentInstanceDispose(audioUnitUnwrapped)
            self.audioUnit = nil
        }
    }
}

// MARK: Private (AudioUnit callbacks)
// swiftlint:disable:next function_parameter_count
func AVAudioEngineDevicePlayoutCallback(inRefCon: UnsafeMutableRawPointer,
                                        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                        inTimestamp: UnsafePointer<AudioTimeStamp>,
                                        inBusNumber: UInt32,
                                        inNumberFrames: UInt32,
                                        ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    debug("AVAudioEngineDevice::AVAudioEngineDevicePlayoutCallback => BEGIN PlayoutCallback - inNumberFrames: \(inNumberFrames)")
    guard let ioData = ioData else {
        debug("AVAudioEngineDevice::AVAudioEngineDevicePlayoutCallback => no ioData")
        return noErr
    }
    assert(ioData.pointee.mNumberBuffers == 1)
    assert(ioData.pointee.mBuffers.mNumberChannels <= 2)
    assert(ioData.pointee.mBuffers.mNumberChannels > 0)

    var context = inRefCon.assumingMemoryBound(to: AudioRendererContext.self)
    context.pointee.bufferList = ioData.pointee

    var audioBufferSizeInBytes: UInt32 = ioData.pointee.mBuffers.mDataByteSize

    // Pull decoded, mixed audio data from the media engine into the AudioUnit's AudioBufferList.
    assert(audioBufferSizeInBytes == (ioData.pointee.mBuffers.mNumberChannels * AVAudioEngineDevice.kAudioSampleSize * inNumberFrames))
    var outputStatus: OSStatus = noErr

    // Get the mixed audio data from AVAudioEngine's output node by calling the `renderBlock`
    guard let renderBlock: AVAudioEngineManualRenderingBlock = context.pointee.renderBlock,
        let maxFramesPerBuffer = context.pointee.maxFramesPerBuffer else {
        debug("AVAudioEngineDevice::AVAudioEngineDevicePlayoutCallback => renderBlock: \(context.pointee.renderBlock), maxFrames: \(context.pointee.maxFramesPerBuffer)")
        return outputStatus
    }

    let status: AVAudioEngineManualRenderingStatus = renderBlock(inNumberFrames, ioData, &outputStatus)

    /*
     * Render silence if there are temporary mismatches between CoreAudio and our rendering format or AVAudioEngine
     * could not render the audio samples.
     */
    if inNumberFrames > maxFramesPerBuffer || status != AVAudioEngineManualRenderingStatus.success {
        if inNumberFrames > maxFramesPerBuffer {
            debug("Can handle a max of \(maxFramesPerBuffer) frames but got \(inNumberFrames).")
        }
        debug("AVAudioEngineDevice::AVAudioEngineDevicePlayoutCallback => render silence. inNumberFrames: \(inNumberFrames), maxFramesPerBuffer: \(maxFramesPerBuffer), status: \(status.rawValue)")
        ioActionFlags.pointee = AudioUnitRenderActionFlags(rawValue: ioActionFlags.pointee.rawValue | AudioUnitRenderActionFlags.unitRenderAction_OutputIsSilence.rawValue)
        memset(ioData.pointee.mBuffers.mData, 0, Int(audioBufferSizeInBytes))
    }
    
    debug("AVAudioEngineDevice::AVAudioEngineDevicePlayoutCallback => END PlayoutCallback")

    return noErr
}

// swiftlint:disable:next function_parameter_count
func AVAudioEngineDeviceRecordCallback(inRefCon: UnsafeMutableRawPointer,
                                       ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                       inTimestamp: UnsafePointer<AudioTimeStamp>,
                                       inBusNumber: UInt32,
                                       inNumberFrames: UInt32,
                                       ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    // stub
    return noErr
}

class AudioRendererContext {
    // Maximum frames per buffer.
    var maxFramesPerBuffer: Int?

    // Buffer passed to AVAudioEngine's manualRenderingBlock to receive the mixed audio data.
    var bufferList: AudioBufferList = AudioBufferList()

    /*
     * Points to AVAudioEngine's manualRenderingBlock. This block is called from within the VoiceProcessingIO playout
     * callback in order to receive mixed audio data from AVAudioEngine in real time.
     */
    var renderBlock: AVAudioEngineManualRenderingBlock?
}

class AudioCapturerContext {
    // Preallocated buffer list. Please note the buffer itself will be provided by Core Audio's VoiceProcessingIO audio unit.
    var bufferList: UnsafeMutablePointer<AudioBufferList>

    // Preallocated mixed (AudioUnit mic + AVAudioPlayerNode file) audio buffer list.
    var mixedAudioBufferList: UnsafeMutablePointer<AudioBufferList?>

    // Core Audio's VoiceProcessingIO audio unit.
    var audioUnit: AudioUnit?

    /*
     * Points to AVAudioEngine's manualRenderingBlock. This block is called from within the VoiceProcessingIO playout
     * callback in order to receive mixed audio data from AVAudioEngine in real time.
     */
    var renderBlock: AVAudioEngineManualRenderingBlock?

    init(bufferList: UnsafeMutablePointer<AudioBufferList>, mixedAudioBufferList: UnsafeMutablePointer<AudioBufferList?>) {
        self.bufferList = bufferList
        self.mixedAudioBufferList = mixedAudioBufferList
    }
}

public class AVAudioPlayerNodeManager {
    var nodes: [Int: AVAudioPlayerNodeBundle] = [:]
    var pausedNodes: [Int: AVAudioPlayerNodeBundle] = [:]

    func addNode(_ id: Int, _ file: AVAudioFile, _ loop: Bool, _ volume: Double) -> AVAudioPlayerNodeBundle {
        let player: AVAudioPlayerNode = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ()
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(AVAudioUnitReverbPreset.mediumHall)
        reverb.wetDryMix = 50

        let nodeBundle = AVAudioPlayerNodeBundle(id, player, reverb, file, loop, eq)
        nodes[id] = nodeBundle
        setMusicVolume(id, volume)

        return nodeBundle
    }

    func disposeNode(_ id: Int) {
        guard let node = getNode(id) else {
            return
        }

        nodes.removeValue(forKey: id)
    }

    func shouldReattachNodes() -> Bool {
        return !nodes.values.isEmpty
    }

    func getNode(_ id: Int) -> AVAudioPlayerNodeBundle? {
        guard let node = nodes[id] else {
            debug("AVAudioPlayerNodeManager::getNode => node not found for id: \(id)")
            return nil
        }

        return node
    }

    public func playNode(_ id: Int) {
        play(id)
    }

    func play(_ id: Int, position: AVAudioFramePosition = 0) {
        guard let node = nodes[id] else {
            return
        }

        if !node.playing {
            let frameCount: AVAudioFrameCount = AVAudioFrameCount(node.file.length - position)

            debug("AVAudioPlayerNodeManager::play => file: \(fileName(node.file)), from: \(position), for: \(frameCount), loop: \(node.loop)")

            node.player.scheduleSegment(node.file, startingFrame: position, frameCount: frameCount, at: nil) {
                debug("AVAudioPlayerNodeManager::segmentComplete => file: \(self.fileName(node.file)). playing: \(node.playing), startedAt: \(position), loop: \(node.loop)")
                if node.loop && node.playing && !self.isPaused(node.id) {
                    node.playing = false
                    self.play(node.id)
                } else {
                    node.playing = false
                }
            }
            node.playing = true
            node.startFrame = position
            node.pauseTime = nil
            node.player.play()
            setMusicVolume(node.id, node.volume)
        }
    }

    func fileName(_ file: AVAudioFile) -> String {
        return String(describing: file.url.absoluteString.split(separator: "/").last)
    }

    public func stopNode(_ id: Int) {
        guard let node = nodes[id] else {
            return
        }
        debug("AVAudioPlayerNodeManager::stopNode => file: \(fileName(node.file))")

        if isPaused(id) {
            node.pauseTime = nil
            pausedNodes.removeValue(forKey: node.id)
        }
        node.playing = false

        node.player.stop()
    }

    public func pauseNode(_ id: Int, _ resumeAfterRendererStarted: Bool = false) {
        guard let node = nodes[id] else {
            return
        }

        node.pauseTime = getPosition(id)
        node.playing = false
        node.resumeAfterRendererStarted = resumeAfterRendererStarted

        node.player.stop()
        pausedNodes[node.id] = node
        debug("AVAudioPlayerNodeManager::pauseNode => paused node \(node.id) pauseTime: \(node.pauseTime)")
    }

    public func resumeNode(_ id: Int) {
        guard let node = nodes[id],
              let pausePosition = node.pauseTime else {
            return
        }

        if node.player.isPlaying {
            return
        }

        debug("AVAudioPlayerNodeManager::resumeNode => node \(node.id), frame: \(pausePosition), volume: \(node.volume)")

        node.resumeAfterRendererStarted = false
        seekPosition(id, pausePosition)
        pausedNodes.removeValue(forKey: node.id)
    }

    public func setMusicVolume(_ id: Int, _ volume: Double) {
        guard let node = nodes[id] else {
            return
        }

        node.volume = volume
        var gain = volumeToGain(volume)

        debug("AVAudioPlayerNodeManager::setMusicVolume => id: \(id), volume: \(volume), gain: \(gain)")

        node.eq.globalGain = Float(gain)
    }

    func fadeOutNode(_ node: AVAudioPlayerNodeBundle) {
        debug("AVAudioPlayerNodeManager::fadeOutNode => START - node \(node.id), volume \(node.volume)")
        var volume = gainToVolume(node.eq.globalGain)
        var increment = volume / 10
        fadeOut(node, volume, increment)
        debug("AVAudioPlayerNodeManager::fadeOutNode => END - node \(node.id)")
    }

    func fadeOut(_ node: AVAudioPlayerNodeBundle, _ volume: Double, _ volumeIncrement: Double) {
        let vol = volume >= 0 ? volume : 0
        node.eq.globalGain = volumeToGain(volume)
        debug("AVAudioPlayerNodeManager::fadeOut => START - node \(node.id), volume \(node.volume) currentVolume: \(volume)")

        if volume > 0 {
            let timeSecs = 0.001  /// 1 ms
            Thread.sleep(forTimeInterval: timeSecs)
            let nextStep = volume - volumeIncrement
            fadeOut(node, nextStep, volumeIncrement)
        }
    }

    func fadeInNode(_ node: AVAudioPlayerNodeBundle) {
        debug("AVAudioPlayerNodeManager::fadeInNode => START - node \(node.id), volume \(node.volume)")
        var increment = node.volume / 10
        fadeIn(node, 0, increment)
        debug("AVAudioPlayerNodeManager::fadeInNode => END - node \(node.id)")
    }

    func fadeIn(_ node: AVAudioPlayerNodeBundle, _ volume: Double, _ volumeIncrement: Double) {
        let vol = volume <= node.volume ? volume : node.volume
        node.eq.globalGain = volumeToGain(vol)
        debug("AVAudioPlayerNodeManager::fadeIn => START - node \(node.id), volume \(node.volume) currentVolume: \(volume)")

        if volume < node.volume {
            let timeSecs = 0.001  /// 1 ms
            Thread.sleep(forTimeInterval: timeSecs)
            let nextStep = volume + volumeIncrement
            fadeIn(node, nextStep, volumeIncrement)
        }
    }

    /**
    * Convert volume range of 0 (silence) -> 1.0 to AVAudioUnitEQ globalGain range of -96.0 (silence) -> 0.0 db
    *
    * AVAudioUnitEQ supports a globalGain range of -96.0 - 24.0 db
    * While developing this it was found that increasing db beyond 0 (thus amplifying the original sound of the audio file) results in
    * audio artifacts during playback. As a result, limiting audio range from -96 db (silent) to 0 (normal volume)
    */
    func volumeToGain(_ vol: Double) -> Float {
        var gain = Float((vol * 96) - 96)
        gain = restrictGainRange(gain)
        return gain
    }

    func gainToVolume(_ gain: Float) -> Double {
        let boundedGain = restrictGainRange(gain)
        let volume = Double((boundedGain + 96) / 96)
        return volume
    }

    func restrictGainRange(_ gain: Float) -> Float {
        if gain < -96 {
            return -96
        } else if gain > 0 {
            return 0
        } else {
            return gain
        }
    }

    public func seekPosition(_ id: Int, _ positionInMillis: Int64) {
        guard let node = nodes[id] else {
            return
        }

        var framePosition = AVAudioFramePosition((Double(positionInMillis) * node.file.processingFormat.sampleRate) / 1000)
        if framePosition < 0 || framePosition >= node.file.length {
            framePosition = 0
        }
        debug("AVAudioPlayerNodeManager::seekPosition => id: \(id), positionInMillis: \(positionInMillis), framePosition: \(framePosition), lengthInFrames: \(node.file.length)")

        node.playing = false
        node.player.stop()

        self.play(node.id, position: framePosition)
    }

    public func getPosition(_ id: Int) -> Int64 {
        guard let node = nodes[id] else {
            return 0
        }

        if node.player.isPlaying {
            /**
             *  Compute position in milliseconds.
             *  `lastRenderTime` has been observed to be invalid when position is retrieved immediately after
             *  starting playback, but before a render frame has taken place. As a result, we will consider the position
             *  to be the frame as which play was initiated.
             *
             *  `node.startFrame`                 => frame at which player was started
             *  `playerTime.sampleTime`    => frames elapsed since player started
             *  `node.file.length`               => number of frames in the file
             *  `playerTime.sampleRate`    => number of frames per second
             *  `1000`                                          => number of milliseconds in a second
             */
            let position: Int64 = {
                if let lastRenderTime = node.player.lastRenderTime,
                  lastRenderTime.isSampleTimeValid,
                  let playerTime = node.player.playerTime(forNodeTime: lastRenderTime) {
                    return Int64((Double((node.startFrame + playerTime.sampleTime) % node.file.length) / node.file.fileFormat.sampleRate) * 1000)
                } else {
                    return Int64((Double((node.startFrame) % node.file.length) / node.file.fileFormat.sampleRate) * 1000)
                }
            }()

            return position
        } else if isPaused(id),
                  let pauseTime = node.pauseTime {
            return pauseTime
        }

        return 0
    }

    public func anyPlaying() -> Bool {
        var result = false
        for nodeBundle in nodes.values where nodeBundle.player.isPlaying {
            debug("AVAudioPlayerNodeManager::anyPlaying => node \(nodeBundle.id) is playing")
            result = true
            break
        }
        debug("AVAudioPlayerNodeManager::anyPlaying => \(result)")
        return result
    }

    public func anyPaused() -> Bool {
        return !pausedNodes.values.isEmpty
    }

    func isPaused(_ id: Int) -> Bool {
        return pausedNodes[id] != nil
    }

    public func pauseAll(_ resumeAfterRendererStarted: Bool = false) {
        self.nodes.values.forEach { (node: AVAudioPlayerNodeBundle) in
            if node.player.isPlaying {
                self.pauseNode(node.id, resumeAfterRendererStarted)
            }
        }
    }

    public func resumeAll() {
        self.pausedNodes.values.forEach { (node: AVAudioPlayerNodeBundle) in
            if node.resumeAfterRendererStarted {
                self.resumeNode(node.id)
            }
        }
    }
}

class AVAudioPlayerNodeBundle {
    let id: Int
    let player: AVAudioPlayerNode
    let reverb: AVAudioUnitReverb
    let file: AVAudioFile
    let loop: Bool
    var pauseTime: Int64?
    var playing: Bool = false
    var startFrame: Int64 = 0
    var resumeAfterRendererStarted: Bool = false
    let eq: AVAudioUnitEQ
    var volume: Double

    init(_ id: Int, _ player: AVAudioPlayerNode, _ reverb: AVAudioUnitReverb, _ file: AVAudioFile, _ loop: Bool, _ eq: AVAudioUnitEQ, _ volume: Double = 0) {
        self.id = id
        self.player = player
        self.reverb = reverb
        self.file = file
        self.loop = loop
        self.eq = eq
        self.volume = volume
    }
}

func debug(_ msg: String) {
    NSLog(msg)
}
