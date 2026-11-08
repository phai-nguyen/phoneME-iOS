import CryptoKit
import Foundation

struct ManicSkinAnimation {
    let type: String
    let beginFrame: CGRect
    let endFrame: CGRect
}

struct ManicSkinItem: Identifiable {
    let id: String
    let frame: CGRect
    let extendedFrame: CGRect
    let normalAssetURL: URL?
    let selectedAssetURL: URL?
    let directKeys: [J2MEKey]
    let directionalKeys: [String: J2MEKey]
    let thumbstickSize: CGSize?
    let isTouchScreen: Bool
    let isSwitchButton: Bool
    let selfRetracting: Bool
    let animation: ManicSkinAnimation?

    var hasDirectionalInput: Bool {
        !directionalKeys.isEmpty
    }

    var isThumbstick: Bool {
        thumbstickSize != nil && hasDirectionalInput
    }

    // DeltaCore gives thumbsticks, touch surfaces, and switches their own
    // item.frame hit area. Ordinary buttons and D-pads use extendedFrame.
    var hitFrame: CGRect {
        if isThumbstick || isTouchScreen || isSwitchButton {
            return frame
        }
        return extendedFrame
    }
}

struct ManicSkinLayout {
    let mappingSize: CGSize
    let backgroundAssetURL: URL?
    let screenFrame: CGRect
    let items: [ManicSkinItem]
}

struct ManicSkin: Identifiable {
    let id: String
    let name: String
    let identifier: String
    let folderURL: URL

    private let standardPortraitLayout: ManicSkinLayout?
    private let standardLandscapeLayout: ManicSkinLayout?
    private let edgeToEdgePortraitLayout: ManicSkinLayout?
    private let edgeToEdgeLandscapeLayout: ManicSkinLayout?

    func layout(for size: CGSize, safeAreaBottom: CGFloat) -> ManicSkinLayout {
        let prefersEdgeToEdge = safeAreaBottom > 0.5
        let isLandscape = size.width > size.height

        let preferredPortrait = prefersEdgeToEdge
            ? edgeToEdgePortraitLayout
            : standardPortraitLayout
        let preferredLandscape = prefersEdgeToEdge
            ? edgeToEdgeLandscapeLayout
            : standardLandscapeLayout
        let fallbackPortrait = prefersEdgeToEdge
            ? standardPortraitLayout
            : edgeToEdgePortraitLayout
        let fallbackLandscape = prefersEdgeToEdge
            ? standardLandscapeLayout
            : edgeToEdgeLandscapeLayout

        if isLandscape {
            return preferredLandscape
                ?? fallbackLandscape
                ?? preferredPortrait
                ?? fallbackPortrait
                ?? Self.requiredLayout(
                    standardPortraitLayout,
                    edgeToEdgePortraitLayout,
                    standardLandscapeLayout,
                    edgeToEdgeLandscapeLayout
                )
        }

        return preferredPortrait
            ?? fallbackPortrait
            ?? preferredLandscape
            ?? fallbackLandscape
            ?? Self.requiredLayout(
                standardPortraitLayout,
                edgeToEdgePortraitLayout,
                standardLandscapeLayout,
                edgeToEdgeLandscapeLayout
            )
    }

    private static func requiredLayout(
        _ standardPortrait: ManicSkinLayout?,
        _ edgePortrait: ManicSkinLayout?,
        _ standardLandscape: ManicSkinLayout?,
        _ edgeLandscape: ManicSkinLayout?
    ) -> ManicSkinLayout {
        // A skin is validated to contain at least one representation before
        // this method can be called.
        standardPortrait
            ?? edgePortrait
            ?? standardLandscape
            ?? edgeLandscape!
    }

