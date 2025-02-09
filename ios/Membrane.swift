import MembraneRTC
import React
import ReplayKit


#if os(iOS)
@available(iOS 12, *)
public extension RPSystemBroadcastPickerView {
  static func show(for preferredExtension: String? = nil, showsMicrophoneButton: Bool = false) {
    let view = RPSystemBroadcastPickerView()
    view.preferredExtension = preferredExtension
    view.showsMicrophoneButton = showsMicrophoneButton
    let selector = NSSelectorFromString("buttonPressed:")
    if view.responds(to: selector) {
      view.perform(selector, with: nil)
    }
  }
}
#endif

public extension NSDictionary {
  func toMetadata() -> Metadata {
    var res: Metadata = .init()
    self.forEach { entry in
      if let key = entry.key as? String {
        res[key] = entry.value
      }
    }
    return res
  }
}

public extension AnyJson {
  func toDict() -> [String: Any] {
    var res: [String: Any] = [:]
    self.keys.forEach { key in
        res[key] = self[key]
    }
    return res
  }
}

extension String: Error {}

public extension String {
  func toTrackEncoding() -> TrackEncoding? {
    switch(self) {
    case "l":
      return TrackEncoding.l
    case "m":
      return TrackEncoding.m
    case "h":
      return TrackEncoding.h
    default:
      return nil
    }
  }
}

@objc(Membrane)
class Membrane: RCTEventEmitter, MembraneRTCDelegate {
  var localVideoTrack: LocalVideoTrack?
  var localAudioTrack: LocalAudioTrack?
  var localScreencastTrack: LocalScreenBroadcastTrack?
  var localUserMetadata: Metadata = .init()
  var videoTrackMetadata: Metadata = .init()
  var audioTrackMetadata: Metadata = .init()
  
  var errorMessage: String?
  var isMicEnabled: Bool = true
  var isCameraEnabled: Bool = true
  var isScreensharingEnabled: Bool = false
  
  
  var localParticipantId: String?
  var isFrontCamera: Bool = true
  
  var room: MembraneRTC? = nil;
  var connectResolve: RCTPromiseResolveBlock? = nil
  var connectReject: RCTPromiseRejectBlock? = nil
  var joinResolve: RCTPromiseResolveBlock? = nil
  var joinReject: RCTPromiseRejectBlock? = nil
  var videoQuality: String? = nil
  var flipVideo: Bool = true
  var videoSimulcastConfig: SimulcastConfig = SimulcastConfig()
  var videoBandwidthLimit: TrackBandwidthLimit = .BandwidthLimit(0)
  var screenshareSimulcastConfig: SimulcastConfig = SimulcastConfig()
  var screenshareBandwidthLimit: TrackBandwidthLimit = .BandwidthLimit(0)
  var globalToLocalTrackId: [String:String] = [:]
  
  var isSpeakersphoneOn = true
  
  var tracksContexts: [String: TrackContext] = [:]
  
  private func getGlobalTrackId(localTrackId: String) -> String? {
    return globalToLocalTrackId.filter { $0.value == localTrackId }.first?.key
  }
  
  @objc static override func requiresMainQueueSetup() -> Bool {
      return false
  }
  
  private func getSimulcastConfigFrom(options: NSDictionary, reject: RCTPromiseRejectBlock) -> SimulcastConfig? {
    let simulcastConfig = options["simulcastConfig"] as? NSDictionary ?? [:]
    var activeEncodings: [TrackEncoding] = []
    if((simulcastConfig["activeEncodings"] as? [String] ?? []).contains(where: {
      e in validateEncoding(encoding: e, reject) == nil
    })) {
      return nil
    }
    (simulcastConfig["activeEncodings"] as? [String] ?? []).forEach {
      e in activeEncodings.append(e.toTrackEncoding()!)
    }
    return SimulcastConfig(
      enabled: simulcastConfig["enabled"] as? Bool ?? false,
      activeEncodings: activeEncodings
    )
  }
  
  private func getBandwidthLimitFrom(options: NSDictionary) -> TrackBandwidthLimit {
    let maxBandwidth = options["maxBandwidth"]
    if(maxBandwidth == nil) {
      return .BandwidthLimit(0)
    } else if(maxBandwidth as? NSDictionary != nil) {
      return .SimulcastBandwidthLimit(maxBandwidth as! SimulcastBandwidthLimit)
    } else {
      return .BandwidthLimit(maxBandwidth as! Int)
    }
  }
  
