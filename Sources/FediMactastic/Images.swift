import AppKit
import AVFoundation
import ImageIO
import SwiftUI

/// Et dekodet bilde: én ramme for stillbilder, flere for animerte GIF-er, APNG og WebP.
final class LoadedImage {
    let frames: [CGImage]
    let durations: [Double]
    let size: CGSize

    init(frames: [CGImage], durations: [Double]) {
        self.frames = frames
        self.durations = durations
        size = CGSize(width: frames.first?.width ?? 1, height: frames.first?.height ?? 1)
    }

    var isAnimated: Bool { frames.count > 1 }
    var aspect: Double { size.height > 0 ? Double(size.width / size.height) : 1 }
    var totalDuration: Double { durations.reduce(0, +) }

    lazy var nsImage: NSImage = NSImage(cgImage: frames[0], size: size)

    static func decode(_ data: Data, maxPixel: Int) -> LoadedImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if count == 1 {
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return LoadedImage(frames: [img], durations: [0])
        }
        var frames: [CGImage] = []
        var durations: [Double] = []
        for i in 0..<min(count, 400) {
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(img)
            durations.append(frameDelay(src, i))
        }
        return frames.isEmpty ? nil : LoadedImage(frames: frames, durations: durations)
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictKey, unclamped, clamped) in dicts {
            if let d = props[dictKey] as? [CFString: Any] {
                let v = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0.1
                // Som nettlesere: svært korte forsinkelser vises som 0,1 s
                return v < 0.011 ? 0.1 : v
            }
        }
        return 0.1
    }
}

/// Henter og husker bilder (minne + disk via URLCache). Samme adresse hentes bare én gang om gangen.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, LoadedImage>()
    private var inflight: [String: Task<LoadedImage?, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 40
        return URLSession(configuration: config)
    }()

    init() {
        cache.countLimit = 400
    }

    private func key(_ url: String, _ maxPixel: Int) -> String { "\(maxPixel)|\(url)" }

    func cached(_ url: String?, maxPixel: Int = 1600) -> LoadedImage? {
        guard let url, !url.isEmpty else { return nil }
        return cache.object(forKey: key(url, maxPixel) as NSString)
    }

    func load(_ url: String?, maxPixel: Int = 1600) async -> LoadedImage? {
        guard let url, !url.isEmpty, let u = URL(string: url) else { return nil }
        let k = key(url, maxPixel)
        if let c = cache.object(forKey: k as NSString) { return c }
        if let t = inflight[k] { return await t.value }
        let session = self.session
        let task = Task.detached(priority: .userInitiated) { () -> LoadedImage? in
            guard let (data, resp) = try? await session.data(from: u) else { return nil }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return LoadedImage.decode(data, maxPixel: maxPixel)
        }
        inflight[k] = task
        let result = await task.value
        inflight[k] = nil
        if let result { cache.setObject(result, forKey: k as NSString) }
        return result
    }

    /// Et stillbilde fra en video (Pleroma lager ofte ingen egen forhåndsvisning for video).
    func videoFrame(_ url: String?) async -> LoadedImage? {
        guard let url, let u = URL(string: url) else { return nil }
        let k = "frame|" + url
        if let c = cache.object(forKey: k as NSString) { return c }
        if let t = inflight[k] { return await t.value }
        let task = Task.detached(priority: .utility) { () -> LoadedImage? in
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: u))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1600, height: 1600)
            guard let (img, _) = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
            return LoadedImage(frames: [img], durations: [0])
        }
        inflight[k] = task
        let result = await task.value
        inflight[k] = nil
        if let result { cache.setObject(result, forKey: k as NSString) }
        return result
    }
}

/// Tegner et (eventuelt animert) bilde i et lag, tilpasset (fit) eller beskåret (fill).
final class AnimatedImageNSView: NSView {
    private var current: LoadedImage?
    var fill = false {
        didSet { layer?.contentsGravity = fill ? .resizeAspectFill : .resizeAspect }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }

    // Trykk går videre til SwiftUI (bildet er bare til visning)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ image: LoadedImage?) {
        guard image !== current else { return }
        current = image
        guard let layer else { return }
        layer.removeAllAnimations()
        guard let image else {
            layer.contents = nil
            return
        }
        layer.contents = image.frames[0]
        if image.isAnimated {
            let total = max(image.totalDuration, 0.05)
            var times: [NSNumber] = []
            var t = 0.0
            for d in image.durations {
                times.append(NSNumber(value: t / total))
                t += d
            }
            let anim = CAKeyframeAnimation(keyPath: "contents")
            anim.values = image.frames
            anim.keyTimes = times
            anim.duration = total
            anim.calculationMode = .discrete
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "gif")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animasjonen må legges inn på nytt når visningen kommer tilbake på skjermen
        if window != nil, let img = current {
            current = nil
            set(img)
        }
    }
}

struct AnimatedImage: NSViewRepresentable {
    let image: LoadedImage?
    var fill = false

    func makeNSView(context: Context) -> AnimatedImageNSView {
        let v = AnimatedImageNSView()
        v.fill = fill
        v.set(image)
        return v
    }

    func updateNSView(_ v: AnimatedImageNSView, context: Context) {
        if v.fill != fill { v.fill = fill }
        v.set(image)
    }
}

/// Bilde fra nettet. [fill] beskjærer så hele flaten fylles; ellers vises hele bildet.
/// [onLoad] får bildet når det er hentet (brukes til å måle bredde/høyde-forholdet).
struct RemoteImage: View {
    let url: String?
    var fill = false
    var maxPixel = 1600
    var videoFrame = false
    var onLoad: ((LoadedImage) -> Void)? = nil

    @ViewState private var image: LoadedImage?

    init(url: String?, fill: Bool = false, maxPixel: Int = 1600, videoFrame: Bool = false, onLoad: ((LoadedImage) -> Void)? = nil) {
        self.url = url
        self.fill = fill
        self.maxPixel = maxPixel
        self.videoFrame = videoFrame
        self.onLoad = onLoad
        _image = State(initialValue: videoFrame ? nil : ImageCache.shared.cached(url, maxPixel: maxPixel))
    }

    var body: some View {
        AnimatedImage(image: image, fill: fill)
            .task(id: url) {
                let loaded = videoFrame
                    ? await ImageCache.shared.videoFrame(url)
                    : await ImageCache.shared.load(url, maxPixel: maxPixel)
                image = loaded
                if let loaded { onLoad?(loaded) }
            }
    }
}

/// Profilbilde: kvadratisk med tynn kantlinje (som i Android-appen).
struct Avatar: View {
    let url: String
    let size: CGFloat
    var onTap: (() -> Void)? = nil

    var body: some View {
        RemoteImage(url: url, fill: true, maxPixel: 256)
            .frame(width: size, height: size)
            .background(PT.fg)
            .pBorder(PT.border)
            .contentShape(Rectangle())
            .if(onTap != nil) { $0.onTapGesture { onTap?() }.handCursor() }
    }
}

extension View {
    /// Hånd-peker over noe som kan klikkes.
    func handCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
