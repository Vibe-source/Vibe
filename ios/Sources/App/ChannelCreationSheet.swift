import SwiftUI
import PhotosUI

/// Telegram-style multi-step channel creation:
/// identity → channel type/policy → people & agents → create.
/// Calls `onCreated(route)` only; does not push. Parent dismisses and routes.
struct ChannelCreationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var coordinator: AppShellCoordinator

  let config: AppSessionConfig
  /// Optional home-list seeds for the people picker (lead may pass visible rows).
  var homeRows: [ChatHomeListRow] = []
  /// Optional affordance for "Create an agent" — lead wires navigation.
  var onCreateAgent: (() -> Void)? = nil
  let onCreated: (ChatRoute) -> Void

  enum Step: Hashable {
    case typePolicy
    case people
  }

  @State private var path = NavigationPath()

  // Identity
  @State private var channelName = ""
  @State private var channelDescription = ""
  @State private var avatarItem: PhotosPickerItem?
  @State private var avatarImage: Image?
  @State private var avatarData: Data?

  // Type / policy
  @State private var isPublic = false
  @State private var publicSlug = ""
  @State private var slugManuallyEdited = false
  @State private var joinApprovalRequired = false
  @State private var restrictSavingContent = false

  // People & agents
  @State private var selectedSubscribers = Set<ContactSearchUser>()
  @State private var selectedAgentAdmins = Set<ContactSearchUser>()
  @State private var searchQuery = ""
  @State private var isSearchPresented = false
  @State private var searchResults: [ContactSearchUser] = []
  @State private var isSearching = false
  @State private var searchTask: Task<Void, Never>?

  @State private var isCreating = false
  @State private var errorMessage: String?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var trimmedName: String {
    channelName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedDescription: String {
    channelDescription.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var normalizedSlug: String {
    Self.normalizePublicSlug(publicSlug)
  }

  private var slugIsValid: Bool {
    guard isPublic else { return true }
    let slug = normalizedSlug
    guard slug.count >= 5, slug.count <= 32 else { return false }
    // Must start with a letter; only a–z, 0–9, underscore.
    guard let first = slug.first, first.isLetter else { return false }
    return slug.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
  }

  private var canProceedFromIdentity: Bool {
    !trimmedName.isEmpty
  }

  private var canProceedFromType: Bool {
    slugIsValid
  }

  var body: some View {
    NavigationStack(path: $path) {
      identityStepView
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("New Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { dismiss() }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Next") {
              if !slugManuallyEdited {
                publicSlug = Self.normalizePublicSlug(trimmedName)
              }
              path.append(Step.typePolicy)
            }
            .disabled(!canProceedFromIdentity)
          }
        }
        .navigationDestination(for: Step.self) { step in
          switch step {
          case .typePolicy:
            typePolicyStepView
              .background(palette.background.ignoresSafeArea())
              .navigationTitle("Channel Type")
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                  Button("Next") {
                    path.append(Step.people)
                  }
                  .disabled(!canProceedFromType)
                }
              }
          case .people:
            peopleStepView
              .background(palette.background.ignoresSafeArea())
              .navigationTitle("Add Subscribers")
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                  Button("Create") {
                    Task { await createChannel() }
                  }
                  .disabled(isCreating)
                }
              }
          }
        }
        .onChange(of: avatarItem) { _, newItem in
          Task {
            guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
            guard let uiImage = UIImage(data: data) else { return }
            self.avatarData = data
            self.avatarImage = Image(uiImage: uiImage)
          }
        }
        .overlay {
          if isCreating {
            ZStack {
              Color.black.opacity(0.3).ignoresSafeArea()
              ProgressView()
                .padding()
                .background(palette.card)
                .cornerRadius(8)
            }
          }
        }
    }
  }

  // MARK: - Step 1: Identity

  private var identityStepView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Set a name and photo for your channel. You can always change these later.")
          .font(.subheadline)
          .foregroundStyle(palette.secondaryText)
          .padding(.horizontal)
          .padding(.top)

        VStack(spacing: 0) {
          HStack(spacing: 16) {
            PhotosPicker(selection: $avatarItem, matching: .images) {
              if let avatarImage {
                avatarImage
                  .resizable()
                  .scaledToFill()
                  .frame(width: 56, height: 56)
                  .clipShape(Circle())
              } else {
                Image(systemName: "camera.fill")
                  .font(.title2)
                  .foregroundStyle(palette.accent)
                  .frame(width: 56, height: 56)
                  .background(palette.accent.opacity(0.12))
                  .clipShape(Circle())
              }
            }
            .buttonStyle(.plain)

            TextField("Channel name", text: $channelName)
              .font(.body)
              .submitLabel(.next)
          }
          .padding()

          Divider().padding(.leading, 16)

          TextField("Description (optional)", text: $channelDescription, axis: .vertical)
            .font(.body)
            .lineLimit(3...6)
            .padding()
        }
        .background(palette.card)
        .cornerRadius(12)
        .padding(.horizontal)

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(.horizontal)
        }

        Spacer(minLength: 24)
      }
    }
  }

  // MARK: - Step 2: Type & policy

  private var typePolicyStepView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Choose who can find and join this channel.")
          .font(.subheadline)
          .foregroundStyle(palette.secondaryText)
          .padding(.horizontal)
          .padding(.top)

        VStack(spacing: 0) {
          channelTypeRow(
            title: "Private Channel",
            subtitle: "Only invited people can join via a revocable invite link.",
            selected: !isPublic
          ) {
            isPublic = false
          }
          Divider().padding(.leading, 56)
          channelTypeRow(
            title: "Public Channel",
            subtitle: "Anyone can find this channel with a public link.",
            selected: isPublic
          ) {
            isPublic = true
            if !slugManuallyEdited {
              publicSlug = Self.normalizePublicSlug(trimmedName)
            }
          }
        }
        .background(palette.card)
        .cornerRadius(12)
        .padding(.horizontal)

        if isPublic {
          VStack(alignment: .leading, spacing: 8) {
            Text("Public link")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(palette.text)
              .padding(.horizontal)

            HStack(spacing: 0) {
              // Never hardcode the host: it follows the server's share base.
              Text("\(VibeShareLinks.display(VibeShareLinks.baseURLString) ?? "vibegram.io")/r/")
                .font(.body)
                .foregroundStyle(palette.secondaryText)
              TextField("channel_name", text: $publicSlug)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: publicSlug) { _, newValue in
                  slugManuallyEdited = true
                  let normalized = Self.normalizePublicSlug(newValue)
                  if normalized != newValue {
                    publicSlug = normalized
                  }
                }
            }
            .padding()
            .background(palette.card)
            .cornerRadius(12)
            .padding(.horizontal)

            Text(slugGuidanceText)
              .font(.caption)
              .foregroundStyle(slugIsValid ? palette.secondaryText : Color.red.opacity(0.9))
              .padding(.horizontal)
          }
        } else {
          Text("A revocable invite link is generated when the channel is created. You can rotate or revoke it later from channel settings.")
            .font(.footnote)
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal)
        }

        VStack(spacing: 0) {
          Toggle(isOn: $joinApprovalRequired) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Approve new subscribers")
                .font(.body)
              Text("Join requests need your approval.")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            }
          }
          .padding()
          .tint(palette.accent)

          Divider().padding(.leading, 16)

          Toggle(isOn: $restrictSavingContent) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Restrict saving content")
                .font(.body)
              Text("Limit saving, forwarding, and screenshots where supported.")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            }
          }
          .padding()
          .tint(palette.accent)
        }
        .background(palette.card)
        .cornerRadius(12)
        .padding(.horizontal)

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(.horizontal)
        }

        Spacer(minLength: 24)
      }
    }
  }

  private var slugGuidanceText: String {
    if normalizedSlug.isEmpty {
      return "5–32 characters: letters, numbers, underscore. Must start with a letter."
    }
    if !slugIsValid {
      return "Use 5–32 characters: a–z, 0–9, underscore only. Must start with a letter."
    }
    return "People can open this channel at vibegram.io/r/\(normalizedSlug)"
  }

  private func channelTypeRow(
    title: String,
    subtitle: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(selected ? palette.accent : palette.secondaryText)
          .frame(width: 28)
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.body.weight(.medium))
            .foregroundStyle(palette.text)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding()
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Step 3: People & agents

  private var peopleStepView: some View {
    VStack(spacing: 0) {
      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding()
      }

      List {
        Section {
          Button {
            onCreateAgent?()
          } label: {
            HStack(spacing: 14) {
              Image(systemName: "plus.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(palette.accent)
              VStack(alignment: .leading, spacing: 2) {
                Text("Create an agent")
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundStyle(palette.accent)
                Text("Add a new standalone agent as channel admin")
                  .font(.caption)
                  .foregroundStyle(palette.secondaryText)
              }
              Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowBackground(Color.clear)
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
          if isSearching {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
            .listRowBackground(Color.clear)
          } else if searchResults.isEmpty {
            Text("No users found.")
              .foregroundStyle(palette.secondaryText)
              .listRowBackground(Color.clear)
          } else {
            groupedUsersSection(users: searchResults)
          }
        } else {
          let seeds = homeRows.compactMap(contactUser(for:))
          if seeds.isEmpty {
            Section {
              Text("Search for people to invite as subscribers, or agents to add as admins.")
                .font(.system(size: 14))
                .foregroundStyle(palette.secondaryText)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
          } else {
            groupedUsersSection(users: seeds)
          }
        }
      }
      .listStyle(.plain)
      .searchable(
        text: $searchQuery,
        isPresented: $isSearchPresented,
        placement: .navigationBarDrawer(displayMode: .automatic),
        prompt: "Search people or agents..."
      )
      .onChange(of: searchQuery) { _, newValue in
        scheduleSearch(query: newValue)
      }
    }
  }

  private func contactUser(for row: ChatHomeListRow) -> ContactSearchUser? {
    ContactSearchUser(payload: [
      "userId": row.peerUserId ?? row.chatId,
      "username": row.title,
      "profileImage": row.avatarUri ?? "",
      "isAgent": row.isBuiltInAgentSurface || row.isBridgeAgentSurface || row.isAgentFriend,
      "agentId": row.peerAgentId ?? "",
      "tier": row.isGoldTier ? "gold" : "free",
    ])
  }

  private func groupedUsersSection(users: [ContactSearchUser]) -> some View {
    var uniqueUsers: [ContactSearchUser] = []
    var seenIDs = Set<String>()
    for user in users {
      if !seenIDs.contains(user.userID) {
        seenIDs.insert(user.userID)
        uniqueUsers.append(user)
      }
    }
    let grouped = Dictionary(grouping: uniqueUsers) { user in
      String(user.username.prefix(1)).uppercased()
    }
    let sortedKeys = grouped.keys.sorted()

    return ForEach(sortedKeys, id: \.self) { letter in
      Section(letter) {
        ForEach(grouped[letter] ?? [], id: \.userID) { user in
          personOrAgentRow(user: user)
        }
      }
    }
  }

  @ViewBuilder
  private func personOrAgentRow(user: ContactSearchUser) -> some View {
    let isAgentAdminCandidate = isStandaloneAgent(user)
    let isSelected =
      isAgentAdminCandidate
      ? selectedAgentAdmins.contains(user)
      : selectedSubscribers.contains(user)

    Button {
      if isAgentAdminCandidate {
        if isSelected {
          selectedAgentAdmins.remove(user)
        } else {
          selectedAgentAdmins.insert(user)
        }
      } else {
        if isSelected {
          selectedSubscribers.remove(user)
        } else {
          selectedSubscribers.insert(user)
        }
      }
    } label: {
      HStack(spacing: 12) {
        ContactSearchResultRow(user: user, isSaved: isSelected, palette: palette)
      }
      .overlay(alignment: .topTrailing) {
        if isAgentAdminCandidate {
          Text("Agent admin")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(palette.accent.opacity(0.12))
            .clipShape(Capsule())
            .padding(.trailing, 48)
            .padding(.top, 14)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Standalone agents (non-nil `agentId`) become channel agent admins.
  private func isStandaloneAgent(_ user: ContactSearchUser) -> Bool {
    guard let agentId = user.agentId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return false
    }
    return !agentId.isEmpty
  }

  private func scheduleSearch(query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }

    isSearching = true
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      if Task.isCancelled { return }

      do {
        let results = try await ContactSearchService.search(config: config, query: trimmed)
        if !Task.isCancelled {
          self.searchResults = results
          self.isSearching = false
        }
      } catch {
        if !Task.isCancelled {
          self.searchResults = []
          self.isSearching = false
        }
      }
    }
  }

  // MARK: - Create

  @MainActor
  private func createChannel() async {
    isCreating = true
    errorMessage = nil
    defer { isCreating = false }

    do {
      var remoteAvatarUrl: String? = nil
      if let avatarData {
        remoteAvatarUrl = try await ChatRoomCreateService.uploadAvatar(
          imageData: avatarData, config: config)
      }

      let humanIds = selectedSubscribers.map(\.userID)
      let agentAdminIds = selectedAgentAdmins.compactMap { user -> String? in
        let id = user.agentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
      }
      let accessType = isPublic ? "public" : "private"
      let slug = isPublic ? normalizedSlug : nil
      let descriptionPayload: String? = trimmedDescription.isEmpty ? nil : trimmedDescription

      let result = try await ChatRoomCreateService.create(
        kind: .channel,
        config: config,
        name: trimmedName,
        description: descriptionPayload,
        memberIds: humanIds,
        agentAdminIds: agentAdminIds,
        avatarUrl: remoteAvatarUrl,
        accessType: accessType,
        publicSlug: slug,
        joinApprovalRequired: joinApprovalRequired,
        restrictSavingContent: restrictSavingContent
      )

      let route = buildRoute(from: result, remoteAvatarUrl: remoteAvatarUrl)
      onCreated(route)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Build route from create result canonical fields; fall back to local selection
  /// when response members are absent.
  private func buildRoute(from result: ChatRoomCreateResult, remoteAvatarUrl: String?) -> ChatRoute {
    let ownMember: [String: Any] = [
      "userId": config.userID,
      "name": config.name ?? config.username ?? "You",
      "role": "owner",
    ]

    let localHumanMembers: [[String: Any]] = selectedSubscribers.map {
      [
        "userId": $0.userID,
        "name": $0.username,
        "role": "subscriber",
      ]
    }
    let localAgentMembers: [[String: Any]] = selectedAgentAdmins.map { user in
      var entry: [String: Any] = [
        "userId": user.userID,
        "name": user.username,
        "role": "agent_admin",
      ]
      if let agentId = user.agentId, !agentId.isEmpty {
        entry["agentId"] = agentId
      }
      return entry
    }
    let localFallback = [ownMember] + localHumanMembers + localAgentMembers

    // Prefer server-returned members when the expanded result ships them.
    let members: [[String: Any]] = {
      let fromResult = result.members
      if !fromResult.isEmpty { return fromResult }
      return localFallback
    }()

    let avatar = result.avatarUrl ?? remoteAvatarUrl
    let role = result.role ?? "owner"

    return ChatRoute(
      chatId: result.chatID,
      title: result.name,
      peerUserId: nil,
      avatarURI: avatar,
      isGroup: true,
      isChannel: true,
      myRole: role,
      initialRows: [],
      members: members,
      roomDescription: result.roomDescription ?? (trimmedDescription.isEmpty ? nil : trimmedDescription),
      accessType: result.accessType,
      publicSlug: result.publicSlug ?? (isPublic ? normalizedSlug : nil),
      shareLink: result.shareLink,
      joinApprovalRequired: result.joinApprovalRequired,
      restrictSavingContent: result.restrictSavingContent,
      memberCount: result.memberCount ?? members.count,
      createdAt: result.createdAt
    )
  }

  // MARK: - Helpers

  static func normalizePublicSlug(_ raw: String) -> String {
    let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var out = ""
    out.reserveCapacity(lowered.count)
    for ch in lowered {
      if ch.isLetter || ch.isNumber || ch == "_" {
        out.append(ch)
      } else if ch == " " || ch == "-" {
        out.append("_")
      }
    }
    // Collapse repeated underscores.
    while out.contains("__") {
      out = out.replacingOccurrences(of: "__", with: "_")
    }
    return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
  }
}
