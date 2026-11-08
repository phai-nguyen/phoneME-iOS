import CoreGraphics
import SwiftUI
import UIKit
import simd

@MainActor
struct ManicSkinView<ScreenContent: View>: View {
    let skin: ManicSkin
    private let session: EmulatorSession
    private let screenContent: () -> ScreenContent
    private let onSpecialAction: (String) -> Void
    @StateObject private var inputCoordinator: ManicSkinInputCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowSafeAreaBottom: CGFloat = 0

    init(
        skin: ManicSkin,
        session: EmulatorSession,
        hapticStyle: GameProfile.ControllerHapticStyle = .soft,
        onSpecialAction: @escaping (String) -> Void = { _ in },
        @ViewBuilder screenContent: @escaping () -> ScreenContent
    ) {
        self.skin = skin
        self.session = session
        self.screenContent = screenContent
        self.onSpecialAction = onSpecialAction
        _inputCoordinator = StateObject(
            wrappedValue: ManicSkinInputCoordinator(
                session: session,
                hapticStyle: hapticStyle
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = skin.layout(
                for: geometry.size,
                safeAreaBottom: max(geometry.safeAreaInsets.bottom, windowSafeAreaBottom)
            )
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
                    let visualFrame = renderedFrame(
                        item.frame,
                        origin: origin,
                        canvasSize: canvasSize
                    )
                    let captureFrame = renderedFrame(
                        item.hitFrame,
                        origin: origin,
                        canvasSize: canvasSize
                    )
                    let animationBeginFrame = item.animation.map {
                        renderedFrame($0.beginFrame, origin: origin, canvasSize: canvasSize)
                    }.map {
                        CGRect(
                            x: $0.minX - captureFrame.minX,
                            y: $0.minY - captureFrame.minY,
                            width: $0.width,
                            height: $0.height
                        )
                    }
                    let animationEndFrame = item.animation.map {
                        renderedFrame($0.endFrame, origin: origin, canvasSize: canvasSize)
                    }.map {
                        CGRect(
                            x: $0.minX - captureFrame.minX,
                            y: $0.minY - captureFrame.minY,
                            width: $0.width,
                            height: $0.height
                        )
                    }
                    ManicSkinItemView(
                        item: item,
                        canvasScale: scale,
                        visualSize: visualFrame.size,
                        visualOrigin: CGPoint(
                            x: visualFrame.minX - captureFrame.minX,
                            y: visualFrame.minY - captureFrame.minY
                        ),
                        animationBeginFrame: animationBeginFrame,
                        animationEndFrame: animationEndFrame,
                        inputCoordinator: inputCoordinator,
                        onSpecialAction: onSpecialAction
                    )
                    .frame(
                        width: max(captureFrame.width, 1),
                        height: max(captureFrame.height, 1)
                    )
                    .position(x: captureFrame.midX, y: captureFrame.midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .background(alignment: .topLeading) {
                ManicSkinWindowSafeAreaReader { bottom in
                    if abs(windowSafeAreaBottom - bottom) > 0.5 {
                        windowSafeAreaBottom = bottom
                    }
                }
                .frame(width: 1, height: 1)
            }
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
    private var activePointer: (x: Int32, y: Int32)?

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

    func prepareHaptic() {
        hapticGenerator?.prepare()
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

    func pulse(keys: [J2MEKey]) {
        guard !keys.isEmpty else { return }
        update(keys: keys, pressed: true)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            self.update(keys: keys, pressed: false, haptic: false)
        }
    }

    func sendPointer(normalizedPoint: CGPoint, action: Int32) {
        guard let session else {
            activePointer = nil
            return
        }

        if action == 2 {
            guard let activePointer else { return }

            let releasePoint: (x: Int32, y: Int32)
            if let frameSize = session.frameStore.frameSize {
                let width = max(Int(frameSize.width.rounded()), 1)
                let height = max(Int(frameSize.height.rounded()), 1)
                let normalizedX = min(max(normalizedPoint.x, 0), 1)
                let normalizedY = min(max(normalizedPoint.y, 0), 1)
                releasePoint = (
                    Int32(min(max(Int(normalizedX * CGFloat(width)), 0), width - 1)),
                    Int32(min(max(Int(normalizedY * CGFloat(height)), 0), height - 1))
                )
            } else {
                releasePoint = activePointer
            }

            session.sendPointer(
                x: releasePoint.x,
                y: releasePoint.y,
                action: 2
            )
            self.activePointer = nil
            return
        }

        guard let frameSize = session.frameStore.frameSize else {
            return
        }
        // A move is valid only after a corresponding pointer-down.
        guard action != 3 || activePointer != nil else {
            return
        }

        // Recover safely if a new pointer-down arrives before the previous
        // pointer was released (for example after a view transition).
        if action == 1, let activePointer {
            session.sendPointer(
                x: activePointer.x,
                y: activePointer.y,
                action: 2
            )
            self.activePointer = nil
        }

        let width = max(Int(frameSize.width.rounded()), 1)
        let height = max(Int(frameSize.height.rounded()), 1)
        let normalizedX = min(max(normalizedPoint.x, 0), 1)
        let normalizedY = min(max(normalizedPoint.y, 0), 1)
        let x = min(max(Int(normalizedX * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(normalizedY * CGFloat(height)), 0), height - 1)

        session.sendPointer(x: Int32(x), y: Int32(y), action: action)
        activePointer = (Int32(x), Int32(y))
    }

    func releaseAll() {
        guard let session else {
            activePointer = nil
            keyOwnerCounts.removeAll()
            return
        }

        if let pointer = activePointer {
            session.sendPointer(x: pointer.x, y: pointer.y, action: 2)
            activePointer = nil
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
    let visualSize: CGSize
    let visualOrigin: CGPoint
    let animationBeginFrame: CGRect?
    let animationEndFrame: CGRect?
    let inputCoordinator: ManicSkinInputCoordinator
    let onSpecialAction: (String) -> Void

    @State private var isPressed = false

    var body: some View {
        let displayedArtworkFrame = artworkFrame

        ZStack(alignment: .topLeading) {
            artwork
                .frame(
                    width: max(displayedArtworkFrame.width, 1),
                    height: max(displayedArtworkFrame.height, 1)
                )
                .position(
                    x: displayedArtworkFrame.midX,
                    y: displayedArtworkFrame.midY
                )

            if item.isTouchScreen {
                ManicSkinTouchscreenCaptureView(
                    onPointer: { point, action in
                        inputCoordinator.sendPointer(
                            normalizedPoint: point,
                            action: action
                        )
                    },
                    onPressedChanged: { isPressed = $0 }
                )
            } else if item.isThumbstick {
                ManicSkinThumbstickCaptureView(
                    item: item,
                    canvasScale: canvasScale,
                    onKeysChanged: { keys, pressed in
                        inputCoordinator.update(keys: keys, pressed: pressed, haptic: false)
                    },
                    onHaptic: {
                        inputCoordinator.triggerHaptic()
                    },
                    onHapticPrepare: {
                        inputCoordinator.prepareHaptic()
                    }
                )
            } else if let specialAction = item.specialAction {
                ManicSkinSwitchCaptureView {
                    inputCoordinator.triggerHaptic()
                    onSpecialAction(specialAction)
                }
            } else if item.isSwitchButton {
                ManicSkinSwitchCaptureView {
                    activateSwitch()
                }
            } else {
                ManicSkinTouchCaptureView(item: item) { keys, pressed in
                    isPressed = pressed
                    inputCoordinator.update(keys: keys, pressed: pressed)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var artworkFrame: CGRect {
        if item.isSwitchButton,
           item.animation?.type == "spring" {
            return isPressed
                ? (animationEndFrame ?? CGRect(origin: visualOrigin, size: visualSize))
                : (animationBeginFrame ?? CGRect(origin: visualOrigin, size: visualSize))
        }
        return CGRect(origin: visualOrigin, size: visualSize)
    }

    private func activateSwitch() {
        inputCoordinator.pulse(keys: item.directKeys)

        guard item.selectedAssetURL != nil || item.animation?.type == "spring" else {
            return
        }

        if item.animation?.type == "spring" {
            if item.selfRetracting {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    isPressed = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        isPressed = false
                    }
                }
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    isPressed.toggle()
                }
            }
        } else {
            isPressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isPressed = false
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
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
    }
}

#if os(iOS)
@MainActor
private struct ManicSkinWindowSafeAreaReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ManicSkinWindowSafeAreaView {
        let view = ManicSkinWindowSafeAreaView()
        view.onChange = onChange
        return view
    }

    func updateUIView(
        _ view: ManicSkinWindowSafeAreaView,
        context: Context
    ) {
        view.onChange = onChange
        view.publishSafeArea()
    }
}

@MainActor
private final class ManicSkinWindowSafeAreaView: UIView {
    var onChange: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        publishSafeArea()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        publishSafeArea()
    }

    func publishSafeArea() {
        onChange?(window?.safeAreaInsets.bottom ?? safeAreaInsets.bottom)
    }
}

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
        guard bounds.width > 0, bounds.height > 0,
              bounds.contains(point) else {
            return []
        }
        guard item.hasDirectionalInput else {
            return item.directKeys
        }
        guard item.hitFrame.width > 0, item.hitFrame.height > 0 else {
            return []
        }

        // Convert the item's artwork frame into this (possibly expanded)
        // capture view's local coordinates, preserving DeltaCore's geometry.
        let itemFrame = CGRect(
            x: (item.frame.minX - item.hitFrame.minX)
                / item.hitFrame.width * bounds.width,
            y: (item.frame.minY - item.hitFrame.minY)
                / item.hitFrame.height * bounds.height,
            width: item.frame.width / item.hitFrame.width * bounds.width,
            height: item.frame.height / item.hitFrame.height * bounds.height
        )
        let thirdWidth = itemFrame.width / 3
        let thirdHeight = itemFrame.height / 3
        let topRect = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: thirdHeight + itemFrame.minY
        )
        let bottomRect = CGRect(
            x: 0,
            y: itemFrame.maxY - thirdHeight,
            width: bounds.width,
            height: thirdHeight + (bounds.maxY - itemFrame.maxY)
        )
        let leftRect = CGRect(
            x: 0,
            y: 0,
            width: thirdWidth + itemFrame.minX,
            height: bounds.height
        )
        let rightRect = CGRect(
            x: itemFrame.maxX - thirdWidth,
            y: 0,
            width: thirdWidth + (bounds.maxX - itemFrame.maxX),
            height: bounds.height
        )

        var directions = [String]()
        if topRect.contains(point) { directions.append("up") }
        if bottomRect.contains(point) { directions.append("down") }
        if leftRect.contains(point) { directions.append("left") }
        if rightRect.contains(point) { directions.append("right") }

        var seen = Set<J2MEKey>()
        return directions.compactMap { item.directionalKeys[$0] }
            .filter { seen.insert($0).inserted }
    }
}

@MainActor
private struct ManicSkinSwitchCaptureView: UIViewRepresentable {
    let onActivate: () -> Void

    func makeUIView(context: Context) -> ManicSkinNativeSwitchView {
        let view = ManicSkinNativeSwitchView()
        view.onActivate = onActivate
        return view
    }

    func updateUIView(
        _ view: ManicSkinNativeSwitchView,
        context: Context
    ) {
        view.onActivate = onActivate
    }
}

@MainActor
private final class ManicSkinNativeSwitchView: UIView {
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = false
        accessibilityTraits = .button
        addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTap))
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    @objc private func handleTap() {
        onActivate?()
    }
}

@MainActor
private struct ManicSkinTouchscreenCaptureView: UIViewRepresentable {
    let onPointer: (CGPoint, Int32) -> Void
    let onPressedChanged: (Bool) -> Void

    func makeUIView(context: Context) -> ManicSkinNativeTouchscreenView {
        let view = ManicSkinNativeTouchscreenView()
        view.onPointer = onPointer
        view.onPressedChanged = onPressedChanged
        return view
    }

    func updateUIView(
        _ view: ManicSkinNativeTouchscreenView,
        context: Context
    ) {
        view.onPointer = onPointer
        view.onPressedChanged = onPressedChanged
    }

    static func dismantleUIView(
        _ view: ManicSkinNativeTouchscreenView,
        coordinator: ()
    ) {
        view.releaseActiveTouch()
    }
}

@MainActor
private final class ManicSkinNativeTouchscreenView: UIView {
    var onPointer: ((CGPoint, Int32) -> Void)?
    var onPressedChanged: ((Bool) -> Void)?

    private var activeTouchID: ObjectIdentifier?
    private var lastNormalizedPoint = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        isUserInteractionEnabled = true
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            releaseActiveTouch()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouchID == nil, let touch = touches.first else { return }
        activeTouchID = ObjectIdentifier(touch)
        send(touch.location(in: self), action: 1)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch(in: touches) else { return }
        send(touch.location(in: self), action: 3)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch(in: touches) else { return }
        send(touch.location(in: self), action: 2)
        activeTouchID = nil
        onPressedChanged?(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseActiveTouch()
    }

    func releaseActiveTouch() {
        guard activeTouchID != nil else { return }
        onPointer?(lastNormalizedPoint, 2)
        activeTouchID = nil
        onPressedChanged?(false)
    }

    private func activeTouch(in touches: Set<UITouch>) -> UITouch? {
        guard let activeTouchID else { return nil }
        return touches.first { ObjectIdentifier($0) == activeTouchID }
    }

    private func send(_ point: CGPoint, action: Int32) {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let normalized = CGPoint(
            x: min(max(point.x / width, 0), 1),
            y: min(max(point.y / height, 0), 1)
        )
        lastNormalizedPoint = normalized
        onPointer?(normalized, action)
        onPressedChanged?(action != 2)
    }
}

@MainActor
private final class ManicSkinImmediatePanGestureRecognizer: UIPanGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state != .began else { return }
        super.touchesBegan(touches, with: event)
        state = .began
    }
}

