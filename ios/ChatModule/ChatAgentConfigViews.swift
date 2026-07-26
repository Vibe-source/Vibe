import SwiftUI
import UIKit

/// One entry in the agent tool catalog (mirrors the backend ToolRegistry).
struct ChatAgentToolInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
}

/// A prompt argument the agent's system prompt references via {{name}}.
/// `locked` is true when the value is pinned in backend code and cannot be
/// edited from the app (shown read-only).
struct ChatAgentPromptVariable: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    var value: String
    let locked: Bool
}

struct ChatAgentModelInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let tier: String
    let recommended: Bool
    let thinkingLevels: [String]
    let defaultThinkingLevel: String
}

struct ChatAgentModelProviderInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let available: Bool
    let models: [ChatAgentModelInfo]
}

struct ChatAgentModelRegistry: Equatable {
    let defaultProvider: String
    let defaultModelId: String
    let providers: [ChatAgentModelProviderInfo]
    let isFallback: Bool

    func provider(id: String) -> ChatAgentModelProviderInfo? {
        providers.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    func model(providerId: String, modelId: String) -> ChatAgentModelInfo? {
        provider(id: providerId)?.models.first {
            $0.id.caseInsensitiveCompare(modelId) == .orderedSame
        }
    }

    func selection(modelId: String) -> (provider: ChatAgentModelProviderInfo, model: ChatAgentModelInfo)? {
        for provider in providers {
            if let model = provider.models.first(where: {
                $0.id.caseInsensitiveCompare(modelId) == .orderedSame
            }) {
                return (provider, model)
            }
        }
        return nil
    }

    static let fallback = ChatAgentModelRegistry(
        defaultProvider: "anthropic",
        defaultModelId: "claude-sonnet-5",
        providers: [
            ChatAgentModelProviderInfo(
                id: "anthropic",
                name: "Anthropic",
                available: true,
                models: [
                    ChatAgentModelInfo(
                        id: "claude-fable-5",
                        name: "Fable 5",
                        description: "Deep reasoning for complex decisions.",
                        tier: "frontier",
                        recommended: false,
                        thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "claude-opus-4-8",
                        name: "Opus 4.8",
                        description: "Maximum capability for demanding work.",
                        tier: "frontier",
                        recommended: false,
                        thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "claude-sonnet-5",
                        name: "Sonnet 5",
                        description: "Fast, capable, and recommended for most agents.",
                        tier: "balanced",
                        recommended: true,
                        thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "claude-haiku-4-5-20251001",
                        name: "Haiku 4.5",
                        description: "Quick responses for lightweight tasks.",
                        tier: "fast",
                        recommended: false,
                        thinkingLevels: ["medium"],
                        defaultThinkingLevel: "medium"),
                ]),
            ChatAgentModelProviderInfo(
                id: "openai",
                name: "OpenAI",
                available: true,
                models: [
                    ChatAgentModelInfo(
                        id: "gpt-5.6-sol",
                        name: "GPT-5.6 Sol",
                        description: "Maximum capability for demanding work.",
                        tier: "frontier",
                        recommended: false,
                        thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "gpt-5.6-terra",
                        name: "GPT-5.6 Terra",
                        description: "A strong balance of speed and capability.",
                        tier: "balanced",
                        recommended: true,
                        thinkingLevels: ["low", "medium", "high", "xhigh"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "gpt-5.6-luna",
                        name: "GPT-5.6 Luna",
                        description: "Fast and efficient for everyday tasks.",
                        tier: "fast",
                        recommended: false,
                        thinkingLevels: ["low", "medium", "high"],
                        defaultThinkingLevel: "medium"),
                ]),
        ],
        isFallback: true
    )
}

enum ChatAgentModelRegistryService {
    static func load(
        apiBaseURL: URL,
        token: String,
        completion: @escaping (ChatAgentModelRegistry) -> Void
    ) {
        let base = apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/agents/model_registry") else {
            completion(.fallback)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
            data, response, error in
            DispatchQueue.main.async {
                guard
                    error == nil,
                    (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                    let data,
                    let payload =
                        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                    let registry = parse(payload)
                else {
                    completion(.fallback)
                    return
                }
                completion(registry)
            }
        }.resume()
    }

    static func parse(_ payload: [String: Any]) -> ChatAgentModelRegistry? {
        guard
            let defaultSelection = payload["default"] as? [String: Any],
            let defaultProvider = normalizedString(defaultSelection["provider"]),
            let defaultModelId = normalizedString(
                defaultSelection["modelId"] ?? defaultSelection["model_id"]),
            let rawProviders = payload["providers"] as? [[String: Any]]
        else {
            return nil
        }

        let providers: [ChatAgentModelProviderInfo] = rawProviders.compactMap { rawProvider in
            guard
                let id = normalizedString(rawProvider["id"]),
                let rawModels = rawProvider["models"] as? [[String: Any]]
            else {
                return nil
            }
            let models: [ChatAgentModelInfo] = rawModels.compactMap { rawModel in
                guard let modelId = normalizedString(rawModel["id"]) else { return nil }
                let fallbackModel = ChatAgentModelRegistry.fallback.selection(modelId: modelId)?.model
                let rawThinkingLevels =
                    normalizedStringList(
                        rawModel["thinkingLevels"] ?? rawModel["thinking_levels"])
                    ?? fallbackModel?.thinkingLevels
                    ?? ["medium"]
                let thinkingLevels = normalizedThinkingLevels(rawThinkingLevels)
                let requestedDefault =
                    normalizedString(
                        rawModel["defaultThinkingLevel"]
                            ?? rawModel["default_thinking_level"])
                    ?? fallbackModel?.defaultThinkingLevel
                    ?? "medium"
                let defaultThinkingLevel =
                    thinkingLevels.first(where: {
                        $0.caseInsensitiveCompare(requestedDefault) == .orderedSame
                    })
                    ?? thinkingLevels.first(where: { $0 == "medium" })
                    ?? thinkingLevels.first
                    ?? "medium"
                return ChatAgentModelInfo(
                    id: modelId,
                    name: normalizedString(rawModel["name"]) ?? modelId,
                    description: normalizedString(rawModel["description"]) ?? "",
                    tier: normalizedString(rawModel["tier"]) ?? "",
                    recommended: boolean(rawModel["recommended"]) ?? false,
                    thinkingLevels: thinkingLevels.isEmpty ? ["medium"] : thinkingLevels,
                    defaultThinkingLevel: defaultThinkingLevel
                )
            }
            let providerName: String
            switch id.lowercased() {
            case "anthropic":
                providerName = "Anthropic"
            case "openai":
                providerName = "OpenAI"
            default:
                providerName = normalizedString(rawProvider["name"]) ?? id
            }
            return ChatAgentModelProviderInfo(
                id: id,
                name: providerName,
                available: boolean(rawProvider["available"]) ?? false,
                models: models
            )
        }

        guard !providers.isEmpty else { return nil }
        return ChatAgentModelRegistry(
            defaultProvider: defaultProvider,
            defaultModelId: defaultModelId,
            providers: providers,
            isFallback: false
        )
    }

    private static func normalizedString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func normalizedStringList(_ raw: Any?) -> [String]? {
        guard let values = raw as? [Any] else { return nil }
        return values.compactMap { normalizedString($0) }
    }

    private static func normalizedThinkingLevels(_ values: [String]) -> [String] {
        let accepted = Set(["low", "medium", "high", "xhigh", "max"])
        var seen = Set<String>()
        return values.compactMap { raw in
            let level = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard accepted.contains(level), seen.insert(level).inserted else { return nil }
            return level
        }
    }
}

class ChatAgentConfigViewModel: ObservableObject {
    @Published var card: ChatListRow.AgentCard
    @Published var modelRegistry: ChatAgentModelRegistry = .fallback

    var onRename: ((String, @escaping (Bool) -> Void) -> Void)?
    var onSavePrompt: ((String, @escaping (Bool) -> Void) -> Void)?
    var onSetStatus: ((Bool) -> Void)?
    var onUpdateEventInboxMode: ((String, String, Int, [String], @escaping (Bool) -> Void) -> Void)?
    var onCopy: ((String) -> Void)?
    var onToast: ((String) -> Void)?

    /// Present the native photo picker / camera flow to set the agent avatar.
    var onPickAvatar: (() -> Void)?
    /// Live handle availability check. Returns (available, reason?) where reason
    /// is a short server code such as "username_taken" when unavailable.
    var onCheckUsername: ((String, @escaping (Bool, String?) -> Void) -> Void)?
    /// Persist a new handle. Returns (success, errorMessage?).
    var onSaveUsername: ((String, @escaping (Bool, String?) -> Void) -> Void)?
    /// Load the tool catalog the agent can be granted.
    var onLoadToolRegistry: ((@escaping ([ChatAgentToolInfo]) -> Void) -> Void)?
    /// Persist the agent's enabled tool ids.
    var onSaveTools: (([String], @escaping (Bool) -> Void) -> Void)?
    /// Load the agent's configured prompt variables (name/value/locked).
    var onLoadPromptVariables: ((@escaping ([ChatAgentPromptVariable]) -> Void) -> Void)?
    /// Persist updated prompt variable values. Returns success.
    var onSavePromptVariables: (([ChatAgentPromptVariable], @escaping (Bool) -> Void) -> Void)?
    /// Load the server-authoritative provider/model catalog.
    var onLoadModelRegistry: ((@escaping (ChatAgentModelRegistry) -> Void) -> Void)?
    /// Persist one exact provider/model pair.
    var onSaveModelSelection: ((String, String, @escaping (Bool) -> Void) -> Void)?
    /// Persist the agent's voice provider ("google" or "openai_realtime").
    var onSaveVoiceProvider: ((String, @escaping (Bool) -> Void) -> Void)?

    /// Whether the current session's `card.latestSecret` (a just-minted invoke secret) is
    /// shown in the clear right now. Resets to false whenever the view is torn down —
    /// there is no way to re-reveal it after that, by design (hashed at rest server-side).
    @Published var isInvokeSecretRevealed = false
    @Published var isRotatingInvokeSecret = false
    /// Mints a new invoke secret (`POST /agents/:id/rotate_secret`). Completion carries
    /// (success, freshSecret, freshSecretHint).
    var onRotateInvokeSecret: ((@escaping (Bool, String?, String?) -> Void) -> Void)?

    /// Webhook signing secret state — a DIFFERENT, reversibly-stored secret (verifies
    /// inbound webhook signatures) that can be fetched again anytime, unlike the
    /// hashed-at-rest invoke secret above.
    @Published var webhookSecret: String?
    @Published var webhookSecretHint: String?
    @Published var isWebhookSecretRevealed = false
    @Published var isLoadingWebhookSecret = false
    /// Fetches the webhook signing secret (`GET /agents/:id/secret`).
    var onLoadWebhookSecret: ((@escaping (String?, String?) -> Void) -> Void)?

    init(card: ChatListRow.AgentCard) {
        self.card = card
    }
}

/// A Settings-app-style row label: a colored icon tile followed by a title. Gives the
/// Configuration list instant visual scannability instead of a column of plain text rows.
private struct ChatAgentSettingsRowLabel: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
            Text(title)
        }
    }
}

