import AppKit
import AVFoundation
import SwiftUI

/// Video rett i feeden. «gifv» (GIF-er som Mastodon har gjort om til video) spilles av med en gang,
/// uten lyd og i loop. Vanlig video viser forhåndsbildet med play-knapp og starter ved klikk; klikk
/// igjen for pause. Spilleren lages først når videoen starter, og stoppes når den forsvinner fra
/// skjermen, når man bytter side eller når appen skjules.
struct InlineVideo: View {
    let m: MediaAttachment
    var crop: Bool
    /// Får bredde/høyde-forholdet til forhåndsbildet når det er lastet.
    var onPosterRatio: (Double) -> Void = { _ in }

    @ViewState private var started: Bool

    init(m: MediaAttachment, crop: Bool, onPosterRatio: @escaping (Double) -> Void = { _ in }) {
        self.m = m
        self.crop = crop
        self.onPosterRatio = onPosterRatio
        _started = ViewState(initialValue: m.type == "gifv")
    }

    var body: some View {
        let p = m.previewUrl ?? ""
        let videoExt = [".mp4", ".webm", ".mov", ".m4v"].contains { p.lowercased().hasSuffix($0) }
        let useFrame = p.isEmpty || p == m.url || videoExt
        ZStack {
            Color.black.opacity(0.001)
            RemoteImage(url: useFrame ? m.url : p, fill: crop, videoFrame: useFrame) { onPosterRatio($0.aspect) }
            if started {
                VideoSurface(url: m.url, loop: m.type == "gifv", crop: crop)
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { started = true }
                PlayIcon()
            }
        }
        .clipped()
        .help(m.description ?? "")
    }
}

@MainActor
@Observable
final class VideoController {
    var player: AVQueuePlayer?
    var playing = false
    var muted = false
    var progress = 0.0

    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var ended = false

    func start(_ url: String, loop: Bool) {
        guard player == nil, let u = URL(string: url) else { return }
        let item = AVPlayerItem(url: u)
        let p = AVQueuePlayer()
        if loop {
            looper = AVPlayerLooper(player: p, templateItem: item)
        } else {
            p.insert(item, after: nil)
        }
        p.isMuted = loop
        muted = loop
        statusObservation = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.playing = status != .paused }
        }
        if !loop {
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                    self.progress = min(max(t.seconds / d, 0), 1)
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended = true }
            }
        }
        player = p
        p.play()
    }

    func toggle() {
        guard let p = player else { return }
        if playing {
            p.pause()
        } else {
            if ended {
                ended = false
                p.seek(to: .zero)
            }
            p.play()
        }
    }

    func pause() { player?.pause() }

    func toggleMute() {
        muted.toggle()
        player?.isMuted = muted
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        statusObservation = nil
        looper = nil
        player = nil
        playing = false
    }
}

private struct VideoSurface: View {
    let url: String
    let loop: Bool
    let crop: Bool

    @ViewState private var ctl = VideoController()
    @Environment(\.screenActive) private var active

    var body: some View {
        ZStack {
            PlayerLayerView(player: ctl.player, crop: crop)
            // Klikkflate over videoen
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { ctl.toggle() }
            if !ctl.playing { PlayIcon() }
            if !loop {
                Button { ctl.toggleMute() } label: {
                    Image(systemName: ctl.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .help(L(ctl.muted ? "video_unmute" : "video_mute"))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: geo.size.width * ctl.progress, height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear { ctl.start(url, loop: loop) }
        .onDisappear { ctl.stop() }
        .onChange(of: active) { _, isActive in if !isActive { ctl.pause() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in ctl.pause() }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer?
    let crop: Bool

    func makeNSView(context: Context) -> PlayerNSView { PlayerNSView() }

    func updateNSView(_ v: PlayerNSView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = crop ? .resizeAspectFill : .resizeAspect
    }
}