@MainActor
private struct ManicSkinThumbstickCaptureView: UIViewRepresentable {
    let item: ManicSkinItem
    let canvasScale: CGFloat
    let onKeysChanged: ([J2MEKey], Bool) -> Void
    let onHaptic: () -> Void
    let onHapticPrepare: () -> Void

    func makeUIView(context: Context) -> ManicSkinNativeThumbstickView {
        let view = ManicSkinNativeThumbstickView()
        view.update(
            item: item,
            canvasScale: canvasScale,
            onKeysChanged: onKeysChanged,
            onHaptic: onHaptic,
            onHapticPrepare: onHapticPrepare
        )
        return view
    }

    func updateUIView(
        _ view: ManicSkinNativeThumbstickView,
        context: Context
    ) {
        view.update(
            item: item,
            canvasScale: canvasScale,
            onKeysChanged: onKeysChanged,
            onHaptic: onHaptic,
            onHapticPrepare: onHapticPrepare
        )
    }

    static func dismantleUIView(
        _ view: ManicSkinNativeThumbstickView,
        coordinator: ()
    ) {
        view.releaseAllTouches()
    }
}

@MainActor
private final class ManicSkinNativeThumbstickView: UIView {
    private enum Direction: Equatable {
        case up, down, left, right

        init?(xAxis: Double, yAxis: Double, threshold: Double) {
            let deadzone = -threshold...threshold
            switch (xAxis, yAxis) {
            case (deadzone, deadzone):
                return nil
            case (...0, deadzone):
                self = .left
            case (0..., deadzone):
                self = .right
            case (deadzone, ...0):
                self = .down
            case (deadzone, 0...):
                self = .up
            default:
                return nil
            }
        }
    }

