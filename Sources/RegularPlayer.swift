//
//  RegularPlayer.swift
//  Pods
//
//  Created by King, Gavin on 3/7/17.
//
//

import Foundation
import AVFoundation
import AVKit

extension AVMediaSelectionOption: TextTrackMetadata {
    public var isSDHTrack: Bool {
        return self.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) && self.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
    }
}

/// A RegularPlayer is used to play regular videos.
@objc open class RegularPlayer: NSObject, Player, ProvidesView {

    public struct Constants {
        public static let TimeUpdateInterval: TimeInterval = 0.1
    }

    // MARK: - Private Properties

    fileprivate var player = AVPlayer()

    private var regularPlayerView: RegularPlayerView

    private var playerLayer: AVPlayerLayer {
        return self.regularPlayerView.playerLayer
    }

    private var seekTolerance: CMTime?

    private var seekTarget: CMTime = CMTime.invalid
    public var isSeekInProgress: Bool = false

    private var lastStateChange: Date = Date()
    private var stateChanges: [String: Int] = [:]

    // MARK: - Public API

    /// Sets an AVAsset on the player.
    ///
    /// - Parameter asset: The AVAsset
    @objc open func set(_ asset: AVAsset) {
        // Create playback options for faster loading
        let options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]

        // Create a specialized playerItem with custom options
        let playerItem = AVPlayerItem(asset: asset)

        // Optimize for high-speed playback by setting appropriate values
        if #available(iOS 10.0, tvOS 10.0, macOS 10.12, *) {
            playerItem.preferredForwardBufferDuration = 10.0 // Start with a good buffer