  private func ensureConnected(_ reject: RCTPromiseRejectBlock) -> Bool {
    if(room == nil) {
      reject("E_NOT_CONNECTED", "Client not connected to server yet. Make sure to call connect() first!", nil)
      return false
    }
    return true
  }
  
  private func ensureVideoTrack(_ reject: RCTPromiseRejectBlock) -> Bool {
    if(room == nil) {
      reject("E_NO_LOCAL_VIDEO_TRACK", "No local video track. Make sure to call connect() first!", nil)
      return false
    }
    return true
  }
  
  private func ensureAudioTrack(_ reject: RCTPromiseRejectBlock) -> Bool {
    if(room == nil) {
      reject("E_NO_LOCAL_AUDIO_TRACK", "No local audio track. Make sure to call connect() first!", nil)
      return false
    }
    return true
  }
  
  private func ensureScreencastTrack(_ reject: RCTPromiseRejectBlock) -> Bool {
    if(room == nil) {
      reject("E_NO_LOCAL_SCREENCAST_TRACK", "No local screencast track. Make sure to toggle screencast on first!", nil)
      return false
    }
    return true
  }
  
  private func validateEncoding(encoding: String, _ reject: RCTPromiseRejectBlock) -> TrackEncoding? {
    let trackEncoding = encoding.toTrackEncoding()
    if(trackEncoding == nil) {
      reject("E_INVALID_ENCODING", "Invalid track encoding specified: \(encoding)", nil)
      return nil
    }
    return trackEncoding
  }
  
    @objc(connect:withRoomName:withConnectionOptions:withResolver:withRejecter:)
    func connect(url: String, roomName: String, connectionOptions: NSDictionary, resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock) -> Void {
    connectResolve = resolve
    connectReject = reject
    self.videoQuality = connectionOptions["quality"] as? String ?? ""
    self.flipVideo = connectionOptions["flipVideo"] as? Bool ?? true
    self.localUserMetadata = (connectionOptions["userMetadata"] as? NSDictionary)?.toMetadata() ?? Metadata()
    self.videoTrackMetadata = (connectionOptions["videoTrackMetadata"] as? NSDictionary)?.toMetadata() ?? Metadata()
    self.audioTrackMetadata = (connectionOptions["audioTrackMetadata"] as? NSDictionary)?.toMetadata() ?? Metadata()
    self.isSpeakersphoneOn = connectionOptions["isSpeakerphoneOn"] as? Bool ?? true
        
    let socketConnectionParams = (connectionOptions["connectionParams"] as? NSDictionary)?.toMetadata() ?? Metadata()
    let socketChannelParams = (connectionOptions["socketChannelParams"] as? NSDictionary)?.toMetadata() ?? Metadata()
      
    guard let videoSimulcastConfig = getSimulcastConfigFrom(options: connectionOptions, reject: reject) else {
      return
    }
    self.videoSimulcastConfig = videoSimulcastConfig
    self.videoBandwidthLimit = getBandwidthLimitFrom(options: connectionOptions)
        
    room = MembraneRTC.connect(
      with: MembraneRTC.ConnectOptions(
        transport: PhoenixTransport(url: url, topic: "room:\(roomName)", params: socketConnectionParams.toDict(), channelParams: socketChannelParams.toDict()),
        config: self.localUserMetadata
      ),
      delegate: self
    )
  }
  
