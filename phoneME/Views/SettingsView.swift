import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return L10n.string("Light")
        case .dark: return L10n.string("Dark")
        case .system: return L10n.string("System")
        }
    }

    var systemImage: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "circle.lefthalf.filled"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var storage: PhoneMEStorageController
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var profiles: GameProfileStore
    @EnvironmentObject private var profileTemplates: ProfileTemplateStore
    @EnvironmentObject private var session: EmulatorSession
    @EnvironmentObject private var backgroundExecution: BackgroundExecutionController
    @EnvironmentObject private var manicSkinStore: ManicSkinStore

    @AppStorage(AppLanguage.preferenceKey) private var appLanguage =
        AppLanguage.defaultLanguage.rawValue
    @AppStorage("appTheme") private var appTheme = AppTheme.system.rawValue
    @AppStorage(TranslationProvider.preferenceKey)
    private var translationProvider = TranslationProvider.defaultProvider.rawValue
    @AppStorage("enableActionBar") private var enableActionBar = true
    @AppStorage("enableStatusBar") private var enableStatusBar = false
    @AppStorage("keepScreenOn") private var keepScreenOn = false
    @State private var storageErrorMessage: String?
    @State private var isImportingManicSkin = false
    @State private var manicSkinErrorMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.nativeTitle)
                            .tag(language.rawValue)
                    }
                }
            } header: {
                Text("Language")
            }

            Section {
                Picker("Appearance", selection: $appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title)
                            .tag(theme.rawValue)
                    }
                }
            } header: {
                Text("Appearance")
            }

            Section {
                Picker("Translation service", selection: translationProviderBinding) {
                    ForEach(TranslationProvider.allCases) { provider in
                        Text(provider.title)
                            .tag(provider.rawValue)
                    }
                }
            } header: {
                Text("Translation")
            }

            Section {
                HStack {
                    Text("JIT Status")
                    Spacer()
                    Label(jitStatusTitle, systemImage: jitStatusSystemImage)
                        .foregroundStyle(jitStatusForegroundStyle)
                }
            } header: {
                Text("JIT")
            }

            Section("Player") {
                Toggle("App Bar", isOn: $enableActionBar)
                Toggle("Status Bar", isOn: $enableStatusBar)
                Toggle("Keep Screen Awake", isOn: $keepScreenOn)
            }

#if os(iOS)
            Section {
                Toggle("Run in Background", isOn: backgroundExecutionBinding)

                if backgroundExecution.isEnabled,
                   backgroundExecution.status.requiresSystemSettings {
                    Button("Open Location Settings") {
                        backgroundExecution.openSystemSettings()
                    }
                }
            } header: {
                Text("Background Execution")
            }