            // This helps maintain higher playback rates by giving a quality/speed tradeoff hint
            playerItem.preferredPeakBitRate = 0 // 0 means no limit
        }

        self.set(playerItem: playerItem)
    }

    @objc open func set(playerItem: AVPlayerItem) {
        // Prepare the old item for removal
        if let currentItem = self.player.currentItem {
            self.removePlayerItemObservers(fromPlayerItem: currentItem)
        }

        // Replace it with the new item
        self.addPlayerItemObservers(toPlayerItem: playerItem)
        self.player.replaceCurrentItem(with: playerItem)
    }

    // MARK: - ProvidesView

    private class RegularPlayerView: PlayerView {
        var playerLayer: AVPlayerLayer {
            return self.layer as! AVPlayerLayer
        }

#if canImport(UIKit)
        override class var layerClass: AnyClass {
            return AVPlayerLayer.self
        }
#elseif canImport(AppKit)
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            self.layer = AVPlayerLayer()
        }

        required init?(coder decoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
#endif

        func configureForPlayer(player: AVPlayer) {
            (self.layer as! AVPlayerLayer).player = player
        }
    }

    open var view: UIView {
        return self.regularPlayerView
    }

    // MARK: - Player

    weak public var delegate: PlayerDelegate?

    public private(set) var state: PlayerState = .ready {
        didSet {
            // Track performance metrics
            self.trackPerformance(oldState: oldValue, newState: state)
            self.delegate?.playerDidUpdateState(player: self, previousState: oldValue)
        }
    }

    public var duration: TimeInterval {
        return self.player.currentItem?.duration.timeInterval ?? 0
    }

    public private(set) var time: TimeInterval = 0 {
        didSet {
            self.delegate?.playerDidUpdateTime(player: self)
        }
    }

    public private(set) var bufferedTime: TimeInterval = 0 {
        didSet {
            self.delegate?.playerDidUpdateBufferedTime(player: self)
        }
    }

    public var isMuted: Bool = true {
        didSet {
            player.isMuted = isMuted
        }
    }

    public var playing: Bool {
        return self.player.rate > 0
    }

    public var ended: Bool {
        return self.time >= self.duration
    }

    public var error: NSError? {
        return self.player.errorForPlayerOrItem
    }

    open func seek(to time: TimeInterval) {
        let cmTime = CMTimeMakeWithSeconds(time, preferredTimescale: Int32(NSEC_PER_SEC))
        self.smoothSeek(to: cmTime)
    }

    open func play() {
        self.player.play()
    }

    open func setRate(_ rate: Float) {
        self.player.rate = rate

        if let currentItem = self.player.currentItem {
            // Progressive buffer scaling based on rate
            if #available(iOS 10.0, tvOS 10.0, macOS 10.12, *) {
                // Scale buffer with rate - higher rates need more buffer
                let bufferDuration = min(30.0, rate * 5.0) // Cap at reasonable maximum
                currentItem.preferredForwardBufferDuration = TimeInterval(bufferDuration)

                // Lower values make playback start faster but might cause more rebuffering
                if rate > 2.0 {
                    currentItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                    self.player.automaticallyWaitsToMinimizeStalling = false
                } else {
                    self.player.automaticallyWaitsToMinimizeStalling = true
                }
            }
        }

        // Apply network and memory optimizations for high rates
        if rate > 2.0 {
            optimizeForHighRatePlayback(true)
        } else {
            optimizeForHighRatePlayback(false)
        }
    }

    open func pause() {
        self.player.pause()
    }

    // MARK: - Lifecycle

    override public convenience init() {
        self.init(seekTolerance: nil)
    }

    public init(seekTolerance: TimeInterval?) {
        self.regularPlayerView = RegularPlayerView(frame: .zero)
        self.seekTolerance = seekTolerance.map {
            CMTimeMakeWithSeconds($0, preferredTimescale: Int32(NSEC_PER_SEC))
        }

        super.init()

        self.addPlayerObservers()
        self.regularPlayerView.configureForPlayer(player: self.player)
        self.setupAirplay()
    }

    deinit {
        if let playerItem = self.player.currentItem {
            self.removePlayerItemObservers(fromPlayerItem: playerItem)
        }

        self.removePlayerObservers()
    }

    // MARK: - Setup

    @available(iOS 10.0, tvOS 10.0, macOS 10.12, *)
    public var automaticallyWaitsToMinimizeStalling: Bool {
        get {
            return self.player.automaticallyWaitsToMinimizeStalling
        }
        set {
            self.player.automaticallyWaitsToMinimizeStalling = newValue
        }
    }

    private func setupAirplay() {
#if os(iOS) || os(tvOS)
        self.player.usesExternalPlaybackWhileExternalScreenIsActive = true
#endif
    }

    // MARK: - Performance Optimization

    private func optimizeForHighRatePlayback(_ enabled: Bool) {
        if enabled {
            // Reduce concurrent operations that might compete with playback
            URLSession.shared.configuration.httpMaximumConnectionsPerHost = 6

            if #available(iOS 10.0, tvOS 10.0, macOS 10.12, *) {
                // Prioritize media loading on the network
                URLSession.shared.configuration.networkServiceType = .video
            }
        }
    }

    private func trackPerformance(oldState: PlayerState, newState: PlayerState) {
        // Track frequency of state changes to detect flapping
        let now = Date()
        let timeInState = now.timeIntervalSince(self.lastStateChange)
        let key = "\(oldState)->\(newState)"

        stateChanges[key] = (stateChanges[key] ?? 0) + 1

        // Log if we're seeing rapid state transitions (potential flapping)
        if timeInState < 0.5 {
            print("Warning: Rapid state transition: \(key) after \(timeInState)s")
            if stateChanges[key] ?? 0 > 5 {
                print("Performance Warning: Frequent state changes detected: \(stateChanges)")
            }
        }

        self.lastStateChange = now
    }

    // MARK: - Smooth Seeking

    // Note: Smooth seeking follows the guide from Apple Technical Q&A: https://developer.apple.com/library/archive/qa/qa1820/_index.html
    // Update the seek target and begin seeking if there is no seek currently in progress.
    private func smoothSeek(to cmTime: CMTime) {
        self.seekTarget = cmTime

        guard self.isSeekInProgress == false else { return }
        self.seekToTarget()
    }

    // Unconditionally seek to the current seek target.
    private func seekToTarget() {
        self.isSeekInProgress = true

        guard self.player.status != .unknown else { return }

        assert(CMTIME_IS_VALID(self.seekTarget))
        let inProgressSeekTarget = self.seekTarget

        // Special handling for high rate playback - seek ahead of target position
        var seekAdjustment: CMTime = CMTime.zero
        if self.player.rate > 2.0 {
            // When playing fast, seek further ahead to give more buffer time
            let adjustment = Double(self.player.rate) * 0.5
            seekAdjustment = CMTimeMakeWithSeconds(adjustment, preferredTimescale: Int32(NSEC_PER_SEC))
        }

        // Adjusted target with additional buffer for high rates
        let adjustedTarget = CMTimeAdd(inProgressSeekTarget, seekAdjustment)

        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self = self else { return }

            self.time = CMTimeGetSeconds(inProgressSeekTarget)
            if CMTimeCompare(inProgressSeekTarget, self.seekTarget) == 0 {
                self.isSeekInProgress = false
            } else {
                self.seekToTarget()
            }
        }

        if let tolerance = self.seekTolerance {
            self.player.seek(
                to: adjustedTarget,
                toleranceBefore: tolerance,
                toleranceAfter: tolerance,
                completionHandler: completion
            )
        } else {
            self.player.seek(to: adjustedTarget, completionHandler: completion)
        }
    }

    // MARK: - Observers

    private struct KeyPath {
        struct Player {
            static let Rate = "rate"
        }

        struct PlayerItem {
            static let Status = "status"
            static let PlaybackLikelyToKeepUp = "playbackLikelyToKeepUp"
            static let LoadedTimeRanges = "loadedTimeRanges"
        }
    }

    private var playerTimeObserver: Any?

    private func addPlayerItemObservers(toPlayerItem playerItem: AVPlayerItem) {
        playerItem.addObserver(self, forKeyPath: KeyPath.PlayerItem.Status, options: [.initial, .new], context: nil)
        playerItem.addObserver(self, forKeyPath: KeyPath.PlayerItem.PlaybackLikelyToKeepUp, options: [.initial, .new], context: nil)
        playerItem.addObserver(self, forKeyPath: KeyPath.PlayerItem.LoadedTimeRanges, options: [.initial, .new], context: nil)
    }

    private func removePlayerItemObservers(fromPlayerItem playerItem: AVPlayerItem) {
        playerItem.removeObserver(self, forKeyPath: KeyPath.PlayerItem.Status, context: nil)
        playerItem.removeObserver(self, forKeyPath: KeyPath.PlayerItem.PlaybackLikelyToKeepUp, context: nil)
        playerItem.removeObserver(self, forKeyPath: KeyPath.PlayerItem.LoadedTimeRanges, context: nil)
    }

    private func addPlayerObservers() {
        self.player.addObserver(self, forKeyPath: KeyPath.Player.Rate, options: [.initial, .new], context: nil)

        let interval = CMTimeMakeWithSeconds(Constants.TimeUpdateInterval, preferredTimescale: Int32(NSEC_PER_SEC))

        self.playerTimeObserver = self.player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main, using: { [weak self] (cmTime) in

            if let strongSelf = self, let time = cmTime.timeInterval {
                strongSelf.time = time
            }
        })
    }

    private func removePlayerObservers() {
        self.player.removeObserver(self, forKeyPath: KeyPath.Player.Rate, context: nil)

        if let playerTimeObserver = self.playerTimeObserver {
            self.player.removeTimeObserver(playerTimeObserver)

            self.playerTimeObserver = nil
        }
    }

    // MARK: Observation

    override open func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        // Player Item Observers

        if keyPath == KeyPath.PlayerItem.Status {
            if let statusInt = change?[.newKey] as? Int, let status = AVPlayerItem.Status(rawValue: statusInt) {
                self.playerItemStatusDidChange(status: status)
            }
        }
        else if keyPath == KeyPath.PlayerItem.PlaybackLikelyToKeepUp {
            if let playbackLikelyToKeepUp = change?[.newKey] as? Bool {
                self.playerItemPlaybackLikelyToKeepUpDidChange(playbackLikelyToKeepUp: playbackLikelyToKeepUp)
            }
        }
        else if keyPath == KeyPath.PlayerItem.LoadedTimeRanges {
            if let loadedTimeRanges = change?[.newKey] as? [NSValue] {
                self.playerItemLoadedTimeRangesDidChange(loadedTimeRanges: loadedTimeRanges)
            }
        }

        // Player Observers

        else if keyPath == KeyPath.Player.Rate {
            if let rate = change?[.newKey] as? Float {
                self.playerRateDidChange(rate: rate)
            }
        }

        // Fall Through Observers

        else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    // MARK: Observation Helpers

    private func playerItemStatusDidChange(status: AVPlayerItem.Status) {
        switch status {
        case .unknown:

            self.state = .loading

        case .readyToPlay:

            self.state = .ready

            // If we tried to seek before the video was ready to play, resume seeking now.
            if self.isSeekInProgress {
                self.seekToTarget()
            }

        case .failed:

            self.state = .failed

        @unknown default:

            self.state = .failed
        }
    }

    private func playerRateDidChange(rate: Float) {
        self.delegate?.playerDidUpdatePlaying(player: self)
    }

    private func playerItemPlaybackLikelyToKeepUpDidChange(playbackLikelyToKeepUp: Bool) {
        let currentRate = self.player.rate
        let currentItem = self.player.currentItem

        // More sophisticated state determination based on multiple factors
        if currentRate > 2.0 {
            // For high rates, evaluate more buffer metrics
            if let currentItem = currentItem {
                let isBufferEmpty = currentItem.isPlaybackBufferEmpty
                let isBufferFull = currentItem.isPlaybackBufferFull

                if isBufferEmpty {
                    self.state = .loading
                } else if playbackLikelyToKeepUp || isBufferFull || self.bufferedTime > 5.0 {
                    // If we have good buffer or system reports likely to keep up
                    self.state = .ready
                } else {
                    // Implement a brief delay before showing loading state at high speeds
                    // This prevents flickering between states on minor buffer issues
                    let capturedItem = currentItem // Create a strong reference
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self,
                              self.player.rate > 2.0,
                              let currentItem = self.player.currentItem, // Safely get the current item
                              !(currentItem.isPlaybackLikelyToKeepUp),
                              !(currentItem.isPlaybackBufferFull) else {
                            return
                        }
                        self.state = .loading
                    }
                }
            } else {
                self.state = playbackLikelyToKeepUp ? .ready : .loading
            }
        } else {
            // Standard behavior for normal playback rates
            self.state = playbackLikelyToKeepUp ? .ready : .loading
        }
    }

    private func playerItemLoadedTimeRangesDidChange(loadedTimeRanges: [NSValue]) {
        guard let bufferedCMTime = loadedTimeRanges.first?.timeRangeValue.end, let bufferedTime = bufferedCMTime.timeInterval else {
            return
        }

        self.bufferedTime = bufferedTime
    }

    // MARK: - Capability Protocol Helpers

