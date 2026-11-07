import CoreGraphics
import SwiftUI
import UIKit

@MainActor
struct ManicSkinView<ScreenContent: View>: View {
    let skin: ManicSkin
    private let session: EmulatorSession
    private let screenContent: () -> ScreenContent
    @StateObject private var inputCoordinator: ManicSkinInputCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init(
        skin: ManicSkin,
        session: EmulatorSession,
        @ViewBuilder screenContent: @escaping () -> ScreenContent
    ) {
        self.skin = skin
        self.session = session
        self.screenContent = screenContent
        _inputCoordinator = StateObject(
            wrappedValue: ManicSkinInputCoordinator(session: session)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = skin.layout(for: geometry.size)
            let mappingWidth = max(layout.mappingSize.width, 1)
            let mappingHeight = max(layout.mappingSize.height, 1)
            let scale = min(
                geometry.size.width / mappingWidth,
                geometry.size.height / mappingHeight
            )
            let canvasSize = CGSize(
                width: mappingWidth * scale,
                height: mappingHeight * scale
            )
            let origin = CGPoint(
                x: (geometry.size.width - canvasSize.width) / 2,
                y: (geometry.size.height - canvasSize.height) / 2
            )
            let screenFrame = renderedFrame(
                layout.screenFrame,
                origin: origin,
                canvasSize: canvasSize
            )

            ZStack(alignment: .topLeading) {
                Color.black

                if let backgroundURL = layout.backgroundAssetURL,
                   let background = ManicSkinPDFRenderer.image(at: backgroundURL) {
                    Image(uiImage: background)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .position(
                            x: origin.x + canvasSize.width / 2,
                            y: origin.y + canvasSize.height / 2
                        )
                }

                screenContent()
                    .frame(
                        width: max(screenFrame.width, 1),
                        height: max(screenFrame.height, 1)
                    )
                    .position(x: screenFrame.midX, y: screenFrame.midY)
                    .clipped()

                ForEach(layout.items) { item in
                    let frame = renderedFrame(
                        item.frame,
                        origin: origin,
                        canvasSize: canvasSize
                    )
                    ManicSkinItemView(
                        item: item,
                        inputCoordinator: inputCoordinator
                    )
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                inputCoordinator.releaseAll()
            }
        }
        .onDisappear {
            inputCoordinator.releaseAll()
        }
        .accessibilityLabel(L10n.string("ManicEMU Java controller skin"))
    }

    private func renderedFrame(
        _ normalized: CGRect,
        origin: CGPoint,
        canvasSize: CGSize
    ) -> CGRect {
        CGRect(
            x: origin.x + normalized.minX * canvasSize.width,
            y: origin.y + normalized.minY * canvasSize.height,
            width: normalized.width * canvasSize.width,
            height: normalized.height * canvasSize.height
        )
    }
}

@MainActor
private final class ManicSkinInputCoordinator: ObservableObject {
    private weak var session: EmulatorSession?
    private var keyOwnerCounts: [J2MEKey: Int] = [:]

    init(session: EmulatorSession) {
        self.session = session
    }

    func update(keys: [J2MEKey], pressed: Bool) {
        guard let session else { return }
        var unique = Set<J2MEKey>()
        for key in keys where unique.insert(key).inserted {
            let count = keyOwnerCounts[key, default: 0]
            if pressed {
                keyOwnerCounts[key] = count + 1
                if count == 0 {
                    session.send(key, pressed: true)
                }
            } else if count <= 1 {
                keyOwnerCounts.removeValue(forKey: key)
                if count == 1 {
                    session.send(key, pressed: false)
                }
            } else {
                keyOwnerCounts[key] = count - 1
            }
        }
    }

    func releaseAll() {
        guard let session else {
            keyOwnerCounts.removeAll()
            return
        }
        let keys = keyOwnerCounts.keys.sorted { $0.rawValue < $1.rawValue }
        keyOwnerCounts.removeAll()
        for key in keys {
            session.send(key, pressed: false)
        }
    }
}

@MainActor
private struct ManicSkinItemView: View {
    let item: ManicSkinItem
    let inputCoordinator: ManicSkinInputCoordinator