  @objc(join:withRejecter:)
  func join(resolve:@escaping RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureConnected(reject)) { return }
    joinResolve = resolve
    joinReject = reject
    room?.join()
  }
  
  @objc(disconnect:withRejecter:)
  func disconnect(resolve:RCTPromiseResolveBlock, reject:RCTPromiseRejectBlock) -> Void {
    room?.remove(delegate: self)
    room?.disconnect()
    room = nil
    MembraneRoom.sharedInstance.participants = [:]
    resolve(nil)
  }
  
  @objc(toggleScreencast:withResolver:withRejecter:)
  func toggleScreencast(screencastOptions: NSDictionary, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    let screencastExtensionBundleId = Bundle.main.infoDictionary?["ScreencastExtensionBundleId"] as? String
    if(screencastExtensionBundleId == nil) {
      reject("E_NO_BUNDLE_ID_SET", "No screencast extension bundle id set. Please set ScreencastExtensionBundleId in Info.plist", nil)
      return
    }
    let appGroupName = Bundle.main.infoDictionary?["AppGroupName"] as? String
    if(appGroupName == nil) {
      reject("E_NO_APP_GROUP_SET", "No app group name set. Please set AppGroupName in Info.plist", nil)
      return
    }
    guard let screencastExtensionBundleId = screencastExtensionBundleId,
          let appGroupName = appGroupName else {
            return
          }
    
    // if screensharing is enabled it must be closed by the Broadcast Extension, not by our application
    // the only thing we can do is to display stop recording button, which we already do
    guard isScreensharingEnabled == false else {
      DispatchQueue.main.async {
        RPSystemBroadcastPickerView.show(for: screencastExtensionBundleId)
      }
      resolve(nil)
      return
    }
    if(!ensureConnected(reject)) { return }
    guard let room = room else {
        return
    }
    
    let preset: VideoParameters = {
      switch(screencastOptions["quality"] as? String) {
        case "VGA":
          return VideoParameters.presetScreenShareVGA
        case "HD5":
          return VideoParameters.presetScreenShareHD5
        case "HD15":
          return VideoParameters.presetScreenShareHD15
        case "FHD15":
          return VideoParameters.presetScreenShareFHD15
        case "FHD30":
          return VideoParameters.presetScreenShareFHD30
        default:
          return VideoParameters.presetScreenShareHD15
      }
    }()
    guard let screenshareSimulcastConfig = getSimulcastConfigFrom(options: screencastOptions, reject: reject) else {
      return
    }
    self.screenshareSimulcastConfig = screenshareSimulcastConfig
    screenshareBandwidthLimit = getBandwidthLimitFrom(options: screencastOptions)
    let videoParameters = VideoParameters(
      dimensions: preset.dimensions.flip(),
      maxBandwidth: screenshareBandwidthLimit,
      maxFps: preset.maxFps,
      simulcastConfig: screenshareSimulcastConfig
    )
    
    let screencastMetadata = (screencastOptions["screencastMetadata"] as? NSDictionary)?.toMetadata() ?? Metadata()
    
      self.localScreencastTrack = room.createScreencastTrack(appGroup: appGroupName, videoParameters: videoParameters, metadata: screencastMetadata, onStart: { [weak self] screencastTrack in
      guard let self = self else {
        DispatchQueue.main.async {
          RPSystemBroadcastPickerView.show(for: screencastExtensionBundleId)
        }
        return
      }
      
      guard let localParticipantId = self.localParticipantId, let screencastTrackId = self.localScreencastTrack?.trackId() else {
         return
      }
        
      MembraneRoom.sharedInstance.participants[localParticipantId]?.videoTracks[screencastTrackId] = screencastTrack
      MembraneRoom.sharedInstance.participants[localParticipantId]?.tracksMetadata[screencastTrackId] = screencastMetadata
        
      self.isScreensharingEnabled = true
      self.emitEvent(name: "IsScreencastOn", data: true)
      self.emitParticipants()
    }, onStop: { [weak self] in
      guard let self = self else {
        return
      }
      
      guard let localParticipantId = self.localParticipantId, let screencastTrackId = self.localScreencastTrack?.trackId() else {
        return
      }
      
      let localParticipant = MembraneRoom.sharedInstance.participants[localParticipantId]
      MembraneRoom.sharedInstance.participants[localParticipantId] = localParticipant?.removeTrack(trackId: screencastTrackId)
      room.removeTrack(trackId: screencastTrackId)
      self.localScreencastTrack = nil
      
      self.isScreensharingEnabled = false
      self.emitEvent(name: "IsScreencastOn", data: false)
      self.emitParticipants()
    })
    DispatchQueue.main.async {
      RPSystemBroadcastPickerView.show(for: screencastExtensionBundleId)
    }
    resolve(nil)
  }
  
  func getParticipantsForRN() -> Dictionary<String, Array<Dictionary<String, Any>>> {
    return ["participants": MembraneRoom.sharedInstance.participants.values.sorted(by: {$0.order < $1.order}).map {
      (p) -> Dictionary in
      var participantType = ""
      if (p.id == localParticipantId) {
        participantType = "Local"
      } else {
        participantType = "Remote"
      }
      
      let videoTracks = p.videoTracks.keys.map { trackId in [
        "id": trackId,
        "type": "Video",
        "metadata": p.tracksMetadata[trackId]?.toDict() ?? [:],
        "encoding": tracksContexts[trackId]?.encoding?.description as Any,
        "encodingReason": tracksContexts[trackId]?.encodingReason?.rawValue as Any,
      ]}
      
      let audioTracks = p.audioTracks.keys.map { trackId in [
        "id": trackId,
        "type": "Audio",
        "metadata": p.tracksMetadata[trackId]?.toDict() ?? [:],
        "vadStatus": tracksContexts[trackId]?.vadStatus.rawValue as Any,
      ]}
        
      return [
        "id": p.id,
        "metadata": p.metadata.toDict(),
        "tracks": videoTracks + audioTracks,
        "type": participantType
      ]
    }]
  }
  
  func getSimulcastConfigAsRNMap(simulcastConfig: SimulcastConfig) -> [String: Any] {
    return [
      "enabled": simulcastConfig.enabled,
      "activeEncodings": simulcastConfig.activeEncodings.map { e in e.description },
    ]
  }
  
  @objc(getParticipants:withRejecter:)
  func getParticipants(resolve:RCTPromiseResolveBlock, reject:RCTPromiseRejectBlock) -> Void {
    resolve(getParticipantsForRN())
  }
  
  @objc(toggleCamera:withRejecter:)
  func toggleCamera(resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureVideoTrack(reject)) { return }
    isCameraEnabled = !isCameraEnabled
    localVideoTrack?.setEnabled(isCameraEnabled)
    resolve(isCameraEnabled)
  }
  
  @objc(isCameraOn:withRejecter:)
  func isCameraOn(resolve:RCTPromiseResolveBlock, reject:RCTPromiseRejectBlock) -> Void {
    resolve(isCameraEnabled)
  }
  
  @objc(toggleMicrophone:withRejecter:)
  func toggleMicrophone(resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureAudioTrack(reject)) { return }
    isMicEnabled = !isMicEnabled
    localAudioTrack?.setEnabled(isMicEnabled)
    resolve(isMicEnabled)
  }
  
  @objc(isMicrophoneOn:withRejecter:)
  func isMicrophoneOn(resolve:RCTPromiseResolveBlock, reject:RCTPromiseRejectBlock) -> Void {
    resolve(isMicEnabled)
  }
  
  @objc(flipCamera:withRejecter:)
  func flipCamera(resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureVideoTrack(reject)) { return }
    guard let cameraTrack = localVideoTrack as? LocalCameraVideoTrack else {
        return
    }

    cameraTrack.switchCamera()
    isFrontCamera = !isFrontCamera
    resolve(nil)
  }
    
    @objc(updatePeerMetadata:withResolver:withRejecter:)
  func updatePeerMetadata(metadata:NSDictionary, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
        if(!ensureConnected(reject)) { return }
        room?.updatePeerMetadata(peerMetadata: metadata.toMetadata())
        resolve(nil)
    }
  
  func updateTrackMetadata(trackId: String, metadata:NSDictionary) {
    guard let room = room, let peerId = localParticipantId else {
      return
    }
    
    room.updateTrackMetadata(trackId: trackId, trackMetadata: metadata.toMetadata())
    MembraneRoom.sharedInstance.participants[peerId]?.tracksMetadata[trackId] = metadata.toMetadata()
    emitParticipants()
  }
    
    @objc(updateVideoTrackMetadata:withResolver:withRejecter:)
    func updateVideoTrackMetadata(metadata:NSDictionary, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
        if(!ensureVideoTrack(reject)) { return }
        guard let trackId = localVideoTrack?.trackId() else {
            return
        }

        updateTrackMetadata(trackId: trackId, metadata: metadata)
        resolve(nil)
    }
    
    @objc(updateAudioTrackMetadata:withResolver:withRejecter:)
    func updateAudioTrackMetadata(metadata:NSDictionary, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
      if(!ensureAudioTrack(reject)) { return }
        guard let trackId = localAudioTrack?.trackId() else {
            return
        }

      updateTrackMetadata(trackId: trackId, metadata: metadata)
        resolve(nil)
    }
    
    @objc(updateScreencastTrackMetadata:withResolver:withRejecter:)
    func updateScreencastTrackMetadata(metadata:NSDictionary, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
      if(!ensureScreencastTrack(reject)) { return }
        guard let trackId = localScreencastTrack?.trackId() else {
            return
        }

      updateTrackMetadata(trackId: trackId, metadata: metadata)
        resolve(nil)
    }
  
  private func toggleTrackEncoding(encoding: TrackEncoding, trackId: String, simulcastConfig: SimulcastConfig) -> SimulcastConfig? {
    guard let room = room else {
      return nil
    }
    if(simulcastConfig.activeEncodings.contains(encoding)) {
      room.disableTrackEncoding(trackId: trackId, encoding: encoding)
      return SimulcastConfig(
        enabled: true,
        activeEncodings: simulcastConfig.activeEncodings.filter { e in e != encoding}
      )
    } else {
      room.enableTrackEncoding(trackId: trackId, encoding: encoding)
      return SimulcastConfig(
        enabled: true,
        activeEncodings: simulcastConfig.activeEncodings + [encoding]
      )
    }
  }
  
  @objc(toggleScreencastTrackEncoding:withResolver:withRejecter:)
  func toggleScreencastTrackEncoding(encoding: NSString, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureScreencastTrack(reject)) { return }
    guard
      let trackId = localScreencastTrack?.trackId(),
      let trackEncoding = validateEncoding(encoding: encoding as String, reject),
      let simulcastConfig = toggleTrackEncoding(encoding: trackEncoding, trackId: trackId, simulcastConfig: screenshareSimulcastConfig) else {
      return
    }
    self.screenshareSimulcastConfig = simulcastConfig
    resolve(getSimulcastConfigAsRNMap(simulcastConfig: simulcastConfig))
  }
  
  @objc(setScreencastTrackBandwidth:withResolver:withRejecter:)
  func setScreencastTrackBandwidth(bandwidth: NSNumber, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureScreencastTrack(reject)) { return }
    guard let room = room, let trackId = localScreencastTrack?.trackId() else {
      return
    }
    room.setTrackBandwidth(trackId: trackId, bandwidth: BandwidthLimit(truncating: bandwidth))
    resolve(nil)
  }
  
  @objc(setScreencastTrackEncodingBandwidth:withBandwidth:withResolver:withRejecter:)
  func setScreencastTrackEncodingBandwidth(encoding: NSString, bandwidth: NSNumber, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureScreencastTrack(reject)) { return }
    guard let room = room, let trackId = localScreencastTrack?.trackId(), let trackEncoding = validateEncoding(encoding: encoding as String, reject) else {
      return
    }
    room.setEncodingBandwidth(trackId: trackId, encoding: trackEncoding.description, bandwidth: BandwidthLimit(truncating: bandwidth))
    resolve(nil)
  }
  
  @objc(setTargetTrackEncoding:withEncoding:withResolver:withRejecter:)
  func setTargetTrackEncoding(trackId: NSString, encoding: NSString, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureConnected(reject)) { return }
    guard
      let room = room,
      let videoTrack = MembraneRoom.sharedInstance.getVideoTrackById(trackId: trackId as String),
      let trackId = (videoTrack as? RemoteVideoTrack)?.track.trackId ?? (videoTrack as? LocalVideoTrack)?.trackId(),
      let globalTrackId = getGlobalTrackId(localTrackId: trackId as String)
    else {
      reject("E_INVALID_TRACK_ID", "Remote track with id=\(trackId) not found", nil)
      return
    }
    guard let trackEncoding = validateEncoding(encoding: encoding as String, reject) else {
      return
    }
    room.setTargetTrackEncoding(trackId: globalTrackId, encoding: trackEncoding)
    resolve(nil)
  }
  
  @objc(toggleVideoTrackEncoding:withResolver:withRejecter:)
  func toggleVideoTrackEncoding(encoding: NSString, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureVideoTrack(reject)) { return }
    guard
      let trackId = localVideoTrack?.trackId(),
      let trackEncoding = validateEncoding(encoding: encoding as String, reject),
      let simulcastConfig = toggleTrackEncoding(encoding: trackEncoding, trackId: trackId, simulcastConfig: videoSimulcastConfig) else {
      return
    }
    self.videoSimulcastConfig = simulcastConfig
    resolve(getSimulcastConfigAsRNMap(simulcastConfig: simulcastConfig))
  }
  
  @objc(setVideoTrackEncodingBandwidth:withBandwidth:withResolver:withRejecter:)
  func setVideoTrackEncodingBandwidth(encoding: NSString, bandwidth: NSNumber, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) -> Void {
    if(!ensureVideoTrack(reject)) { return }
    guard let room = room, let trackId = localVideoTrack?.trackId() else {
      return
    }
    room.setEncodingBandwidth(trackId: trackId, encoding: encoding as String, bandwidth: BandwidthLimit(truncating: bandwidth))
    resolve(nil)
  }
  
  @objc(setVideoTrackBandwidth:withResolver:withRejecter:)
  func setVideoTrackBandwidth(bandwidth: NSNumber, resolve:RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) {
    if(!ensureVideoTrack(reject)) { return }
    guard let room = room, let trackId = localVideoTrack?.trackId() else {
      return
    }
    room.setTrackBandwidth(trackId: trackId, bandwidth: BandwidthLimit(truncating: bandwidth))
  }
  
  @objc(toggleSpeakerphone:withRejecter:)
  func toggleSpeakerphone(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
    if(isSpeakersphoneOn) {
      localAudioTrack?.setVoiceChatMode()
    } else {
      localAudioTrack?.setVideoChatMode()
    }
    isSpeakersphoneOn = !isSpeakersphoneOn
    resolve(nil)
  }
  
  override func supportedEvents() -> [String]! {
    return [
      "ParticipantsUpdate",
      "MembraneError",
      "IsMicrophoneOn",
      "IsCameraOn",
      "IsScreencastOn",
      "BandwidthEstimation",
    ]
  }
  
  func emitEvent(name: String, data: Any?) -> Void {
    sendEvent(withName: name, body: data)
  }
  
  func emitParticipants() -> Void {
    emitEvent(name: "ParticipantsUpdate", data: getParticipantsForRN())
  }
  
  func onConnected() {
    guard let room = room else {
      return
    }
    
    let preset: VideoParameters = {
      switch videoQuality {
      case "QVGA169":
        return VideoParameters.presetQVGA169
      case "VGA169":
        return VideoParameters.presetVGA169
      case "VQHD169":
        return VideoParameters.presetQHD169
      case "HD169":
        return VideoParameters.presetHD169
      case "FHD169":
        return VideoParameters.presetFHD169
      case "QVGA43":
        return VideoParameters.presetQVGA43
      case "VGA43":
        return VideoParameters.presetVGA43
      case "VQHD43":
        return VideoParameters.presetQHD43
      case "HD43":
        return VideoParameters.presetHD43
      case "FHD43":
        return VideoParameters.presetFHD43
      default:
        return VideoParameters.presetVGA169
      }
    }()
    let videoParameters = VideoParameters(
      dimensions: flipVideo ? preset.dimensions.flip() : preset.dimensions,
      maxBandwidth: self.videoBandwidthLimit,
      simulcastConfig: self.videoSimulcastConfig
    )
    
    let localParticipantId = UUID().uuidString
    self.localParticipantId = localParticipantId
    
    localVideoTrack = room.createVideoTrack(videoParameters: videoParameters, metadata: videoTrackMetadata)
    localAudioTrack = room.createAudioTrack(metadata: audioTrackMetadata)
    
    if(isSpeakersphoneOn) {
      localAudioTrack?.setVideoChatMode()
    } else {
      localAudioTrack?.setVoiceChatMode()
    }
    
    var localParticipant = Participant(
      id: localParticipantId,
      metadata: localUserMetadata)
    
    if let localVideoTrack = localVideoTrack {
      localParticipant.videoTracks = [localVideoTrack.trackId(): localVideoTrack]
      localParticipant.tracksMetadata[localVideoTrack.trackId()] = videoTrackMetadata
    }
    
    if let localAudioTrack = localAudioTrack {
      localParticipant.audioTracks = [localAudioTrack.trackId(): localAudioTrack]
      localParticipant.tracksMetadata[localAudioTrack.trackId()] = audioTrackMetadata
    }
    
    MembraneRoom.sharedInstance.participants[localParticipantId] = localParticipant
    
    if let connectResolve = connectResolve {
      connectResolve(nil)
    }
  }
  
  func onJoinSuccess(peerID: String, peersInRoom: [Peer]) {
    peersInRoom.forEach { peer in
      MembraneRoom.sharedInstance.participants[peer.id] = Participant(id: peer.id, metadata: peer.metadata)
    }
    
    emitParticipants()
    if let joinResolve = joinResolve {
      joinResolve(nil)
    }
    joinResolve = nil
    joinReject = nil
  }
  
  func onJoinError(metadata: Any) {
    if let joinReject = joinReject {
      joinReject("E_MEMBRANE_JOIN", "Failed to join room: \(metadata)", nil)
    }
    joinResolve = nil
    joinReject = nil
  }
  
  func updateOrAddTrack(ctx: TrackContext) {
    guard var participant = MembraneRoom.sharedInstance.participants[ctx.peer.id] else {
      return
    }
    if let audioTrack = ctx.track as? RemoteAudioTrack {
      let localTrackId = (ctx.track as? RemoteAudioTrack)?.track.trackId
      globalToLocalTrackId[ctx.trackId] = localTrackId
      participant.audioTracks[audioTrack.track.trackId] = audioTrack
      participant.tracksMetadata[audioTrack.track.trackId] = ctx.metadata
      if let localTrackId = localTrackId,
         tracksContexts[localTrackId] == nil {
        tracksContexts[localTrackId] = ctx
        ctx.setOnVoiceActivityChangedListener { ctx in
          self.emitParticipants()
        }
      }
    }
    
    if let videoTrack = ctx.track as? RemoteVideoTrack {
      let localTrackId = (ctx.track as? RemoteVideoTrack)?.track.trackId
      globalToLocalTrackId[ctx.trackId] = localTrackId
      participant.videoTracks[videoTrack.track.trackId] = videoTrack
      participant.tracksMetadata[videoTrack.track.trackId] = ctx.metadata
      if let localTrackId = localTrackId,
         tracksContexts[localTrackId] == nil {
        tracksContexts[localTrackId] = ctx
        ctx.setOnEncodingChangedListener { ctx in
          self.emitParticipants()
        }
      }
    }
    MembraneRoom.sharedInstance.participants[ctx.peer.id] = participant
    emitParticipants()
  }
  
  func onTrackReady(ctx: TrackContext) {
    updateOrAddTrack(ctx: ctx)
  }
  
  func onTrackAdded(ctx: TrackContext) {
    
  }
  
  func onTrackRemoved(ctx: TrackContext) {
    guard var participant = MembraneRoom.sharedInstance.participants[ctx.peer.id] else {
      return
    }
    if let audioTrack = ctx.track as? RemoteAudioTrack {
      participant = participant.removeTrack(trackId: audioTrack.track.trackId)
    }
    if let videoTrack = ctx.track as? RemoteVideoTrack {
      participant = participant.removeTrack(trackId: videoTrack.track.trackId)
    }
    globalToLocalTrackId.removeValue(forKey: ctx.trackId)
    MembraneRoom.sharedInstance.participants[ctx.peer.id] = participant
    emitParticipants()
  }
  
  func onTrackUpdated(ctx: TrackContext) {
    updateOrAddTrack(ctx: ctx)
  }
  
  func onPeerJoined(peer: Peer) {
    MembraneRoom.sharedInstance.participants[peer.id] = Participant(id: peer.id, metadata: peer.metadata)
    emitParticipants()
  }
  
  func onPeerLeft(peer: Peer) {
    MembraneRoom.sharedInstance.participants.removeValue(forKey: peer.id)
    emitParticipants()
  }
  
  func onPeerUpdated(peer: Peer) {
    
  }
  
  func onError(_ error: MembraneRTCError) {
    if let joinReject = joinReject {
      joinReject("E_MEMBRANE_JOIN", "Failed to join room: \(error)", nil)
    }
    if let connectReject = connectReject {
      connectReject("E_MEMBRANE_CONNECT", "Failed to connect: \(error)", nil)
    }
    joinReject = nil
    joinResolve = nil
    connectReject = nil
    connectResolve = nil
    var errorMessage: String? = nil
    switch error {
    case let .rtc(message):
        errorMessage = message

    case let .transport(message):
        errorMessage = message

    case let .unknown(message):
        errorMessage = message
    }
    emitEvent(name: "MembraneError", data: errorMessage)
  }
  
  func onBandwidthEstimationChanged(estimation: Int) {
    emitEvent(name: "BandwidthEstimation", data: estimation)
  }
  
}