    static func read(from folderURL: URL, id: String) throws -> ManicSkin {
        let infoURL = folderURL.appendingPathComponent("info.json")
        let data = try Data(contentsOf: infoURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManicSkinImportError.invalidMetadata
        }

        let gameType = root["gameTypeIdentifier"] as? String ?? ""
        guard gameType == "public.aoshuang.game.j2me" else {
            throw ManicSkinImportError.notJ2MESkin
        }

        let identifier = root["identifier"] as? String ?? ""
        let name = root["name"] as? String ?? folderURL.deletingPathExtension().lastPathComponent
        guard !identifier.isEmpty, !name.isEmpty else {
            throw ManicSkinImportError.invalidMetadata
        }

        let representations = root["representations"] as? [String: Any] ?? [:]
        let iphone = representations["iphone"] as? [String: Any] ?? representations
        let hasDisplayVariants = iphone["standard"] != nil || iphone["edgeToEdge"] != nil

        // Keep both iPhone display representations. DeltaCore selects between
        // them using the active window's safe-area traits instead of always
        // preferring Standard when both are present.
        let standardRepresentation = iphone["standard"] as? [String: Any]
            ?? (hasDisplayVariants ? nil : iphone)
        let edgeToEdgeRepresentation = iphone["edgeToEdge"] as? [String: Any]

        let standardPortrait = try parseLayout(
            standardRepresentation?["portrait"] as? [String: Any],
            folderURL: folderURL
        )
        let standardLandscape = try parseLayout(
            standardRepresentation?["landscape"] as? [String: Any],
            folderURL: folderURL
        )
        let edgePortrait = try parseLayout(
            edgeToEdgeRepresentation?["portrait"] as? [String: Any],
            folderURL: folderURL
        )
        let edgeLandscape = try parseLayout(
            edgeToEdgeRepresentation?["landscape"] as? [String: Any],
            folderURL: folderURL
        )

        guard standardPortrait != nil
                || standardLandscape != nil
                || edgePortrait != nil
                || edgeLandscape != nil else {
            throw ManicSkinImportError.invalidMetadata
        }

        return ManicSkin(
            id: id,
            name: name,
            identifier: identifier,
            folderURL: folderURL,
            standardPortraitLayout: standardPortrait,
            standardLandscapeLayout: standardLandscape,
            edgeToEdgePortraitLayout: edgePortrait,
            edgeToEdgeLandscapeLayout: edgeLandscape
        )
    }