#if os(iOS)
    @available(iOS 9.0, *)
    fileprivate lazy var _pictureInPictureController: AVPictureInPictureController? = {
        AVPictureInPictureController(playerLayer: self.regularPlayerView.playerLayer)
    }()
#endif
}

// MARK: Capability Protocols

extension RegularPlayer: AirPlayCapable
{
    public var isAirPlayEnabled: Bool {
        get {
            return self.player.allowsExternalPlayback
        }
        set {
            return self.player.allowsExternalPlayback = newValue
        }
    }
}

#if os(iOS)
extension RegularPlayer: PictureInPictureCapable {
    @available(iOS 9.0, *)
    public var pictureInPictureController: AVPictureInPictureController? {
        return self._pictureInPictureController
    }
}
#endif

extension RegularPlayer: VolumeCapable
{
    public var volume: Float {
        get {
            return self.player.volume
        }
        set {
            self.player.volume = newValue
        }
    }
}

extension RegularPlayer: FillModeCapable {
    public var fillMode: FillMode {
        get {
            let gravity = (self.view.layer as! AVPlayerLayer).videoGravity

            return gravity == .resizeAspect ? .fit : .fill
        }
        set {
            let gravity: AVLayerVideoGravity

            switch newValue {
            case .fit:

                gravity = .resizeAspect

            case .fill:

                gravity = .resizeAspectFill
            case .scaleToFit:

                gravity = .resize
            }

            (self.view.layer as! AVPlayerLayer).videoGravity = gravity
        }
    }
}