#endif

            Section {
                Picker("Java controller skin", selection: manicSkinSelectionBinding) {
                    Text("Built-in keypad").tag("")
                    ForEach(manicSkinStore.skins) { skin in
                        Text(skin.name).tag(skin.id)
                    }
                }

                Button {
                    isImportingManicSkin = true
                } label: {
                    Label("Import ManicEMU Skin", systemImage: "square.and.arrow.down")
                }

                if let selectedSkin = manicSkinStore.selectedSkin {
                    Text(L10n.format("Using %@ for the virtual Java controls.", selectedSkin.name))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The built-in phoneME keypad is currently active.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Java Controller Skin")
            }

            Section {
                Picker("Data Storage", selection: storageLocationBinding) {
                    ForEach(PhoneMEStorageLocation.allCases) { location in
                        Text(location.title)
                            .tag(location)
                    }
                }
                .disabled(storage.isSwitching)

                if storage.isSwitching {
                    HStack {
                        ProgressView()
                        Text("Moving library and game data…")
                            .foregroundStyle(.secondary)
                    }
                }

            } header: {
                Text("Storage")
            }

        }
        .fileImporter(
            isPresented: $isImportingManicSkin,
            // Some Files providers expose .manicskin as a generic file type.
            // Accept selectable files here; the ZIP and J2ME metadata are validated by ManicSkinStore.
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    _ = try manicSkinStore.importSkin(from: url)
                } catch {
                    manicSkinErrorMessage = error.localizedDescription
                }
            case .failure(let error):
                manicSkinErrorMessage = error.localizedDescription
            }
        }
        .navigationTitle("Settings")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .alert("Storage", isPresented: storageErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storageErrorMessage ?? "")
        }
        .alert("Java Controller Skin", isPresented: manicSkinErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manicSkinErrorMessage ?? "")
        }
        .task {
            session.refreshJITStatus()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                session.refreshJITStatus()
            }
        }
    }

    private var manicSkinSelectionBinding: Binding<String> {
        Binding(
            get: { manicSkinStore.selectedSkinID ?? "" },
            set: { value in
                manicSkinStore.selectSkin(id: value.isEmpty ? nil : value)
            }
        )
    }

    private var manicSkinErrorBinding: Binding<Bool> {
        Binding(
            get: { manicSkinErrorMessage != nil },
            set: { shown in
                if !shown {
                    manicSkinErrorMessage = nil
                }
            }
        )
    }

    private var jitStatusTitle: String {
        switch session.jitStatus {
        case .ready:
            return L10n.string("Ready")
        case .unavailable:
            return L10n.string("Permission Required")
        }
    }

    private var jitStatusSystemImage: String {
        session.jitStatus == .ready
            ? "checkmark.circle.fill"
            : "exclamationmark.triangle.fill"
    }

    private var jitStatusForegroundStyle: Color {
        session.jitStatus == .ready ? .green : .orange
    }

    private var translationProviderBinding: Binding<String> {
        Binding(
            get: { translationProvider },
            set: { rawValue in
                translationProvider = rawValue
                guard let provider = TranslationProvider(rawValue: rawValue) else {
                    return
                }
                for application in session.runningApplications.values {
                    let profile = profiles.profile(for: application.game)
                    guard profile.isAutoTranslationEnabled else { continue }
                    session.setAutoTranslationConfiguration(
                        enabled: true,
                        sourceLanguage:
                            profile.effectiveAutoTranslationSourceLanguage,
                        targetLanguage:
                            profile.effectiveAutoTranslationTargetLanguage,
                        provider: provider,
                        for: application.game
                    ) { _ in }
                }
            }
        )
    }

    private var storageLocationBinding: Binding<PhoneMEStorageLocation> {
        Binding(
            get: { storage.activeLocation },
            set: { switchStorage(to: $0) }
        )
    }

    private var storageErrorBinding: Binding<Bool> {
        Binding(
            get: { storageErrorMessage != nil },
            set: { if !$0 { storageErrorMessage = nil } }
        )
    }

    private func switchStorage(to location: PhoneMEStorageLocation) {
        guard location != storage.activeLocation else { return }
        guard session.runningApplications.isEmpty else {
            storageErrorMessage = L10n.string(
                "Close all running J2ME apps before changing the data location."
            )
            return
        }

        Task { @MainActor in
            do {
                try await storage.switchLocation(to: location)
                PhoneMERuntimeResources.configure(
                    storageRootURL: storage.rootURL
                )
                manicSkinStore.updateStorageRoot(storage.rootURL)
                session.resetRuntimeForStorageChange()
                library.reloadFromStorage()
                profiles.reloadFromStorage()
                profileTemplates.reloadFromStorage()
            } catch {
                storageErrorMessage = error.localizedDescription
            }
        }
    }

#if os(iOS)
    private var backgroundExecutionBinding: Binding<Bool> {
        Binding(
            get: { backgroundExecution.isEnabled },
            set: { backgroundExecution.setEnabled($0) }
        )
    }
#endif
}

struct ProfilesView: View {
    @EnvironmentObject private var templates: ProfileTemplateStore

    @State private var editingTemplate: ProfileTemplate?
    @State private var renamingTemplate: ProfileTemplate?
    @State private var showAddDialog = false
    @State private var enteredName = ""

    @ViewBuilder
    var body: some View {
        Group {
            if templates.templates.isEmpty {
                PhoneMEEmptyStateView(
                    title: "No Profiles",
                    message: "Create a reusable profile for display, font and input settings.",
                    systemImage: "slider.horizontal.3",
                    actionTitle: "Create Profile",
                    action: beginAddingProfile
                )
            } else {
                List(templates.templates) { template in
                    Button {
                        editingTemplate = template
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(template.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if template.id == templates.defaultTemplateID {
                                        Text("Default")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if template.id == templates.defaultTemplateID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("Default profile")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            templates.setDefault(template)
                        } label: {
                            Label("Set as Default", systemImage: "checkmark.circle")
                        }
                        Button {
                            editingTemplate = template
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            enteredName = template.name
                            renamingTemplate = template
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            templates.remove(template)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Profiles")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: beginAddingProfile) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add profile")
            }
        }
        .phoneMETextInputAlert(
            isPresented: $showAddDialog,
            title: "New Profile",
            placeholder: "Profile Name",
            text: $enteredName,
            confirmTitle: "Add"
        ) {
            if let template = templates.add(name: enteredName) {
                editingTemplate = template
            }
        }
        .phoneMETextInputAlert(
            isPresented: renameDialogBinding,
            title: "Rename Profile",
            placeholder: "Profile Name",
            text: $enteredName,
            confirmTitle: "Save"
        ) {
            if let renamingTemplate {
                templates.rename(renamingTemplate, to: enteredName)
            }
        }
        .sheet(item: $editingTemplate) { template in
            PhoneMENavigationStack {
                GameProfileEditorView(
                    profileName: template.name,
                    initialProfile: templates.currentTemplate(template)?.profile ?? template.profile
                ) { profile in
                    templates.save(profile, for: template)
                }
            }
        }
    }

    private func beginAddingProfile() {
        enteredName = ""
        showAddDialog = true
    }

    private var renameDialogBinding: Binding<Bool> {
        Binding(
            get: { renamingTemplate != nil },
            set: { if !$0 { renamingTemplate = nil } }
        )
    }
}