    @State private var isPressed = false

    var body: some View {
        ZStack {
            if isPressed,
               let selectedURL = item.selectedAssetURL,
               let image = ManicSkinPDFRenderer.image(at: selectedURL) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if let normalURL = item.normalAssetURL,
                      let image = ManicSkinPDFRenderer.image(at: normalURL) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }

            ManicSkinTouchCaptureView(item: item) { keys, pressed in
                isPressed = pressed
                inputCoordinator.update(keys: keys, pressed: pressed)
            }
        }
        .contentShape(Rectangle())
    }
}

#if os(iOS)
@MainActor
private struct ManicSkinTouchCaptureView: UIViewRepresentable {
    let item: ManicSkinItem
    let onKeysChanged: ([J2MEKey], Bool) -> Void

    func makeUIView(context: Context) -> ManicSkinNativeTouchView {
        let view = ManicSkinNativeTouchView()
        view.item = item
        view.onKeysChanged = onKeysChanged
        return view
    }

    func updateUIView(_ view: ManicSkinNativeTouchView, context: Context) {
        view.item = item
        view.onKeysChanged = onKeysChanged
    }

    static func dismantleUIView(
        _ view: ManicSkinNativeTouchView,
        coordinator: ()
    ) {
        view.releaseAllTouches()
    }
}

@MainActor
private final class ManicSkinNativeTouchView: UIView {
    var item: ManicSkinItem?
    var onKeysChanged: (([J2MEKey], Bool) -> Void)?
    private var activeTouches: [ObjectIdentifier: [J2MEKey]] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        update(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        update(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    func releaseAllTouches() {
        for keys in activeTouches.values {
            onKeysChanged?(keys, false)
        }
        activeTouches.removeAll()
    }

    private func update(_ touches: Set<UITouch>) {
        guard let item else { return }
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            let nextKeys = keys(at: touch.location(in: self), item: item)
            let previousKeys = activeTouches[identifier] ?? []
            if previousKeys == nextKeys { continue }

            if !previousKeys.isEmpty {
                onKeysChanged?(previousKeys, false)
            }
            if nextKeys.isEmpty {
                activeTouches.removeValue(forKey: identifier)
            } else {
                activeTouches[identifier] = nextKeys
                onKeysChanged?(nextKeys, true)
            }
        }
    }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            if let keys = activeTouches.removeValue(forKey: identifier) {
                onKeysChanged?(keys, false)
            }
        }
    }

    private func keys(at point: CGPoint, item: ManicSkinItem) -> [J2MEKey] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        guard item.hasDirectionalInput else { return item.directKeys }

        let x = min(max(point.x / bounds.width, 0), 1)
        let y = min(max(point.y / bounds.height, 0), 1)
        var directions = [String]()

        if x < 0.34 {
            directions.append("left")
        } else if x > 0.66 {
            directions.append("right")
        }
        if y < 0.34 {
            directions.append("up")
        } else if y > 0.66 {
            directions.append("down")
        }

        if directions.isEmpty {
            return []
        }

        var seen = Set<J2MEKey>()
        return directions.compactMap { item.directionalKeys[$0] }
            .filter { seen.insert($0).inserted }
    }
}
#endif

@MainActor
private enum ManicSkinPDFRenderer {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard url.pathExtension.lowercased() == "pdf" else {
            guard let image = UIImage(contentsOfFile: url.path) else { return nil }
            cache.setObject(image, forKey: key)
            return image
        }
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else {
            return nil
        }

        let box = page.getBoxRect(.mediaBox).standardized
        guard box.width > 0, box.height > 0,
              box.width <= 8192, box.height <= 8192 else {
            return nil
        }

        let factor = min(1.5, 1600 / max(box.width, box.height))
        let size = CGSize(
            width: max(box.width * factor, 1),
            height: max(box.height * factor, 1)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: factor, y: -factor)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