extension RegularPlayer: TextTrackCapable {
    public var selectedTextTrack: TextTrackMetadata? {
        guard let group = self.player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            return nil
        }

        if #available(iOS 9.0, *) {
            return self.player.currentItem?.currentMediaSelection.selectedMediaOption(in: group)
        }
        else {
            return self.player.currentItem?.selectedMediaOption(in: group)
        }
    }

    public var availableTextTracks: [TextTrackMetadata] {
        guard let group = self.player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            return []
        }
        return group.options
    }

    public func fetchTextTracks(completion: @escaping ([TextTrackMetadata], TextTrackMetadata?) -> Void) {
        self.player.currentItem?.asset.loadValuesAsynchronously(forKeys: [#keyPath(AVAsset.availableMediaCharacteristicsWithMediaSelectionOptions)]) { [weak self] in
            guard let strongSelf = self, let group = strongSelf.player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
                completion([], nil)
                return
            }
            if #available(iOS 9.0, *) {
                completion(group.options, strongSelf.player.currentItem?.currentMediaSelection.selectedMediaOption(in: group))
            }
            else {
                completion(group.options, strongSelf.player.currentItem?.selectedMediaOption(in: group))
            }
        }
    }

    public func select(_ textTrack: TextTrackMetadata?) {
        guard let group = self.player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            return
        }

        guard let track = textTrack else {
            self.player.currentItem?.select(nil, in: group)
            return
        }

        let option = group.options.first(where: { option in
            track.matches(option)
        })
        self.player.currentItem?.select(option, in: group)
    }
}
