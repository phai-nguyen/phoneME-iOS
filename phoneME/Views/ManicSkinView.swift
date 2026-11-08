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
        hapticStyle: GameProfile.ControllerHapticStyle = .soft,
        @ViewBuilder screenContent: @escaping () -> ScreenContent
    ) {
        self.skin = skin
        self.session = session
        self.screenContent = screenContent
        _inputCoordinator = StateObject(
            wrappedValue: ManicSkinInputCoordinator(
                session: session,
                hapticStyle: hapticStyle
            )
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
                        canvasScale: scale,
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
    private let hapticGenerator: UIImpactFeedbackGenerator?

    init(session: EmulatorSession, hapticStyle: GameProfile.ControllerHapticStyle) {
        self.session = session
        let style: UIImpactFeedbackGenerator.FeedbackStyle?
        switch hapticStyle {
        case .off: style = nil
        case .soft: style = .soft
        case .light: style = .light
        case .medium: style = .medium
        case .heavy: style = .heavy
        case .rigid: style = .rigid
        }
        if let style {
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.prepare()
            hapticGenerator = generator
        } else {
            hapticGenerator = nil
        }
    }

    func triggerHaptic() {
        guard let hapticGenerator else { return }
        hapticGenerator.impactOccurred()
        hapticGenerator.prepare()
    }

    func update(keys: [J2MEKey], pressed: Bool, haptic: Bool = true) {
        guard let session else { return }
        var unique = Set<J2MEKey>()
        var didActivateKey = false
        for key in keys where unique.insert(key).inserted {
            let count = keyOwnerCounts[key, default: 0]
            if pressed {
                keyOwnerCounts[key] = count + 1
                if count == 0 {
                    session.send(key, pressed: true)
                    didActivateKey = true
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
        if haptic && didActivateKey {
            triggerHaptic()
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
    let canvasScale: CGFloat
    let inputCoordinator: ManicSkinInputCoordinator

    @State private var isPressed = false

    var body: some View {
        Group {
            if item.isThumbstick {
                ManicSkinThumbstickCaptureView(
                    item: item,
                    canvasScale: canvasScale,
                    onKeysChanged: { keys, pressed in
                        inputCoordinator.update(keys: keys, pressed: pressed, haptic: false)
                    },
                    onHaptic: {
                        inputCoordinator.triggerHaptic()
                    }
                )
            } else {
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
            let nextSet = Set(keys(at: touch.location(in: self), item: item))
            let previousSet = Set(activeTouches[identifier] ?? [])
            if previousSet == nextSet { continue }

            let released = previousSet.subtracting(nextSet).sorted { $0.rawValue < $1.rawValue }
            let pressed = nextSet.subtracting(previousSet).sorted { $0.rawValue < $1.rawValue }
            if !released.isEmpty { onKeysChanged?(released, false) }
            if !pressed.isEmpty { onKeysChanged?(pressed, true) }

            if nextSet.isEmpty {
                activeTouches.removeValue(forKey: identifier)
            } else {
                activeTouches[identifier] = nextSet.sorted { $0.rawValue < $1.rawValue }
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

@MainActor
private struct ManicSkinThumbstickCaptureView: UIViewRepresentable {
    let item: ManicSkinItem
    let canvasScale: CGFloat
    let onKeysChanged: ([J2MEKey], Bool) -> Void
    let onHaptic: () -> Void

    func makeUIView(context: Context) -> ManicSkinNativeThumbstickView {
        let view = ManicSkinNativeThumbstickView()
        view.update(item: item, canvasScale: canvasScale,
                    onKeysChanged: onKeysChanged, onHaptic: onHaptic)
        return view
    }

    func updateUIView(_ view: ManicSkinNativeThumbstickView, context: Context) {
        view.update(item: item, canvasScale: canvasScale,
                    onKeysChanged: onKeysChanged, onHaptic: onHaptic)
    }

    static func dismantleUIView(_ view: ManicSkinNativeThumbstickView, coordinator: ()) {
        view.releaseAllTouches()
    }
}

@MainActor
private final class ManicSkinNativeThumbstickView: UIView {
    private let knobImageView = UIImageView()
    private var item: ManicSkinItem?
    private var canvasScale: CGFloat = 1
    private var onKeysChanged: (([J2MEKey], Bool) -> Void)?
    private var onHaptic: (() -> Void)?
    private var activeTouchID: ObjectIdentifier?
    private var trackingOrigin: CGPoint?
    private var activeKeys = Set<J2MEKey>()
    private var knobCenter = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        clipsToBounds = false
        knobImageView.backgroundColor = .clear
        knobImageView.contentMode = .scaleAspectFit
        knobImageView.isUserInteractionEnabled = false
        addSubview(knobImageView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        clipsToBounds = false
        knobImageView.contentMode = .scaleAspectFit
        addSubview(knobImageView)
    }

    func update(
        item: ManicSkinItem,
        canvasScale: CGFloat,
        onKeysChanged: @escaping ([J2MEKey], Bool) -> Void,
        onHaptic: @escaping () -> Void
    ) {
        let imageChanged = self.item?.normalAssetURL != item.normalAssetURL
        self.item = item
        self.canvasScale = canvasScale
        self.onKeysChanged = onKeysChanged
        self.onHaptic = onHaptic
        if imageChanged || knobImageView.image == nil {
            knobImageView.image = item.normalAssetURL.flatMap { ManicSkinPDFRenderer.image(at: $0) }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size: CGSize
        if let knob = item?.thumbstickSize {
            size = CGSize(width: max(knob.width * canvasScale, 1),
                          height: max(knob.height * canvasScale, 1))
        } else {
            size = bounds.size
        }
        knobImageView.bounds = CGRect(origin: .zero, size: size)
        if activeTouchID == nil {
            knobCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        knobImageView.center = knobCenter
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouchID == nil,
              let touch = touches.first,
              bounds.width > 0, bounds.height > 0 else { return }
        activeTouchID = ObjectIdentifier(touch)
        trackingOrigin = touch.location(in: self)
        knobCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        knobImageView.center = knobCenter
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouchID,
              let touch = touches.first(where: { ObjectIdentifier($0) == activeTouchID }),
              var origin = trackingOrigin else { return }

        let location = touch.location(in: self)
        let dx = location.x - origin.x
        let dy = location.y - origin.y

        if !(bounds.minX...bounds.maxX).contains(location.x), abs(dx) >= bounds.midX {
            origin.x = bounds.midX
        }
        if !(bounds.minY...bounds.maxY).contains(location.y), abs(dy) >= bounds.midY {
            origin.y = bounds.midY
        }
        trackingOrigin = origin
        updateAnalog(translation: CGPoint(x: dx, y: dy))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    func releaseAllTouches() {
        releaseKeys()
        activeTouchID = nil
        trackingOrigin = nil
        knobCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        knobImageView.center = knobCenter
    }

    private func updateAnalog(translation: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = Double(translation.x)
        let dy = Double(translation.y)
        let maximumDistance = Double(bounds.midX) * 0.8
        let distance = min(hypot(dx, dy), maximumDistance)
        let angle = atan2(dy, dx)
        let adjustedX = Double(center.x) + distance * cos(angle)
        let adjustedY = Double(center.y) + distance * sin(angle)
        knobCenter = CGPoint(x: adjustedX, y: adjustedY)
        knobImageView.center = knobCenter

        let insetSide = Double(bounds.midX)
        guard insetSide > 0 else { return }
        let insetMinX = Double(center.x) - insetSide / 2
        let insetMinY = Double(center.y) - insetSide / 2

        var xAxis = ((adjustedX - insetMinX) / insetSide) * 2 - 1
        xAxis = min(max(xAxis, -1), 1)
        if abs(xAxis) < 0.1 { xAxis = 0 }

        var yAxis = -(((adjustedY - insetMinY) / insetSide) * 2 - 1)
        yAxis = min(max(yAxis, -1), 1)
        if abs(yAxis) < 0.1 { yAxis = 0 }

        var nextKeys = Set<J2MEKey>()
        if xAxis < 0 { nextKeys.insert(.left) }
        if xAxis > 0 { nextKeys.insert(.right) }
        if yAxis > 0 { nextKeys.insert(.up) }
        if yAxis < 0 { nextKeys.insert(.down) }
        updateKeys(nextKeys)
    }

    private func updateKeys(_ nextKeys: Set<J2MEKey>) {
        let released = activeKeys.subtracting(nextKeys).sorted { $0.rawValue < $1.rawValue }
        let pressed = nextKeys.subtracting(activeKeys).sorted { $0.rawValue < $1.rawValue }
        if !released.isEmpty { onKeysChanged?(released, false) }
        if !pressed.isEmpty {
            onKeysChanged?(pressed, true)
            onHaptic?()
        }
        activeKeys = nextKeys
    }

    private func finish(_ touches: Set<UITouch>) {
        guard let activeTouchID,
              touches.contains(where: { ObjectIdentifier($0) == activeTouchID }) else { return }
        releaseKeys()
        self.activeTouchID = nil
        trackingOrigin = nil
        knobCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        knobImageView.center = knobCenter
        onHaptic?()
    }

    private func releaseKeys() {
        guard !activeKeys.isEmpty else { return }
        let keys = activeKeys.sorted { $0.rawValue < $1.rawValue }
        activeKeys.removeAll()
        onKeysChanged?(keys, false)
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
