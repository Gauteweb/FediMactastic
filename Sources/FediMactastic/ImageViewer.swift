import AppKit
import SwiftUI

/// Tilstand for zoom/panorering av ett bilde. Forskyvningen er målt fra midten av visningsflaten.
struct ZoomState: Equatable {
    var scale: CGFloat = 1
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
}

let maxZoom: CGFloat = 6

/// Holder bildet innenfor visningsflaten (ingen tomrom utover det zoomingen gir plass til).
func clampZoom(_ s: ZoomState, _ width: CGFloat, _ height: CGFloat) -> ZoomState {
    let maxX = width * (s.scale - 1) / 2
    let maxY = height * (s.scale - 1) / 2
    var c = s
    c.offsetX = min(max(s.offsetX, -maxX), maxX)
    c.offsetY = min(max(s.offsetY, -maxY), maxY)
    return c
}

/// Zoomer rundt [centroid] slik at punktet under fingrene/pekeren blir liggende stille, og flytter med [pan].
func applyZoomGesture(_ s: ZoomState, zoomChange: CGFloat, pan: CGSize, centroid: CGPoint, width: CGFloat, height: CGFloat) -> ZoomState {
    let newScale = min(max(s.scale * zoomChange, 1), maxZoom)
    let ratio = newScale / s.scale
    let rx = centroid.x - width / 2
    let ry = centroid.y - height / 2
    let raw = ZoomState(
        scale: newScale,
        offsetX: rx + pan.width - (rx - s.offsetX) * ratio,
        offsetY: ry + pan.height - (ry - s.offsetY) * ratio
    )
    return clampZoom(raw, width, height)
}

/// Dobbeltklikk: tilbake til normal hvis zoomet inn, ellers zoom inn mot klikkpunktet.
func toggleZoomAt(_ s: ZoomState, _ tap: CGPoint, _ width: CGFloat, _ height: CGFloat, target: CGFloat = 2.5) -> ZoomState {
    s.scale > 1.01 ? ZoomState() : applyZoomGesture(s, zoomChange: target / s.scale, pan: .zero, centroid: tap, width: width, height: height)
}

/// Bildevisning som dekker hele vinduet: bla mellom bildene (piltaster eller knapper), klyp,
/// dobbeltklikk eller scroll med ⌘ for å zoome, og alt-teksten ligger fast under bildet.
struct ImageViewer: View {
    let images: [MediaAttachment]
    let onDismiss: () -> Void
    @ViewState private var index: Int

    init(images: [MediaAttachment], startIndex: Int, onDismiss: @escaping () -> Void) {
        self.images = images
        self.onDismiss = onDismiss
        _index = ViewState(initialValue: min(max(startIndex, 0), max(images.count - 1, 0)))
    }

    var body: some View {
        if images.indices.contains(index) {
            let current = images[index]
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        TopIconButton(icon: "xmark", help: L("viewer_close"), action: onDismiss)
                            .keyboardShortcut(.cancelAction)
                        if images.count > 1 {
                            Text("\(index + 1) / \(images.count)").bold().foregroundStyle(PT.topBarText)
                        }
                        Spacer()
                        PTextButton(text: L("viewer_open_original")) { openExternal(current.url) }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 50)
                    PDivider()
                }
                .background(PT.topBar.ignoresSafeArea(edges: .top))

                ZStack {
                    ZoomableImage(m: current).id(current.id)
                    if images.count > 1 {
                        HStack {
                            arrow("chevron.left", L("image_prev"), enabled: index > 0) { index -= 1 }
                                .keyboardShortcut(.leftArrow, modifiers: [])
                            Spacer()
                            arrow("chevron.right", L("image_next"), enabled: index < images.count - 1) { index += 1 }
                                .keyboardShortcut(.rightArrow, modifiers: [])
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                altPanel(current.description)
            }
            .background(Color.black.opacity(0.96).ignoresSafeArea())
            .contentShape(Rectangle())
            .onTapGesture {} // Hindrer at klikk går gjennom til innholdet bak
        }
    }

    private func arrow(_ icon: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0)
        .help(help)
    }

    private func altPanel(_ description: String?) -> some View {
        let has = !(description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            PDivider()
            AutoHeightScroll(maxHeight: 200) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("alt_badge")).font(.system(size: 12, weight: .bold)).foregroundStyle(PT.link)
                    Text(has ? description! : L("alt_none"))
                        .font(.system(size: 15))
                        .foregroundStyle(has ? PT.text : PT.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
        }
        .background(PT.fg)
    }
}

private struct ZoomableImage: View {
    let m: MediaAttachment
    @ViewState private var zoom = ZoomState()
    @ViewState private var lastMagnification: CGFloat = 1
    @ViewState private var lastDrag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            RemoteImage(url: m.url, fill: false, maxPixel: 4096)
                .frame(width: w, height: h)
                .scaleEffect(zoom.scale)
                .offset(x: zoom.offsetX, y: zoom.offsetY)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { v in
                        withAnimation(.easeInOut(duration: 0.2)) { zoom = toggleZoomAt(zoom, v.location, w, h) }
                    }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            let change = v.magnification / lastMagnification
                            lastMagnification = v.magnification
                            zoom = applyZoomGesture(zoom, zoomChange: change, pan: .zero, centroid: v.startLocation, width: w, height: h)
                        }
                        .onEnded { _ in lastMagnification = 1 }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            guard zoom.scale > 1.01 else { return }
                            let d = CGSize(width: v.translation.width - lastDrag.width, height: v.translation.height - lastDrag.height)
                            lastDrag = v.translation
                            zoom = clampZoom(ZoomState(scale: zoom.scale, offsetX: zoom.offsetX + d.width, offsetY: zoom.offsetY + d.height), w, h)
                        }
                        .onEnded { _ in lastDrag = .zero }
                )
                .help(m.description ?? "")
        }
        .clipped()
    }
}
