import MembraneRTC
import UIKit
import Combine

@objc(VideoRendererViewManager)
class VideoRendererViewManager: RCTViewManager {
  override func view() -> (VideoRendererView) {
    return VideoRendererView()
  }
  
  @objc static override func requiresMainQueueSetup() -> Bool {
      return false
  }
}

class VideoRendererView : UIView {
  var videoView: VideoView? = nil
  var cancellableParticipants: Cancellable? = nil
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    videoView = VideoView()
    videoView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(videoView!)
    cancellableParticipants = MembraneRoom.sharedInstance.$participants
      .sink { _ in
        self.updateVideoTrack()
      }
  }
  
  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  func updateVideoTrack() {
    DispatchQueue.main.async {
      let newTrack = MembraneRoom.sharedInstance.getVideoTrackById(trackId: self.trackId)
      if(newTrack != self.videoView?.track) {
        self.videoView?.track = newTrack
      }
    }
  }
  
  @objc var trackId: String = "" {
    didSet {
      updateVideoTrack()
    }
  }
  
  @objc var videoLayout: String = "FILL" {
    didSet {
      switch(videoLayout) {
      case "FIT":
        self.videoView?.layout = .fit
      case "FILL":
        self.videoView?.layout = .fill
      default:
        self.videoView?.layout = .fill
      }
      
    }
  }
}
