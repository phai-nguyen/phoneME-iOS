import CryptoKit
import Foundation

struct ManicSkinItem: Identifiable {
    let id: String
    let frame: CGRect
    let normalAssetURL: URL?
    let selectedAssetURL: URL?
    let directKeys: [J2MEKey]
    let directionalKeys: [String: J2MEKey]

    var hasDirectionalInput: Bool {
        !directionalKeys.isEmpty
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
    let portraitLayout: ManicSkinLayout
    let landscapeLayout: ManicSkinLayout?

    func layout(for size: CGSize) -> ManicSkinLayout {
        if size.width > size.height {
            return landscapeLayout ?? portraitLayout
        }
        return portraitLayout
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
        let selectedPlatform = (iphone["standard"] as? [String: Any])
            ?? (iphone["edgeToEdge"] as? [String: Any])
            ?? iphone

        let parsedPortrait = try parseLayout(
            selectedPlatform["portrait"] as? [String: Any],
            folderURL: folderURL
        )
        let landscape = try parseLayout(
            selectedPlatform["landscape"] as? [String: Any],
            folderURL: folderURL
        )
        guard let defaultLayout = parsedPortrait ?? landscape else {
            throw ManicSkinImportError.invalidMetadata
        }

        return ManicSkin(
            id: id,
            name: name,
            identifier: identifier,
            folderURL: folderURL,
            portraitLayout: defaultLayout,
            landscapeLayout: landscape
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

        var items: [ManicSkinItem] = []
        let rawItems = value["items"] as? [[String: Any]] ?? []
        for (index, rawItem) in rawItems.enumerated() {
            guard let frame = normalizedFrame(
                rawItem["frame"],
                mappingSize: mappingSize
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
            let (directKeys, directionalKeys) = parseInputs(rawItem["inputs"])

            guard !directKeys.isEmpty || !directionalKeys.isEmpty else {
                continue
            }

            items.append(ManicSkinItem(
                id: "item-\(index)",
                frame: frame,
                normalAssetURL: normalURL,
                selectedAssetURL: selectedURL,
                directKeys: directKeys,
                directionalKeys: directionalKeys
            ))
        }

        let screens = value["screens"] as? [[String: Any]] ?? []
        let screenFrame: CGRect
        if let outputFrame = screens.first?["outputFrame"],
           let normalized = normalizedOutputFrame(outputFrame) {
            screenFrame = normalized
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

    private static func normalizedOutputFrame(_ value: Any?) -> CGRect? {
        guard let frame = value as? [String: Any],
              let x = number(frame["x"]),
              let y = number(frame["y"]),
              let width = number(frame["width"]),
              let height = number(frame["height"]),
              width > 0, height > 0,
              abs(x) <= 2, abs(y) <= 2,
              width <= 2, height <= 2 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func normalizedFrame(
        _ value: Any?,
        mappingSize: CGSize
    ) -> CGRect? {
        guard let frame = value as? [String: Any],
              let x = number(frame["x"]),
              let y = number(frame["y"]),
              let width = number(frame["width"]),
              let height = number(frame["height"]),
              width > 0, height > 0,
              width <= mappingSize.width * 2,
              height <= mappingSize.height * 2,
              abs(x) <= mappingSize.width * 2,
              abs(y) <= mappingSize.height * 2 else {
            return nil
        }
        return CGRect(
            x: x / mappingSize.width,
            y: y / mappingSize.height,
            width: width / mappingSize.width,
            height: height / mappingSize.height
        )
    }

    private static func parseInputs(
        _ value: Any?
    ) -> ([J2MEKey], [String: J2MEKey]) {
        var direct = [J2MEKey]()
        var directional = [String: J2MEKey]()

        if let inputs = value as? [String: Any] {
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
        } else if let values = value as? [String] {
            let cardinalValues = values.compactMap { normalizedDirection($0) }
            if Set(cardinalValues).count >= 2 {
                for direction in Set(cardinalValues) {
                    if let key = key(for: direction) {
                        directional[direction] = key
                    }
                }
            } else {
                direct = values.compactMap(key(for:))
            }
        } else if let single = value as? String, let key = key(for: single) {
            direct = [key]
        }

        var seen = Set<J2MEKey>()
        direct = direct.filter { seen.insert($0).inserted }
        return (direct, directional)
    }

    private static func normalizedDirection(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "up": return "up"
        case "down": return "down"
        case "left": return "left"
        case "right": return "right"
        default: return nil
        }
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

        try FileManager.default.createDirectory(
            at: skinsDirectoryURL,
            withIntermediateDirectories: true
        )

        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard sourceData.count <= 32 * 1024 * 1024 else {
            throw ManicSkinArchiveError.tooLarge
        }
        let digest = SHA256.hash(data: sourceData)
        let id = digest.map { String(format: "%02x", $0) }.joined()
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
            try ManicSkinArchive.extract(from: sourceURL, to: stagingURL)
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