    private static func parseLayout(
        _ value: [String: Any]?,
        folderURL: URL
    ) throws -> ManicSkinLayout? {
        guard let value else { return nil }
        guard let mapping = value["mappingSize"] as? [String: Any],
              let width = number(mapping["width"]),
              let height = number(mapping["height"]),
              width > 0, height > 0,
              width <= 8192, height <= 8192 else {
            throw ManicSkinImportError.invalidMetadata
        }

        let mappingSize = CGSize(width: width, height: height)
        let assets = value["assets"] as? [String: Any] ?? [:]
        let backgroundName = assets["resizable"] as? String
            ?? assets["background"] as? String
        let backgroundURL = try assetURL(backgroundName, folderURL: folderURL)
        let representationEdges = parseExtendedEdges(value["extendedEdges"])

        var items: [ManicSkinItem] = []
        let rawItems = value["items"] as? [[String: Any]] ?? []
        for (index, rawItem) in rawItems.enumerated() {
            guard let rawFrame = rawRect(rawItem["frame"]) else {
                continue
            }

            let placement = (rawItem["placement"] as? String)?.lowercased() ?? "controller"
            let itemEdges = mergedEdges(
                inherited: representationEdges,
                overrides: parseExtendedEdges(rawItem["extendedEdges"]),
                rawOverrides: rawItem["extendedEdges"]
            )
            let rawExtendedFrame = applying(itemEdges, to: rawFrame)
            guard let frame = normalizedRect(
                rawFrame,
                mappingSize: mappingSize,
                placement: placement
            ), let extendedFrame = normalizedRect(
                rawExtendedFrame,
                mappingSize: mappingSize,
                placement: placement
            ) else {
                continue
            }

            let asset = rawItem["asset"] as? [String: Any] ?? [:]
            let thumbstick = rawItem["thumbstick"] as? [String: Any] ?? [:]
            let normalName = asset["normal"] as? String
                ?? thumbstick["name"] as? String
            let selectedName = asset["selected"] as? String
            let normalURL = try assetURL(normalName, folderURL: folderURL)
            let selectedURL = try assetURL(selectedName, folderURL: folderURL)
            let thumbstickSize: CGSize?
            if let knobWidth = number(thumbstick["width"]),
               let knobHeight = number(thumbstick["height"]),
               knobWidth > 0, knobHeight > 0,
               knobWidth <= mappingSize.width * 2,
               knobHeight <= mappingSize.height * 2 {
                // Keep knob dimensions in mappingSize pixels. The renderer
                // multiplies them by the canvas pixel-to-point scale.
                thumbstickSize = CGSize(width: knobWidth, height: knobHeight)
            } else {
                thumbstickSize = nil
            }

            let inputs = parseInputs(rawItem["inputs"])
            let selfRetracting = rawItem["selfRetracting"] as? Bool ?? true
            let animation = parseAnimation(
                rawItem["animation"],
                mappingSize: mappingSize,
                placement: placement
            )

            // Artwork-only items remain visible. Touch-screen items are kept
            // even though their x/y inputs are pointer coordinates, not keys.
            guard !inputs.directKeys.isEmpty
                    || !inputs.directionalKeys.isEmpty
                    || inputs.isTouchScreen
                    || inputs.isSwitchButton
                    || normalURL != nil
                    || selectedURL != nil else {
                continue
            }

            items.append(ManicSkinItem(
                id: "item-\(index)",
                frame: frame,
                extendedFrame: extendedFrame,
                normalAssetURL: normalURL,
                selectedAssetURL: selectedURL,
                directKeys: inputs.directKeys,
                directionalKeys: inputs.directionalKeys,
                thumbstickSize: thumbstickSize,
                isTouchScreen: inputs.isTouchScreen,
                isSwitchButton: inputs.isSwitchButton,
                selfRetracting: selfRetracting,
                animation: animation
            ))
        }

        let screens = value["screens"] as? [[String: Any]] ?? []
        let screenFrame: CGRect
        if let firstScreen = screens.first {
            let isAppPlacement = (firstScreen["placement"] as? String) == "app"
            if let outputFrame = firstScreen["outputFrame"],
               let normalized = normalizedOutputFrame(
                   outputFrame,
                   mappingSize: mappingSize,
                   alreadyNormalized: isAppPlacement
               ) {
                screenFrame = normalized
            } else {
                screenFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        } else {
            screenFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        return ManicSkinLayout(
            mappingSize: mappingSize,
            backgroundAssetURL: backgroundURL,
            screenFrame: screenFrame,
            items: items
        )
    }

    private struct ExtendedEdges {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var left: CGFloat = 0
        var right: CGFloat = 0
    }

    private static func parseExtendedEdges(_ value: Any?) -> ExtendedEdges {
        guard let dictionary = value as? [String: Any] else {
            return ExtendedEdges()
        }
        return ExtendedEdges(
            top: number(dictionary["top"]) ?? 0,
            bottom: number(dictionary["bottom"]) ?? 0,
            left: number(dictionary["left"]) ?? 0,
            right: number(dictionary["right"]) ?? 0
        )
    }

    private static func mergedEdges(
        inherited: ExtendedEdges,
        overrides: ExtendedEdges,
        rawOverrides: Any?
    ) -> ExtendedEdges {
        guard let dictionary = rawOverrides as? [String: Any] else {
            return inherited
        }
        return ExtendedEdges(
            top: dictionary["top"] == nil ? inherited.top : overrides.top,
            bottom: dictionary["bottom"] == nil ? inherited.bottom : overrides.bottom,
            left: dictionary["left"] == nil ? inherited.left : overrides.left,
            right: dictionary["right"] == nil ? inherited.right : overrides.right
        )
    }

    private static func applying(
        _ edges: ExtendedEdges,
        to frame: CGRect
    ) -> CGRect {
        CGRect(
            x: frame.minX - edges.left,
            y: frame.minY - edges.top,
            width: frame.width + edges.left + edges.right,
            height: frame.height + edges.top + edges.bottom
        )
    }

    private static func parseAnimation(
        _ value: Any?,
        mappingSize: CGSize,
        placement: String
    ) -> ManicSkinAnimation? {
        guard let dictionary = value as? [String: Any],
              let type = dictionary["type"] as? String,
              let rawBegin = rawRect(dictionary["begin"]),
              let rawEnd = rawRect(dictionary["end"]),
              let begin = normalizedRect(
                rawBegin,
                mappingSize: mappingSize,
                placement: placement
              ),
              let end = normalizedRect(
                rawEnd,
                mappingSize: mappingSize,
                placement: placement
              ) else {
            return nil
        }
        return ManicSkinAnimation(
            type: type.lowercased(),
            beginFrame: begin,
            endFrame: end
        )
    }

    private static func rawRect(_ value: Any?) -> CGRect? {
        guard let frame = value as? [String: Any],
              let x = number(frame["x"]),
              let y = number(frame["y"]),
              let width = number(frame["width"]),
              let height = number(frame["height"]),
              width > 0, height > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func normalizedRect(
        _ rect: CGRect,
        mappingSize: CGSize,
        placement: String
    ) -> CGRect? {
        guard mappingSize.width > 0, mappingSize.height > 0 else {
            return nil
        }
        guard abs(rect.minX) <= mappingSize.width * 2,
              abs(rect.minY) <= mappingSize.height * 2,
              rect.width <= mappingSize.width * 2,
              rect.height <= mappingSize.height * 2 else {
            return nil
        }
        if placement == "app" {
            return rect
        }
        return CGRect(
            x: rect.minX / mappingSize.width,
            y: rect.minY / mappingSize.height,
            width: rect.width / mappingSize.width,
            height: rect.height / mappingSize.height
        )
    }

    private static func assetURL(
        _ name: String?,
        folderURL: URL
    ) throws -> URL? {
        guard let name, !name.isEmpty else { return nil }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else {
            throw ManicSkinImportError.invalidMetadata
        }
        let url = folderURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ManicSkinImportError.missingAsset(name)
        }
        return url
    }

    private static func normalizedOutputFrame(
        _ value: Any?,
        mappingSize: CGSize,
        alreadyNormalized: Bool
    ) -> CGRect? {
        guard let frame = rawRect(value) else { return nil }
        if alreadyNormalized {
            return frame
        }
        if abs(frame.minX) <= 2, abs(frame.minY) <= 2,
           frame.width <= 2, frame.height <= 2 {
            return frame
        }
        return normalizedRect(
            frame,
            mappingSize: mappingSize,
            placement: "controller"
        )
    }

    private static func parseInputs(
        _ value: Any?
    ) -> (
        directKeys: [J2MEKey],
        directionalKeys: [String: J2MEKey],
        isTouchScreen: Bool,
        isSwitchButton: Bool
    ) {
        var direct = [J2MEKey]()
        var directional = [String: J2MEKey]()
        var isTouchScreen = false
        var isSwitchButton = false

        if let inputs = value as? [String: Any] {
            if inputs["x"] != nil && inputs["y"] != nil {
                // DeltaCore models this as a continuous pointer surface.
                // These tokens must never be translated into Java key codes.
                isTouchScreen = true
            } else {
                for (direction, rawValue) in inputs {
                    guard let rawValue = rawValue as? String,
                          let key = key(for: rawValue) else {
                        continue
                    }
                    let normalizedDirection = direction.lowercased()
                    if ["up", "down", "left", "right"].contains(normalizedDirection) {
                        directional[normalizedDirection] = key
                    } else {
                        direct.append(key)
                    }
                }
            }
        } else if let values = value as? [String] {
            // In the ManicEMU/DeltaCore format, an array is a standard button
            // mapping, even when a value happens to be "up" or "left".
            direct = values.compactMap(key(for:))
        } else if value is String {
            // A single string is a switch input in the source format.
            isSwitchButton = true
            if let value = value as? String, let key = key(for: value) {
                direct = [key]
            }
        }

        var seen = Set<J2MEKey>()
        direct = direct.filter { seen.insert($0).inserted }
        return (direct, directional, isTouchScreen, isSwitchButton)
    }

    private static func key(for value: String) -> J2MEKey? {
        let token = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        switch token {
        case "up", "leftthumbstickup", "rightthumbstickup": return .up
        case "down", "leftthumbstickdown", "rightthumbstickdown": return .down
        case "left", "leftthumbstickleft", "rightthumbstickleft": return .left
        case "right", "leftthumbstickright", "rightthumbstickright": return .right
        case "fire", "a", "b", "x", "y", "buttona", "buttonb": return .fire
        case "softleft", "softkeyleft", "select", "l1", "l3": return .softLeft
        case "softright", "softkeyright", "start", "r1", "r3": return .softRight
        case "star", "*": return .star
        case "pound", "hash", "#": return .pound
        case "num0": return .zero
        case "num1": return .one
        case "num2": return .two
        case "num3": return .three
        case "num4": return .four
        case "num5": return .five
        case "num6": return .six
        case "num7": return .seven
        case "num8": return .eight
        case "num9": return .nine
        default:
            if token.count == 1, let digit = token.first,
               let value = digit.wholeNumberValue, (0...9).contains(value) {
                return J2MEKey(rawValue: Int32(48 + value))
            }
            if token.hasPrefix("key"), token.count == 4,
               let last = token.last,
               let value = last.wholeNumberValue, (0...9).contains(value) {
                return J2MEKey(rawValue: Int32(48 + value))
            }
            return nil
        }
    }

    private static func number(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber else { return nil }
        let result = CGFloat(number.doubleValue)
        return result.isFinite ? result : nil
    }
}

enum ManicSkinImportError: LocalizedError {
    case invalidMetadata
    case notJ2MESkin
    case missingAsset(String)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            return L10n.string("The ManicEMU skin info.json file is invalid.")
        case .notJ2MESkin:
            return L10n.string("This ManicEMU skin is not a Java ME skin.")
        case .missingAsset(let name):
            return L10n.format("The ManicEMU skin is missing asset %@.", name)
        case .importFailed(let message):
            return L10n.format("The ManicEMU skin could not be imported: %@", message)
        }
    }
}