    private let knobImageView = UIImageView()
    private var panGestureRecognizer: ManicSkinImmediatePanGestureRecognizer?
    private var item: ManicSkinItem?
    private var canvasScale: CGFloat = 1
    private var onKeysChanged: (([J2MEKey], Bool) -> Void)?
    private var onHaptic: (() -> Void)?
    private var onHapticPrepare: (() -> Void)?
    private var trackingOrigin: CGPoint?
    private var previousDirection: Direction?
    private var isActivated = false
    // Match DeltaCore: horizontal and vertical inputs have independent lifecycles.
    private var activeHorizontalKey: J2MEKey?
    private var activeVerticalKey: J2MEKey?
    private var knobCenter = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        clipsToBounds = false

        knobImageView.backgroundColor = .clear
        knobImageView.contentMode = .scaleAspectFit
        knobImageView.isUserInteractionEnabled = false
        addSubview(knobImageView)

        let pan = ManicSkinImmediatePanGestureRecognizer(
            target: self,
            action: #selector(handlePanGesture(_:))
        )
        pan.delaysTouchesBegan = true
        pan.cancelsTouchesInView = true
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        panGestureRecognizer = pan
    }

    func update(
        item: ManicSkinItem,
        canvasScale: CGFloat,
        onKeysChanged: @escaping ([J2MEKey], Bool) -> Void,
        onHaptic: @escaping () -> Void,
        onHapticPrepare: @escaping () -> Void
    ) {
        let imageChanged = self.item?.normalAssetURL != item.normalAssetURL
        self.item = item
        self.canvasScale = canvasScale
        self.onKeysChanged = onKeysChanged
        self.onHaptic = onHaptic
        self.onHapticPrepare = onHapticPrepare

        if imageChanged || knobImageView.image == nil {
            knobImageView.image = item.normalAssetURL.flatMap {
                ManicSkinPDFRenderer.image(at: $0)
            }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let size: CGSize
        if let knob = item?.thumbstickSize {
            size = CGSize(
                width: max(knob.width * canvasScale, 1),
                height: max(knob.height * canvasScale, 1)
            )
        } else {
            size = bounds.size
        }

        knobImageView.bounds = CGRect(origin: .zero, size: size)
        if trackingOrigin == nil {
            knobCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        knobImageView.center = knobCenter
    }

    @objc private func handlePanGesture(
        _ gestureRecognizer: UIPanGestureRecognizer
    ) {
        switch gestureRecognizer.state {
        case .began:
            trackingOrigin = gestureRecognizer.location(in: self)
            previousDirection = nil
            isActivated = false
            onHapticPrepare?()
            updateAnalog(translation: .zero)

        case .changed:
            guard var origin = trackingOrigin else { return }

            let location = gestureRecognizer.location(in: self)
            let translationX = location.x - origin.x
            let translationY = location.y - origin.y
            let translatedX = origin.x + translationX
            let translatedY = origin.y + translationY

            // Match DeltaCore: after reaching an edge, recenter only the
            // tracking origin so the knob can follow the finger on the way back.
            if !(bounds.minX...bounds.maxX).contains(translatedX),
               abs(translationX) >= bounds.midX {
                origin.x = bounds.midX
            }
            if !(bounds.minY...bounds.maxY).contains(translatedY),
               abs(translationY) >= bounds.midY {
                origin.y = bounds.midY
            }

            updateAnalog(translation: CGPoint(x: translationX, y: translationY))
            trackingOrigin = origin

        case .ended, .cancelled, .failed:
            guard trackingOrigin != nil else { return }
            onHaptic?()
            releaseKeys()
            trackingOrigin = nil
            isActivated = false
            previousDirection = nil
            resetKnobToCenter()

        default:
            break
        }
    }

    func releaseAllTouches() {
        let wasTracking = trackingOrigin != nil
        releaseKeys()
        trackingOrigin = nil
        isActivated = false
        previousDirection = nil
        resetKnobToCenter()

        // Reset a recognizer that was active when the app was backgrounded
        // or when SwiftUI dismantles this control.
        if wasTracking, let panGestureRecognizer {
            panGestureRecognizer.isEnabled = false
            panGestureRecognizer.isEnabled = true
        }
    }

    private func updateAnalog(translation: CGPoint) {
        guard !bounds.isEmpty else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let point = SIMD2(Double(translation.x), Double(translation.y))
        let maximumDistance = Double(bounds.midX) * 0.8
        let distance = min(simd_length(point), maximumDistance)
        let angle = atan2(point.y, point.x)

        let adjustedX = Double(center.x) + distance * cos(angle)
        let adjustedY = Double(center.y) + distance * sin(angle)
        knobCenter = CGPoint(x: adjustedX, y: adjustedY)
        knobImageView.center = knobCenter

        let insetSideLength = Double(bounds.midX)
        guard insetSideLength > 0 else { return }

        let insetMinX = Double(center.x) - insetSideLength / 2
        let insetMinY = Double(center.y) - insetSideLength / 2

        var xAxis = (adjustedX - insetMinX) / insetSideLength
        xAxis = min(max(xAxis, 0), 1)
        xAxis = (xAxis * 2) - 1
        if abs(xAxis) < 0.1 { xAxis = 0 }

        var yAxis = (adjustedY - insetMinY) / insetSideLength
        yAxis = max(yAxis, 0)
        yAxis = min(yAxis, 1)
        yAxis = -((yAxis * 2) - 1)
        if abs(yAxis) < 0.1 { yAxis = 0 }

        let magnitude = simd_length(SIMD2(xAxis, yAxis))
        let nowActivated = magnitude > 0.1

        if let direction = Direction(
            xAxis: xAxis,
            yAxis: yAxis,
            threshold: 0.1
        ) {
            if previousDirection != direction {
                onHaptic?()
            }
            previousDirection = direction
        } else {
            if nowActivated && !isActivated {
                onHaptic?()
            }
            previousDirection = nil
        }
        isActivated = nowActivated

        updateAxes(xAxis: xAxis, yAxis: yAxis)
    }

    private func updateAxis(_ nextKey: J2MEKey?, activeKey: inout J2MEKey?) {
        guard activeKey != nextKey else { return }

        if let currentKey = activeKey {
            onKeysChanged?([currentKey], false)
        }
        if let nextKey {
            onKeysChanged?([nextKey], true)
        }
        activeKey = nextKey
    }

    private func updateAxes(xAxis: Double, yAxis: Double) {
        let horizontalKey: J2MEKey?
        if xAxis < 0 {
            horizontalKey = .left
        } else if xAxis > 0 {
            horizontalKey = .right
        } else {
            horizontalKey = nil
        }

        let verticalKey: J2MEKey?
        if yAxis > 0 {
            verticalKey = .up
        } else if yAxis < 0 {
            verticalKey = .down
        } else {
            verticalKey = nil
        }

        // Releasing one axis must never change the other axis' held key.
        updateAxis(horizontalKey, activeKey: &activeHorizontalKey)
        updateAxis(verticalKey, activeKey: &activeVerticalKey)
    }

    private func releaseKeys() {
        updateAxes(xAxis: 0, yAxis: 0)
    }

    private func resetKnobToCenter() {
        knobCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        knobImageView.center = knobCenter
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