struct ChatAgentSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftName: String = ""
    @State private var isSavingName = false
    @State private var didLoadModelRegistry = false
    @State private var showRotateInvokeSecretConfirm = false

    private var promptSummary: String {
        let prompt = (viewModel.card.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? "Not set" : prompt
    }

    private var toolsSummary: String {
        let count = viewModel.card.enabledTools.count
        switch count {
        case 0: return "None"
        case 1: return "1 tool"
        default: return "\(count) tools"
        }
    }

    private var modelSummary: String {
        // A cached card without the new fields represents an existing agent,
        // whose previous effective runtime was Anthropic Haiku 4.5.
        let providerId = viewModel.card.modelProvider ?? "anthropic"
        let modelId = viewModel.card.modelId ?? "claude-haiku-4-5-20251001"
        let provider =
            viewModel.modelRegistry.provider(id: providerId)
            ?? ChatAgentModelRegistry.fallback.provider(id: providerId)
        let model =
            viewModel.modelRegistry.model(providerId: providerId, modelId: modelId)
            ?? ChatAgentModelRegistry.fallback.model(providerId: providerId, modelId: modelId)
        return "\(provider?.name ?? providerId) · \(model?.name ?? modelId)"
    }

    var body: some View {
        Form {
            // Profile / avatar — a single tappable affordance (the camera badge) instead
            // of a duplicate "Change Photo" button doing the same thing underneath it.
            Section {
                HStack {
                    Spacer()
                    Button(action: { viewModel.onPickAvatar?() }) {
                        ChatAgentGlobalAvatarView(
                            avatarUrl: viewModel.card.avatarUrl,
                            displayName: viewModel.card.displayName,
                            peerUserId: viewModel.card.agentUserId,
                            size: 88
                        )
                        .frame(width: 88, height: 88)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            } header: {
                Text("Profile")
            }

            Section {
                HStack {
                    TextField("Agent Name", text: $draftName)
                        .onSubmit { saveName() }

                    if isSavingName {
                        ProgressView().controlSize(.small)
                    } else if draftName != viewModel.card.displayName {
                        Button("Save") { saveName() }
                    }
                }

                NavigationLink(destination: ChatAgentUsernameView(viewModel: viewModel)) {
                    HStack {
                        Text("Handle")
                        Spacer()
                        Text(viewModel.card.username.map { "@\($0)" } ?? "Not set")
                            .foregroundColor(.secondary)
                    }
                }

                Toggle("Active (Published)", isOn: Binding(
                    get: { viewModel.card.status.lowercased() == "published" },
                    set: { newValue in viewModel.onSetStatus?(newValue) }
                ))
            } header: {
                Text("Agent Identity")
            } footer: {
                if viewModel.card.status.lowercased() == "published" {
                    Text("The handle is locked while the agent is published. Revert to draft to change it.")
                }
            }

            Section {
                ChatNativeAgentSecretCardRepresentable(
                    secret: viewModel.card.latestSecret,
                    hint: viewModel.card.secretHint,
                    isLoading: viewModel.isRotatingInvokeSecret,
                    isRevealed: viewModel.isInvokeSecretRevealed,
                    canReveal: viewModel.card.latestSecret != nil,
                    isDark: colorScheme == .dark,
                    onReveal: { viewModel.isInvokeSecretRevealed.toggle() },
                    onCopy: {
                        guard let secret = viewModel.card.latestSecret else { return }
                        viewModel.onCopy?(secret)
                    },
                    onRotate: { showRotateInvokeSecretConfirm = true }
                )
                .frame(minHeight: 190)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Invoke Secret")
            } footer: {
                Text(
                    viewModel.card.latestSecret != nil
                        ? "Shown once — copy it now. It cannot be viewed again after you leave this screen."
                        : "For security this can only be viewed right after it's created or rotated. Rotate to generate a new one."
                )
            }

            Section {
                NavigationLink(destination: ChatAgentModelPickerView(viewModel: viewModel)) {
                    HStack {
                        ChatAgentSettingsRowLabel(icon: "cpu", tint: .purple, title: "Model")
                        Spacer()
                        Text(modelSummary)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                NavigationLink(destination: ChatAgentPromptView(viewModel: viewModel)) {
                    HStack {
                        ChatAgentSettingsRowLabel(icon: "text.alignleft", tint: .blue, title: "System Prompt")
                        Spacer()
                        Text(promptSummary)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                NavigationLink(destination: ChatAgentToolsView(viewModel: viewModel)) {
                    HStack {
                        ChatAgentSettingsRowLabel(icon: "wrench.and.screwdriver.fill", tint: .orange, title: "Tools")
                        Spacer()
                        Text(toolsSummary)
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink(destination: ChatAgentPromptVariablesView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "curlybraces", tint: .teal, title: "Prompt Variables")
                }

                NavigationLink(destination: ChatAgentIntegrationView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "bolt.horizontal.circle.fill", tint: .indigo, title: "Integration & Delivery")
                }
                NavigationLink(destination: ChatAgentOutputSettingsView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "slider.horizontal.3", tint: .pink, title: "Output Controls")
                }
                NavigationLink(destination: ChatAgentVoiceSettingsView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "waveform", tint: .green, title: "Voice Settings")
                }
            } header: {
                Text("Configuration")
            }
        }
        .onAppear {
            draftName = viewModel.card.displayName
            guard !didLoadModelRegistry else { return }
            didLoadModelRegistry = true
            viewModel.onLoadModelRegistry? { registry in
                viewModel.modelRegistry = registry
            }
        }
        .onChange(of: viewModel.card) { newCard in
            if !isSavingName {
                draftName = newCard.displayName
            }
        }
        .alert("Rotate invoke secret?", isPresented: $showRotateInvokeSecretConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Rotate", role: .destructive) {
                viewModel.isRotatingInvokeSecret = true
                viewModel.onRotateInvokeSecret? { success, _, _ in
                    viewModel.isRotatingInvokeSecret = false
                    if success {
                        viewModel.isInvokeSecretRevealed = true
                    }
                }
            }
        } message: {
            Text("The current secret stops working immediately. Anything invoking this agent with it will need the new one.")
        }
    }

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != viewModel.card.displayName else { return }
        isSavingName = true
        viewModel.onRename?(trimmed) { success in
            isSavingName = false
            if !success {
                draftName = viewModel.card.displayName
            }
        }
    }
}

struct ChatAgentModelPickerView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel

    var body: some View {
        ChatProviderModelPickerView(
            registry: viewModel.modelRegistry,
            currentProviderId: viewModel.card.modelProvider ?? "anthropic",
            currentModelId: viewModel.card.modelId ?? "claude-haiku-4-5-20251001",
            currentThinkingLevel: nil
        ) { providerId, modelId, _, completion in
            // Standalone-agent persistence currently stores the provider/model pair.
            // The reusable picker still resolves thinking locally without inventing
            // a separate backend update contract here.
            viewModel.onSaveModelSelection?(providerId, modelId, completion)
        }
    }
}

/// Reusable server-registry-backed model/thinking picker. Provider is inferred
/// from the selected model and returned only as persistence/runtime metadata.
struct ChatProviderModelPickerView: View {
    let registry: ChatAgentModelRegistry
    let currentProviderId: String
    let currentModelId: String
    let currentThinkingLevel: String?
    let onSave: (String, String, String, @escaping (Bool) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProviderId = ""
    @State private var selectedModelId = ""
    @State private var selectedThinkingLevel = ""
    @State private var isSaving = false

    private var selectedProvider: ChatAgentModelProviderInfo? {
        registry.provider(id: selectedProviderId)
    }

    private var selectedModel: ChatAgentModelInfo? {
        registry.model(providerId: selectedProviderId, modelId: selectedModelId)
    }

    private var selectedCombinationIsValid: Bool {
        guard
            let provider = selectedProvider,
            provider.available,
            let model = selectedModel
        else {
            return false
        }
        return model.thinkingLevels.contains(selectedThinkingLevel)
    }

    private var isDirty: Bool {
        selectedProviderId.caseInsensitiveCompare(currentProviderId) != .orderedSame
            || selectedModelId.caseInsensitiveCompare(currentModelId) != .orderedSame
            || selectedThinkingLevel.caseInsensitiveCompare(resolvedCurrentThinkingLevel)
                != .orderedSame
    }

    private var resolvedCurrentThinkingLevel: String {
        let model =
            registry.model(providerId: currentProviderId, modelId: currentModelId)
            ?? ChatAgentModelRegistry.fallback.model(
                providerId: currentProviderId,
                modelId: currentModelId)
        guard let model else { return currentThinkingLevel ?? "medium" }
        if let currentThinkingLevel,
            let supported = model.thinkingLevels.first(where: {
                $0.caseInsensitiveCompare(currentThinkingLevel) == .orderedSame
            })
        {
            return supported
        }
        return model.defaultThinkingLevel
    }

    var body: some View {
        Form {
            Section {
                ForEach(registry.providers) { provider in
                    ForEach(provider.models) { model in
                        Button {
                            selectModel(model, from: provider)
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(model.name)
                                            .foregroundColor(provider.available ? .primary : .secondary)
                                        if model.recommended {
                                            Text("Recommended")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    Text(
                                        provider.available
                                            ? model.description
                                            : "Unavailable")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                if selectedProviderId == provider.id
                                    && selectedModelId == model.id
                                {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                }
                            }
                        }
                        .disabled(!provider.available)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                if registry.isFallback {
                    Text("Showing the built-in catalog while the live registry is unavailable. The server validates every selection.")
                }
            }

            Section {
                if let model = selectedModel {
                    ForEach(model.thinkingLevels, id: \.self) { level in
                        Button {
                            selectedThinkingLevel = level
                        } label: {
                            HStack {
                                Text(thinkingLevelTitle(level))
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedThinkingLevel == level {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                }
                            }
                        }
                    }
                } else {
                    Text("Select an available model first.")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Thinking")
            } footer: {
                Text("Higher levels spend more time reasoning before answering.")
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .presentationBackground(.ultraThinMaterial)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { saveSelection() }
                        .disabled(!isDirty || !selectedCombinationIsValid)
                }
            }
        }
        .onAppear {
            resolveSelection()
        }
        .onChange(of: registry) { _ in
            resolveSelection()
        }
    }

    private func resolveSelection() {
        if let currentProvider = registry.provider(id: currentProviderId),
            let currentModel = registry.model(
                providerId: currentProvider.id,
                modelId: currentModelId)
        {
            selectedProviderId = currentProvider.id
            selectedModelId = currentModel.id
            selectedThinkingLevel =
                currentModel.thinkingLevels.first(where: {
                    guard let currentThinkingLevel else { return false }
                    return $0.caseInsensitiveCompare(currentThinkingLevel) == .orderedSame
                })
                ?? currentModel.defaultThinkingLevel
            return
        }

        guard
            let fallbackProvider =
                registry.provider(id: registry.defaultProvider)
                ?? registry.providers.first(where: \.available)
                ?? registry.providers.first
        else {
            selectedProviderId = ""
            selectedModelId = ""
            selectedThinkingLevel = ""
            return
        }
        guard
            let fallbackModel =
                registry.model(
                    providerId: fallbackProvider.id,
                    modelId: registry.defaultModelId)
                ?? fallbackProvider.models.first(where: \.recommended)
                ?? fallbackProvider.models.first
        else {
            selectedProviderId = fallbackProvider.id
            selectedModelId = ""
            selectedThinkingLevel = ""
            return
        }
        selectModel(fallbackModel, from: fallbackProvider)
    }

    private func selectModel(
        _ model: ChatAgentModelInfo,
        from provider: ChatAgentModelProviderInfo
    ) {
        guard provider.available else { return }
        let previousThinkingLevel = selectedThinkingLevel
        selectedProviderId = provider.id
        selectedModelId = model.id
        selectedThinkingLevel =
            model.thinkingLevels.first(where: {
                $0.caseInsensitiveCompare(previousThinkingLevel) == .orderedSame
            })
            ?? model.defaultThinkingLevel
    }

    private func saveSelection() {
        guard selectedCombinationIsValid, !isSaving else { return }
        isSaving = true
        onSave(selectedProviderId, selectedModelId, selectedThinkingLevel) { success in
            isSaving = false
            if success {
                dismiss()
            }
        }
    }

    private func thinkingLevelTitle(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Circular agent avatar: remote image when available, gradient initial otherwise.
/// Bridges the SAME global avatar component the Chats home list and the Agents list use
/// (`ChatAvatarNodeView` — real photo, real per-identity gradient fallback, real image
/// cache) into SwiftUI, so an agent's avatar looks identical everywhere it appears instead
/// of this screen inventing its own one-off placeholder style.
struct ChatAgentGlobalAvatarView: UIViewRepresentable {
    let avatarUrl: String?
    let displayName: String
    let peerUserId: String?
    var size: CGFloat = 44
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> ChatAvatarNodeView {
        ChatAvatarNodeView()
    }

    func updateUIView(_ uiView: ChatAvatarNodeView, context: Context) {
        uiView.configure(
            with: ChatAvatarDescriptor(
                title: displayName,
                rawAvatarURI: avatarUrl,
                peerUserId: peerUserId,
                chatId: nil,
                kind: .standard,
                isGroup: false,
                members: [],
                preferPushAvatar: false,
                gradientColors: nil
            ),
            isDark: colorScheme == .dark,
            renderingSide: size
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatAvatarNodeView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// Inner page for editing the agent's system prompt.
struct ChatAgentPromptView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftPrompt: String = ""
    @State private var isSaving = false

    private var isDirty: Bool {
        draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            != (viewModel.card.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draftPrompt)
                    .frame(minHeight: 240)
            } header: {
                Text("System Prompt")
            } footer: {
                Text("Defines how the agent behaves and responds.")
            }
        }
        .navigationTitle("System Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { savePrompt() }
                        .disabled(!isDirty)
                }
            }
        }
        .onAppear { draftPrompt = viewModel.card.systemPrompt ?? "" }
    }

    private func savePrompt() {
        let trimmed = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        viewModel.onSavePrompt?(trimmed) { success in
            isSaving = false
            if success {
                dismiss()
            } else {
                draftPrompt = viewModel.card.systemPrompt ?? ""
            }
        }
    }
}

/// Inner page to change the agent handle with live availability checking.
struct ChatAgentUsernameView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var isChecking = false
    @State private var isSaving = false
    @State private var availability: Availability = .unknown
    @State private var debounceWork: DispatchWorkItem?

    private enum Availability: Equatable {
        case unknown
        case available
        case unavailable(String)
    }

    private var normalized: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }

    private var isUnchanged: Bool {
        normalized == (viewModel.card.username ?? "").lowercased()
    }

    private var published: Bool {
        viewModel.card.status.lowercased() == "published"
    }

    private var canSave: Bool {
        if published || isSaving || normalized.isEmpty || isUnchanged { return false }
        if case .available = availability { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("@")
                        .foregroundColor(.secondary)
                    TextField("handle", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .disabled(published)
                        .onChange(of: draft) { _ in scheduleCheck() }
                    statusIcon
                }
            } header: {
                Text("Handle")
            } footer: {
                footerText
            }
        }
        .navigationTitle("Handle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
        .onAppear { draft = viewModel.card.username ?? "" }
    }

    @ViewBuilder private var statusIcon: some View {
        if isChecking {
            ProgressView().controlSize(.small)
        } else if isUnchanged || normalized.isEmpty {
            EmptyView()
        } else {
            switch availability {
            case .available:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .unavailable:
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
            case .unknown:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var footerText: some View {
        if published {
            Text("The handle is locked while the agent is published. Revert to draft to change it.")
        } else if isUnchanged || normalized.isEmpty {
            Text("3–30 characters: lowercase letters, numbers, and underscores.")
        } else {
            switch availability {
            case .available:
                Text("@\(normalized) is available.").foregroundColor(.green)
            case .unavailable(let reason):
                Text(Self.message(for: reason)).foregroundColor(.red)
            case .unknown:
                Text("3–30 characters: lowercase letters, numbers, and underscores.")
            }
        }
    }

    private func scheduleCheck() {
        debounceWork?.cancel()
        availability = .unknown
        guard !normalized.isEmpty, !isUnchanged, !published else {
            isChecking = false
            return
        }
        let work = DispatchWorkItem { runCheck() }
        debounceWork = work
        isChecking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func runCheck() {
        let candidate = normalized
        viewModel.onCheckUsername?(candidate) { available, reason in
            guard candidate == normalized else { return }
            isChecking = false
            availability = available ? .available : .unavailable(reason ?? "unavailable")
        }
    }

    private func save() {
        isSaving = true
        viewModel.onSaveUsername?(normalized) { success, errorMessage in
            isSaving = false
            if success {
                dismiss()
            } else if let errorMessage {
                availability = .unavailable(errorMessage)
            }
        }
    }

    static func message(for reason: String) -> String {
        switch reason {
        case "username_taken": return "That handle is already taken."
        case "reserved_username": return "That handle is reserved."
        case "invalid_username": return "Use 3–30 lowercase letters, numbers, or underscores."
        case "username_locked_after_publish": return "Handle is locked while published."
        default: return reason
        }
    }
}

/// Inner page to grant/revoke the agent's tools.
struct ChatAgentToolsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var tools: [ChatAgentToolInfo] = []
    @State private var enabled: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false

    private var isDirty: Bool {
        enabled != Set(viewModel.card.enabledTools)
    }

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                Section {
                    ForEach(tools) { tool in
                        Toggle(isOn: Binding(
                            get: { enabled.contains(tool.id) },
                            set: { on in
                                if on { enabled.insert(tool.id) } else { enabled.remove(tool.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                Text(tool.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("Choose which capabilities this agent can use.")
                }
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }.disabled(!isDirty)
                }
            }
        }
        .onAppear {
            enabled = Set(viewModel.card.enabledTools)
            loadTools()
        }
    }

    private func loadTools() {
        guard let loader = viewModel.onLoadToolRegistry else {
            isLoading = false
            return
        }
        loader { loaded in
            tools = loaded
            isLoading = false
        }
    }

    private func save() {
        isSaving = true
        viewModel.onSaveTools?(Array(enabled)) { success in
            isSaving = false
            if success { dismiss() }
        }
    }
}

struct ChatAgentPromptVariablesView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var variables: [ChatAgentPromptVariable] = []
    @State private var original: [ChatAgentPromptVariable] = []
    @State private var isLoading = true
    @State private var isSaving = false

    private var isDirty: Bool { variables != original }

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } else if variables.isEmpty {
                Section {
                    Text("No prompt variables yet. Add {{variable}} placeholders in your system prompt, then define their values here so you can change wording without rewriting the prompt.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach($variables) { $variable in
                    Section {
                        if variable.locked {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("{{\(variable.name)}}").font(.subheadline.monospaced())
                                    Text(variable.value.isEmpty ? "—" : variable.value)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "lock.fill").foregroundColor(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("{{\(variable.name)}}").font(.subheadline.monospaced())
                                TextField("Value", text: $variable.value)
                            }
                        }
                    } footer: {
                        if !variable.description.isEmpty {
                            Text(variable.locked ? "\(variable.description) · pinned in code" : variable.description)
                        } else if variable.locked {
                            Text("Pinned in code")
                        }
                    }
                }
            }
        }
        .navigationTitle("Prompt Variables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }.disabled(!isDirty)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let loader = viewModel.onLoadPromptVariables else {
            isLoading = false
            return
        }
        loader { loaded in
            variables = loaded
            original = loaded
            isLoading = false
        }
    }

    private func save() {
        isSaving = true
        viewModel.onSavePromptVariables?(variables) { success in
            isSaving = false
            if success { dismiss() }
        }
    }
}

struct ChatAgentIntegrationView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var inboxMode: String = "per_event"
    @State private var incomingChatEnabled: Bool = true
    
    var body: some View {
        Form {
            Section {
                copyableRow(title: "API Base", value: viewModel.card.apiBaseURL)
                copyableRow(title: "Events URL", value: viewModel.card.eventsURL)
                copyableRow(title: "Invoke URL", value: viewModel.card.invokeURL)
                copyableRow(title: "Callback URL", value: viewModel.card.callbackURL)
            } header: {
                Text("Endpoints")
            }
            
            Section {
                copyableRow(title: "Default Chat", value: viewModel.card.defaultDestinationChat?.chatId)
                ForEach(viewModel.card.attachedChats, id: \.chatId) { chat in
                    copyableRow(title: "Attached Chat", value: chat.chatId)
                }
            } header: {
                Text("Delivery Channels")
            }
            
            Section {
                Picker("Inbox Mode", selection: $inboxMode) {
                    Text("Per Event").tag("per_event")
                    Text("Batched Summary").tag("batched_summary")
                }
                .onChange(of: inboxMode) { newValue in
                    // Call backend later
                    viewModel.onToast?("Inbox mode set to \(newValue == "batched_summary" ? "Batched" : "Per Event")")
                }

                Toggle("Accept Incoming Chat", isOn: $incomingChatEnabled)
            } header: {
                Text("Settings")
            }

            Section {
                HStack {
                    Text("Webhook Signing Secret")
                    Spacer()
                    if viewModel.isLoadingWebhookSecret {
                        ProgressView().controlSize(.small)
                    } else if viewModel.isWebhookSecretRevealed, let secret = viewModel.webhookSecret {
                        Text(secret)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(maskedWebhookSecret)
                            .foregroundColor(.secondary)
                    }

                    Button(action: toggleWebhookSecretRevealed) {
                        Image(systemName: viewModel.isWebhookSecretRevealed ? "eye.slash.fill" : "eye.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoadingWebhookSecret)

                    if viewModel.isWebhookSecretRevealed, let secret = viewModel.webhookSecret {
                        Button(action: {
                            viewModel.onCopy?(secret)
                            viewModel.onToast?("Copied webhook signing secret")
                        }) {
                            Image(systemName: "square.on.square")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Webhook Signing Secret")
            } footer: {
                Text("Verifies inbound webhook signatures. This is separate from the invoke secret used to call your agent, and can be viewed anytime.")
            }
        }
        .navigationTitle("Integration & Delivery")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            inboxMode = viewModel.card.eventInboxMode
            incomingChatEnabled = viewModel.card.incomingChatEnabled
        }
    }

    private var maskedWebhookSecret: String {
        let hint = viewModel.webhookSecretHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (hint?.isEmpty == false) ? "•••• \(hint!)" : "Tap to reveal"
    }

    private func toggleWebhookSecretRevealed() {
        if viewModel.isWebhookSecretRevealed {
            viewModel.isWebhookSecretRevealed = false
            return
        }
        if viewModel.webhookSecret != nil {
            viewModel.isWebhookSecretRevealed = true
            return
        }
        viewModel.isLoadingWebhookSecret = true
        viewModel.onLoadWebhookSecret? { secret, hint in
            viewModel.isLoadingWebhookSecret = false
            viewModel.webhookSecret = secret
            if let hint {
                viewModel.webhookSecretHint = hint
            }
            viewModel.isWebhookSecretRevealed = secret != nil
            if secret == nil {
                viewModel.onToast?("Could not load webhook secret")
            }
        }
    }

    private func copyableRow(title: String, value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value ?? "Not set")
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let value = value, !value.isEmpty {
                Button(action: {
                    viewModel.onCopy?(value)
                    viewModel.onToast?("Copied \(title)")
                }) {
                    Image(systemName: "square.on.square")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ChatAgentOutputSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var enableText = true
    @State private var enableMessages = true
    @State private var enableMedia = false
    @State private var enableVoice = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Text Output", isOn: $enableText)
                Toggle("Messages", isOn: $enableMessages)
                Toggle("Media Generation", isOn: $enableMedia)
                Toggle("Voice Output", isOn: $enableVoice)
            } header: {
                Text("Allowed Modalities")
            } footer: {
                Text("Control what modalities the agent is permitted to return. Backend sync to be added.")
            }
        }
        .navigationTitle("Output Controls")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let modes = viewModel.card.outputModes
            enableText = modes.contains("text") || modes.isEmpty // default
            enableMessages = modes.contains("messages") || modes.isEmpty
            enableMedia = modes.contains("media")
            enableVoice = modes.contains("voice")
        }
    }
}

private struct ChatAgentVoiceProviderOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
}

private let chatAgentVoiceProviderOptions: [ChatAgentVoiceProviderOption] = [
    ChatAgentVoiceProviderOption(
        id: "google",
        title: "Google",
        subtitle: "Gemini TTS — natural, steerable voices in 70+ languages.",
        icon: "waveform",
        tint: .blue
    ),
    ChatAgentVoiceProviderOption(
        id: "openai_realtime",
        title: "OpenAI Realtime",
        subtitle: "Low-latency, live spoken conversation — not the older OpenAI TTS API.",
        icon: "waveform.badge.mic",
        tint: .green
    ),
]

struct ChatAgentVoiceSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                ForEach(chatAgentVoiceProviderOptions) { option in
                    Button {
                        select(option)
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(option.tint.gradient)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Image(systemName: option.icon)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .foregroundColor(.primary)
                                Text(option.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if viewModel.card.voiceProvider == option.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .disabled(isSaving)
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("Which speech engine this agent uses when it talks back with voice.")
            }
        }
        .navigationTitle("Voice Settings")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isSaving {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func select(_ option: ChatAgentVoiceProviderOption) {
        guard viewModel.card.voiceProvider != option.id else { return }
        isSaving = true
        viewModel.onSaveVoiceProvider?(option.id) { _ in
            isSaving = false
        }
    }
}

// MARK: - Group VoIP / AI agent configuration sheet
// Presented as a pageSheet (same API as AgentBridgeHistorySheet / connect sheets):
// summary root + inner NavigationLink pushes — not one long full-screen form.

final class GroupAgentConfigModel: ObservableObject {
  let chatId: String
  let existingId: Any?
  let documents: [(id: String, name: String, url: String)]

  @Published var name: String
  @Published var systemPrompt: String
  @Published var enabled: Bool
  @Published var enabledTools: Set<String>
  @Published var generateInput: String = ""
  @Published var isGenerating = false
  @Published var errorMessage: String?

  var onSave: (([String: Any]) -> Void)?
  var onDelete: (() -> Void)?

  static let toolOptions: [(id: String, title: String, subtitle: String)] = [
    ("search_google", "Web Search", "Search Google for up-to-date results"),
    ("analyze_image", "Image Analysis", "Understand images and OCR text"),
    ("analyze_document", "Document Analysis", "Read and summarize document files"),
    ("create_document", "Create Document", "Generate formatted document drafts"),
  ]

  init(
    chatId: String,
    config: [String: Any]?,
    documents: [(id: String, name: String, url: String)] = []
  ) {
    self.chatId = chatId
    self.existingId = config?["id"]
    self.documents = documents
    self.name = (config?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let snake = (config?["system_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let camel = (config?["systemPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.systemPrompt = snake.isEmpty ? camel : snake
    if let raw = config?["enabled"] as? Bool {
      self.enabled = raw
    } else if let n = config?["enabled"] as? NSNumber {
      self.enabled = n.boolValue
    } else {
      self.enabled = true
    }
    let tools =
      Self.parseTools(config?["enabled_tools"])
      ?? Self.parseTools(config?["enabledTools"])
      ?? ["search_google", "analyze_image", "analyze_document", "create_document"]
    self.enabledTools = Set(tools)
  }

  var isExisting: Bool { existingId != nil }

  var promptSummary: String {
    let p = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return p.isEmpty ? "Not set" : p
  }

  var toolsSummary: String {
    switch enabledTools.count {
    case 0: return "None"
    case 1: return "1 tool"
    default: return "\(enabledTools.count) tools"
    }
  }

  func buildConfig() -> [String: Any]? {
    let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      errorMessage = "System prompt is required."
      return nil
    }
    guard !enabledTools.isEmpty else {
      errorMessage = "Enable at least one tool."
      return nil
    }
    errorMessage = nil
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var config: [String: Any] = [
      "chat_id": chatId,
      "name": trimmedName.isEmpty ? "Vibe AI" : trimmedName,
      "system_prompt": prompt,
      "enabled": enabled,
      "enabled_tools": Array(enabledTools).sorted(),
    ]
    if let existingId {
      config["id"] = existingId
    }
    return config
  }

  func generatePrompt(completion: @escaping (Bool) -> Void) {
    let input = generateInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else {
      errorMessage = "Describe the agent first."
      completion(false)
      return
    }
    guard !enabledTools.isEmpty else {
      errorMessage = "Enable at least one tool before generating."
      completion(false)
      return
    }
    isGenerating = true
    errorMessage = nil
    ChatEngine.shared.generateAgentPrompt(
      chatId: chatId,
      input: input,
      enabledTools: Array(enabledTools)
    ) { [weak self] payload in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isGenerating = false
        let generated =
          (payload?["systemPrompt"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !generated.isEmpty else {
          self.errorMessage = "Could not generate a prompt. Try adjusting your input."
          completion(false)
          return
        }
        self.systemPrompt = generated
        completion(true)
      }
    }
  }

  private static func parseTools(_ raw: Any?) -> [String]? {
    guard let list = raw as? [Any] else { return nil }
    let out = list.compactMap { item -> String? in
      if let s = item as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
      }
      if let n = item as? NSNumber { return n.stringValue }
      return nil
    }
    return out.isEmpty ? nil : out
  }
}

/// Clean pageSheet for group agent config — summary + inner pushes.
struct GroupAgentConfigSheet: View {
  @StateObject var model: GroupAgentConfigModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var showDeleteConfirm = false

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  /// Soft elevated row over glass — mirrors ask/progress sheet `neutralFill`.
  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }
  private var accentTint: Color { palette.text }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            Text("Name")
              .font(.system(size: 16, weight: .regular))
              .foregroundStyle(palette.text)
            Spacer(minLength: 12)
            TextField("Vibe AI", text: $model.name)
              .multilineTextAlignment(.trailing)
              .foregroundStyle(palette.secondaryText)
          }
          .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
          .listRowBackground(rowFill)

          Toggle("Agent Enabled", isOn: $model.enabled)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .listRowBackground(rowFill)
        } header: {
          Text("Agent")
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(palette.secondaryText)
        } footer: {
          Text("When enabled, the agent can participate in this group chat.")
            .foregroundStyle(palette.secondaryText)
        }

        Section {
          NavigationLink {
            GroupAgentPromptEditor(model: model)
          } label: {
            configRow(title: "System Prompt", value: model.promptSummary)
          }
          .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
          .listRowBackground(rowFill)

          NavigationLink {
            GroupAgentToolsEditor(model: model)
          } label: {
            configRow(title: "Tools", value: model.toolsSummary)
          }
          .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
          .listRowBackground(rowFill)

          if !model.documents.isEmpty {
            NavigationLink {
              GroupAgentDocumentsView(documents: model.documents)
            } label: {
              configRow(title: "Documents", value: "\(model.documents.count)")
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .listRowBackground(rowFill)
          }
        } header: {
          Text("Configuration")
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(palette.secondaryText)
        }

        if model.isExisting {
          Section {
            Button("Remove Agent", role: .destructive) {
              showDeleteConfirm = true
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .listRowBackground(rowFill)
          }
        }

        if let errorMessage = model.errorMessage {
          Section {
            Text(errorMessage)
              .font(.system(size: 13))
              .foregroundStyle(.red)
              .listRowBackground(rowFill)
          }
        }
      }
      .listStyle(.insetGrouped)
      // Glass sheet body like chat progress/ask sheets — no solid fill.
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .navigationTitle("Vibe AI")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .tint(accentTint)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .semibold))
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(model.isExisting ? "Save" : "Create") {
            guard let config = model.buildConfig() else { return }
            model.onSave?(config)
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .confirmationDialog(
        "Remove AI Agent",
        isPresented: $showDeleteConfirm,
        titleVisibility: .visible
      ) {
        Button("Remove", role: .destructive) {
          model.onDelete?()
          dismiss()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This removes the agent and clears its memory. This cannot be undone.")
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    // Let the system pageSheet Liquid Glass show through (same as ask/progress sheets).
    .presentationBackground(.clear)
  }

  @ViewBuilder
  private func configRow(title: String, value: String) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(palette.text)
      Spacer(minLength: 12)
      Text(value)
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
    }
  }
}

private struct GroupAgentPromptEditor: View {
  @ObservedObject var model: GroupAgentConfigModel
  @Environment(\.colorScheme) private var colorScheme

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }

  var body: some View {
    Form {
      Section {
        TextField("e.g. Helpful PM for sprint planning", text: $model.generateInput)
          .listRowBackground(rowFill)
        Button {
          model.generatePrompt { _ in }
        } label: {
          HStack {
            if model.isGenerating {
              ProgressView().controlSize(.small)
            }
            Text(model.isGenerating ? "Generating…" : "Generate from input")
          }
        }
        .disabled(model.isGenerating)
        .listRowBackground(rowFill)
      } header: {
        Text("Generate")
      } footer: {
        Text("Optional: describe the agent, then generate a system prompt.")
      }

      Section {
        TextEditor(text: $model.systemPrompt)
          .frame(minHeight: 220)
          .listRowBackground(rowFill)
      } header: {
        Text("System Prompt")
      } footer: {
        Text("Describe how this agent should behave in the group.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("System Prompt")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}

private struct GroupAgentToolsEditor: View {
  @ObservedObject var model: GroupAgentConfigModel
  @Environment(\.colorScheme) private var colorScheme

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }

  var body: some View {
    List {
      Section {
        ForEach(GroupAgentConfigModel.toolOptions, id: \.id) { option in
          Toggle(isOn: Binding(
            get: { model.enabledTools.contains(option.id) },
            set: { on in
              if on {
                model.enabledTools.insert(option.id)
              } else {
                model.enabledTools.remove(option.id)
              }
            }
          )) {
            VStack(alignment: .leading, spacing: 2) {
              Text(option.title)
              Text(option.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
          }
          .listRowBackground(rowFill)
        }
      } header: {
        Text("Enabled Tools")
      } footer: {
        Text("At least one tool is required.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Tools")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}

private struct GroupAgentDocumentsView: View {
  let documents: [(id: String, name: String, url: String)]
  @Environment(\.colorScheme) private var colorScheme

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }

  var body: some View {
    List {
      Section {
        ForEach(documents, id: \.id) { doc in
          Button {
            let cleaned = doc.url.replacingOccurrences(of: "vibe://", with: "https://")
            if let url = URL(string: cleaned) {
              UIApplication.shared.open(url)
            }
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "doc.text.fill")
                .foregroundStyle(.tint)
              Text(doc.name)
                .foregroundStyle(.primary)
              Spacer()
              Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
          }
          .listRowBackground(rowFill)
        }
      } header: {
        Text("Agent Documents")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Documents")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}