@MainActor
final class ManicSkinStore: ObservableObject {
    @Published private(set) var skins: [ManicSkin] = []
    @Published private(set) var selectedSkinID: String?

    private static let selectedSkinKey = "phoneME.manicSkin.selectedID"
    private var storageRootURL: URL

    init(storageRootURL: URL) {
        self.storageRootURL = storageRootURL
        selectedSkinID = UserDefaults.standard.string(forKey: Self.selectedSkinKey)
        reload()
    }

    var selectedSkin: ManicSkin? {
        guard let selectedSkinID else { return nil }
        return skins.first(where: { $0.id == selectedSkinID })
    }

    func selectSkin(id: String?) {
        selectedSkinID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.selectedSkinKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedSkinKey)
        }
    }

    func updateStorageRoot(_ rootURL: URL) {
        guard storageRootURL.standardizedFileURL != rootURL.standardizedFileURL else {
            return
        }
        storageRootURL = rootURL
        reload()
    }

    func reload() {
        let directory = skinsDirectoryURL
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        skins = folders.compactMap { folder in
            let id = folder.lastPathComponent
            return try? ManicSkin.read(from: folder, id: id)
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if let selectedSkinID,
           !skins.contains(where: { $0.id == selectedSkinID }) {
            selectSkin(id: nil)
        }
    }

    @discardableResult
    func importSkin(from sourceURL: URL) throws -> ManicSkin {
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let localImportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phoneME-ManicSkin-\(UUID().uuidString)")
            .appendingPathExtension("manicskin")
        defer {
            try? FileManager.default.removeItem(at: localImportURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: localImportURL)

        let sourceData = try Data(contentsOf: localImportURL, options: [.mappedIfSafe])
        guard sourceData.count <= 32 * 1024 * 1024 else {
            throw ManicSkinArchiveError.tooLarge
        }
        let digest = SHA256.hash(data: sourceData)
        let id = digest.map { String(format: "%02x", $0) }.joined()

        try FileManager.default.createDirectory(
            at: skinsDirectoryURL,
            withIntermediateDirectories: true
        )
        let finalURL = skinsDirectoryURL.appendingPathComponent(id, isDirectory: true)

        if FileManager.default.fileExists(atPath: finalURL.path) {
            let existing = try ManicSkin.read(from: finalURL, id: id)
            selectSkin(id: id)
            reload()
            return existing
        }

        let stagingURL = skinsDirectoryURL.appendingPathComponent(
            ".import-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try ManicSkinArchive.extract(from: localImportURL, to: stagingURL)
            _ = try ManicSkin.read(from: stagingURL, id: id)
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }

        reload()
        selectSkin(id: id)
        guard let imported = selectedSkin else {
            throw ManicSkinImportError.importFailed("The imported skin could not be indexed.")
        }
        return imported
    }

    func removeSkin(id: String) throws {
        let url = skinsDirectoryURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.removeItem(at: url)
        if selectedSkinID == id {
            selectSkin(id: nil)
        }
        reload()
    }

    private var skinsDirectoryURL: URL {
        storageRootURL.appendingPathComponent("skins", isDirectory: true)
    }
}
