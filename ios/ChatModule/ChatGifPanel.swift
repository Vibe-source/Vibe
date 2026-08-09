import UIKit

#if canImport(GiphyUISDK)
    import GiphyUISDK
#endif

final class ChatGifPanelConfig {
    static let shared = ChatGifPanelConfig()

    private init() {}

    /// Giphy API key. Loaded from (first match wins):
    /// 1) process env `GIPHY_API_KEY`
    /// 2) Info.plist `GIPHY_API_KEY`
    /// 3) same public demo key the web client uses (fetch still works offline-dev)
    var apiKey: String = ChatGifPanelConfig.resolveApiKey()

    /// Re-read env/plist (call at launch so scheme env overrides apply).
    func reloadFromEnvironment() {
        apiKey = Self.resolveApiKey()
        let n = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count
        NSLog("[NativeGif][iOS] apiKey reloaded length=%d", n)
    }

    private static func resolveApiKey() -> String {
        if let env = ProcessInfo.processInfo.environment["GIPHY_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty
        {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "GIPHY_API_KEY") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // Public demo key used by client/src/components/GifPicker.tsx
        return "sXpGFDGZs0Dv1mmNFvYaGUvYwKX0PWIh"
    }
}

struct ChatGifSelection {
    let id: String
    let url: String
    let previewUrl: String
    let width: Int
    let height: Int
    /// Already-decoded/cached GIF bytes when available (cell image, cache, or local file).
    let localData: Data?
}

protocol ChatGifPanelViewDelegate: AnyObject {
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectGif gif: ChatGifSelection)
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectSticker sticker: ChatStickerSelection)
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectEmoji emoji: String)
    func chatGifPanelDidRequestClose(_ panel: ChatGifPanelView)
}

private enum ChatGifPanelTab: Int, CaseIterable {
    case gifs = 0
    case stickers = 1
    case emoji = 2

    var title: String {
        switch self {
        case .gifs: return "GIFs"
        case .stickers: return "Stickers"
        case .emoji: return "Emoji"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .gifs: return "Search GIFs"
        case .stickers: return "Search stickers"
        case .emoji: return "Search emoji"
        }
    }
}

private struct ChatGifQuickFilter {
    let id: String
    /// SF Symbol name (outline); rendered as a muted template image.
    let symbolName: String
    let query: String
}

/// Standard Unicode emoji groups. Replaced an emotion taxonomy that could only ever hold a
/// hand-picked sample.
private enum ChatEmojiCategory: String, CaseIterable {
    case recent
    case smileys
    case people
    case nature
    case food
    case activity
    case travel
    case objects
    case symbols
    case flags

    static let browseCases: [ChatEmojiCategory] = [
        .smileys, .people, .nature, .food, .activity, .travel, .objects, .symbols, .flags,
    ]

    var title: String {
        switch self {
        case .recent: return "Recently Used"
        case .smileys: return "Smileys & Emotion"
        case .people: return "People & Body"
        case .nature: return "Animals & Nature"
        case .food: return "Food & Drink"
        case .activity: return "Activity"
        case .travel: return "Travel & Places"
        case .objects: return "Objects"
        case .symbols: return "Symbols"
        case .flags: return "Flags"
        }
    }

    var icon: String {
        switch self {
        case .recent: return "🕘"
        case .smileys: return "🙂"
        case .people: return "👍"
        case .nature: return "🐻"
        case .food: return "🍔"
        case .activity: return "⚽️"
        case .travel: return "✈️"
        case .objects: return "💡"
        case .symbols: return "❤️"
        case .flags: return "🏳️"
        }
    }

    /// Scalar ranges per group, approximated by Unicode block.
    var scalarRanges: [ClosedRange<UInt32>] {
        switch self {
        case .recent, .flags: return []
        case .smileys: return [0x1F600...0x1F64F, 0x1F910...0x1F93A, 0x1F970...0x1F97A,
                               0x1FAE0...0x1FAE8, 0x2639...0x263A]
        case .people: return [0x1F440...0x1F450, 0x1F464...0x1F487, 0x1F574...0x1F575,
                              0x1F645...0x1F64F, 0x1F9B0...0x1F9DF, 0x1FAF0...0x1FAF8,
                              0x261D...0x261D, 0x270A...0x270D]
        case .nature: return [0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F344,
                              0x1F998...0x1F9AE, 0x1F41A...0x1F43F, 0x2600...0x2604]
        case .food: return [0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F32D...0x1F32F]
        case .activity: return [0x1F380...0x1F3AF, 0x1F930...0x1F93E, 0x26BD...0x26BE,
                                0x1F3C0...0x1F3CF]
        case .travel: return [0x1F680...0x1F6C5, 0x1F3E0...0x1F3F0, 0x1F5FA...0x1F5FF,
                              0x2708...0x2708]
        case .objects: return [0x1F4A0...0x1F4FF, 0x1F510...0x1F5D4, 0x1F9F0...0x1F9FF,
                               0x231A...0x231B]
        case .symbols: return [0x2190...0x21FF, 0x2700...0x27BF, 0x1F300...0x1F32C,
                               0x1F500...0x1F50F, 0x2764...0x2764, 0x1F493...0x1F49F,
                               0x0023...0x0023, 0x2049...0x2049]
        }
    }
}

/// Every emoji this device can draw, from Unicode. Search text comes from
/// `properties.name`; unrenderable scalars are dropped rather than shown as tofu.
private enum ChatEmojiCatalogBuilder {
    static func build() -> [ChatEmojiEntry] {
        var seen = Set<String>()
        var entries: [ChatEmojiEntry] = []

        for category in ChatEmojiCategory.browseCases where category != .flags {
            for range in category.scalarRanges {
                for raw in range {
                    guard let scalar = Unicode.Scalar(raw) else { continue }
                    let properties = scalar.properties
                    guard properties.isEmoji else { continue }
                    // Without the selector these draw as monochrome text glyphs.
                    let value =
                        properties.isEmojiPresentation
                        ? String(scalar) : String(scalar) + "\u{FE0F}"
                    guard !seen.contains(value), isRenderable(value) else { continue }
                    seen.insert(value)
                    entries.append(
                        ChatEmojiEntry(
                            value: value,
                            searchText: (properties.name ?? "").lowercased(),
                            category: category
                        ))
                }
            }
        }

        entries.append(contentsOf: flagEntries(excluding: &seen))
        return entries
    }

    /// Flags are regional-indicator pairs, so they come from region codes, not a range.
    private static func flagEntries(excluding seen: inout Set<String>) -> [ChatEmojiEntry] {
        let base: UInt32 = 0x1F1E6
        let scalarA = Unicode.Scalar("A").value
        var entries: [ChatEmojiEntry] = []
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2 else { continue }
            var value = ""
            var valid = true
            for character in code.uppercased().unicodeScalars {
                guard character.value >= scalarA, character.value <= scalarA + 25,
                    let indicator = Unicode.Scalar(base + (character.value - scalarA))
                else {
                    valid = false
                    break
                }
                value.unicodeScalars.append(indicator)
            }
            guard valid, !seen.contains(value), isRenderable(value) else { continue }
            seen.insert(value)
            let name = Locale.current.localizedString(forRegionCode: code) ?? code
            entries.append(
                ChatEmojiEntry(
                    value: value,
                    searchText: "\(name.lowercased()) flag \(code.lowercased())",
                    category: .flags
                ))
        }
        return entries
    }

    /// Tofu filter: does the emoji font have a glyph for every scalar?
    private static func isRenderable(_ value: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)
        var characters = Array(value.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    }
}

private struct ChatEmojiEntry: Hashable {
    let value: String
    let searchText: String
    let category: ChatEmojiCategory
}

private struct ChatEmojiSection {
    let title: String
    let items: [ChatEmojiEntry]
}

/// `safeAreaInsets` is zeroed on both bars below for the same reason: a bottom bar inherits
/// the window's home-indicator inset and reserves room for it *inside itself*, which is the
/// extra edge that pushed this chrome out of view. The panel positions these itself.
private final class FloatingTabBar: UITabBar {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

private final class ChatGifRecentCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatGifRecentCell"
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 10
        imageView.layer.cornerCurve = .continuous
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }
}

private final class ChatGifPanelEmojiCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatGifPanelEmojiCell"

    private let emojiLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(emojiLabel)
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous

        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        emojiLabel.font = .systemFont(ofSize: 31)
        emojiLabel.textAlignment = .center

        NSLayoutConstraint.activate([
            emojiLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            emojiLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            emojiLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            emojiLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(emoji: String, highlighted: Bool) {
        emojiLabel.text = emoji
        contentView.backgroundColor =
            highlighted
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.clear
    }
}

private final class ChatGifPanelEmojiHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "ChatGifPanelEmojiHeaderView"

    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(titleLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, color: UIColor) {
        titleLabel.text = title.uppercased()
        titleLabel.textColor = color
    }
}

final class ChatGifPanelView: UIView {
    weak var delegate: ChatGifPanelViewDelegate?
    var onPreferredHeightChange: (() -> Void)?

    /// True while the panel's own search field holds focus. Host lifts the bar above the
    /// search keyboard; panel height stays fixed so the composer is not pushed offscreen.
    private(set) var isSearchExpanded = false

    /// Space above floating tab bar for scroll content (tighter — closer to content).
    private let bottomFloatingInset: CGFloat = 40
    /// Was 32, which the 49pt bar overflowed because the container did not clip.
    private let bottomFloatingControlHeight: CGFloat = 36
    /// Was 4. Not from the safe area — that reserves the home-indicator strip inside the
    /// chrome and pushes it out of view.
    private let bottomFloatingEdgeInset: CGFloat = 14
    private let topControlsSpacing: CGFloat = 4
    private let stripHeight: CGFloat = 30
    private let searchHeight: CGFloat = 34
    // Total header zone: strip + gap + search + bottom gap
    /// One row plus breathing room above and below. Was two stacked rows.
    private var headerZoneHeight: CGFloat {
        6 + searchHeight + 8
    }

    private var panelVisible = false
    private var activeTab: ChatGifPanelTab = .gifs
    private var searchTextByTab: [ChatGifPanelTab: String] = [:]
    private var selectedGifFilterID: String?
    private var selectedStickerPackID: String? = ChatGifPanelView.loadSelectedStickerPackID()
    private var stickerShowingRecent = false
    private var selectedEmojiCategory: ChatEmojiCategory?

    // Native sticker pack panel (replaces Giphy stickers when packs are available)
    private lazy var stickerPackPanel: ChatStickerPackPanel = {
        let panel = ChatStickerPackPanel()
        panel.delegate = self
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        return panel
    }()
    private var emojiSections: [ChatEmojiSection] = []
    private var recentEmojiValues = ChatGifPanelView.loadRecentEmojiValues()

    weak var hostViewController: UIViewController? {
        didSet {
            guard hostViewController !== oldValue else { return }
            removeEmbeddedPicker()
            if panelVisible, activeTab == .gifs {
                installEmbeddedPickerIfNeeded()
            }
        }
    }

    private let glassBackground = UIVisualEffectView(effect: nil)
    // Category strip + search — translateY + fade on content scroll
    private let headerView = UIView()
    private let headerChromeView = UIVisualEffectView(effect: nil)
    private let topStripScrollView = UIScrollView()
    private let topStripStack = UIStackView()
    private let searchChromeView = UIVisualEffectView(effect: nil)
    private let searchIconView = UIImageView()
    private let searchField = UITextField()
    private let clearSearchButton = UIButton(type: .system)
    // Full-bleed content: 3 pages (GIF | Stickers | Emoji) via translateX / paging
    private let contentContainerView = UIView()
    private let pagesScrollView = UIScrollView()
    private let mediaContainerView = UIView()
    /// GIFs the user has sent, above the browse grid. Local files, no network.
    private lazy var recentsCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 6
        layout.itemSize = CGSize(width: 96, height: 96)
        layout.sectionInset = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.register(
            ChatGifRecentCell.self, forCellWithReuseIdentifier: ChatGifRecentCell.reuseIdentifier)
        view.register(
            UICollectionReusableView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "ChatGifPanelEmptyHeaderView"
        )
        view.dataSource = self
        view.delegate = self
        return view
    }()
    private var recentGifEntries: [ChatGifRecentsStore.Entry] = []
    private let stateLabel = UILabel()
    private let loadingView = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)
    private var isProgrammaticPageScroll = false
    private var contentOffsetObservation: NSKeyValueObservation?
    // Bottom gradient mask (fades into tab bar)
    private let bottomMaskView = UIView()
    private let bottomMaskGradient = CAGradientLayer()
    // Bottom floating controls
    /// Clips the bar to a capsule. The original bug was only that this did NOT clip, so
    /// the 49pt bar painted its background past a 32pt container.
    private let bottomTabBarContainer = UIView()
    private let bottomTabBar = FloatingTabBar()
    private let closeChromeView = UIVisualEffectView(effect: nil)
    private let closeButton = UIButton(type: .system)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private let emojiCollectionView: UICollectionView

    #if canImport(GiphyUISDK)
        private var pickerViewController: GiphyGridController?
    #endif

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 6, left: 12, bottom: 16, right: 12)
        layout.headerReferenceSize = CGSize(width: 120, height: 34)
        emojiCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        removeEmbeddedPicker()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let panelCornerRadius: CGFloat = 28
        let topCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.cornerRadius = panelCornerRadius
        layer.cornerCurve = .continuous
        layer.maskedCorners = topCorners
        glassBackground.layer.cornerRadius = panelCornerRadius
        glassBackground.layer.cornerCurve = .continuous
        glassBackground.layer.maskedCorners = topCorners
        bottomTabBarContainer.layer.cornerRadius = bottomFloatingControlHeight * 0.5
        closeChromeView.layer.cornerRadius = bottomFloatingControlHeight * 0.5
        closeChromeView.layer.cornerCurve = .continuous
        applyFrameLayout()
        // The Giphy grid builds its scroll view lazily, so the inset pass at install time
        // finds nothing. Re-applying on layout catches it; it is idempotent and leaves a
        // scrolling user alone.
        updateContentInsets()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshChrome()
        rebuildTopStripButtons()
        rebuildSearchChrome()
        emojiCollectionView.reloadData()

        #if canImport(GiphyUISDK)
            pickerViewController?.theme = currentGiphyTheme()
        #endif
    }

    func prepareIfNeeded() {
        guard panelVisible else { return }
        if activeTab == .emoji {
            rebuildEmojiSections()
        } else if activeTab == .gifs {
            installEmbeddedPickerIfNeeded()
        } else {
            applyStickerPanelState()
        }
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible

        if visible {
            reloadRecentGifs()
            applyActiveTabState(animated: false)
            if activeTab == .gifs {
                installEmbeddedPickerIfNeeded()
            }
            return
        }

        searchField.resignFirstResponder()
        setSearchExpanded(false)
        removeEmbeddedPicker()
        loadingSpinner.stopAnimating()
        loadingView.isHidden = true
        stateLabel.isHidden = true
    }

    private func setupUI() {
        clipsToBounds = true
        backgroundColor = .clear
        ensureStickerPackSelection()

        // Glass background fills everything
        glassBackground.frame = bounds
        glassBackground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glassBackground)

        // Full-bleed content container (top to bottom — header floats above)
        contentContainerView.backgroundColor = .clear
        contentContainerView.frame = bounds
        contentContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentContainerView)

        // Horizontal paging: page 0 = GIFs, 1 = Stickers, 2 = Emoji (translateX)
        pagesScrollView.isPagingEnabled = true
        pagesScrollView.showsHorizontalScrollIndicator = false
        pagesScrollView.showsVerticalScrollIndicator = false
        pagesScrollView.bounces = true
        pagesScrollView.delegate = self
        pagesScrollView.backgroundColor = .clear
        pagesScrollView.clipsToBounds = true
        contentContainerView.addSubview(pagesScrollView)

        // Media container for Giphy grid — page 0
        mediaContainerView.backgroundColor = .clear
        pagesScrollView.addSubview(mediaContainerView)

        // Stickers — page 1
        pagesScrollView.addSubview(stickerPackPanel)

        // Emoji collection — page 2
        emojiCollectionView.translatesAutoresizingMaskIntoConstraints = true
        emojiCollectionView.backgroundColor = .clear
        emojiCollectionView.alwaysBounceVertical = true
        emojiCollectionView.keyboardDismissMode = .onDrag
        emojiCollectionView.dataSource = self
        emojiCollectionView.delegate = self
        emojiCollectionView.register(
            ChatGifPanelEmojiCell.self,
            forCellWithReuseIdentifier: ChatGifPanelEmojiCell.reuseIdentifier
        )
        emojiCollectionView.register(
            ChatGifPanelEmojiHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: ChatGifPanelEmojiHeaderView.reuseIdentifier
        )
        pagesScrollView.addSubview(emojiCollectionView)

        // State / loading overlays
        stateLabel.translatesAutoresizingMaskIntoConstraints = true
        stateLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stateLabel.font = .systemFont(ofSize: 14)
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateLabel.isHidden = true
        contentContainerView.addSubview(stateLabel)

        loadingView.backgroundColor = .clear
        loadingView.isUserInteractionEnabled = false
        loadingView.isHidden = true
        contentContainerView.addSubview(loadingView)

        loadingSpinner.hidesWhenStopped = true
        loadingView.addSubview(loadingSpinner)

        // Bottom gradient mask: transparent → bg colour (feathers into tab bar)
        bottomMaskView.isUserInteractionEnabled = false
        bottomMaskGradient.startPoint = CGPoint(x: 0.5, y: 0)
        bottomMaskGradient.endPoint = CGPoint(x: 0.5, y: 1)
        bottomMaskView.layer.addSublayer(bottomMaskGradient)
        addSubview(bottomMaskView)

        // ── Scrollable header: strip + search (scrolls with content) ──
        headerView.backgroundColor = .clear
        headerView.isUserInteractionEnabled = true
        addSubview(headerView)

        headerChromeView.clipsToBounds = true
        headerChromeView.layer.cornerRadius = 18
        headerChromeView.layer.cornerCurve = .continuous
        headerView.addSubview(headerChromeView)

        topStripScrollView.showsHorizontalScrollIndicator = false
        topStripScrollView.alwaysBounceHorizontal = true
        topStripScrollView.backgroundColor = .clear
        headerChromeView.contentView.addSubview(topStripScrollView)

        topStripStack.axis = .horizontal
        topStripStack.alignment = .center
        topStripStack.spacing = 6
        topStripStack.translatesAutoresizingMaskIntoConstraints = false
        topStripScrollView.addSubview(topStripStack)

        let topStripMinHeight = topStripStack.heightAnchor.constraint(
            greaterThanOrEqualTo: topStripScrollView.frameLayoutGuide.heightAnchor)

        NSLayoutConstraint.activate([
            topStripStack.leadingAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.leadingAnchor),
            topStripStack.trailingAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.trailingAnchor),
            topStripStack.topAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.topAnchor),
            topStripStack.bottomAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.bottomAnchor),
            topStripMinHeight,
        ])

        searchChromeView.clipsToBounds = true
        searchChromeView.layer.cornerRadius = 18
        searchChromeView.layer.cornerCurve = .continuous
        headerChromeView.contentView.addSubview(searchChromeView)

        searchIconView.contentMode = .scaleAspectFit
        searchChromeView.contentView.addSubview(searchIconView)

        searchField.delegate = self
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .never
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.addTarget(self, action: #selector(searchTextDidChange), for: .editingChanged)
        searchChromeView.contentView.addSubview(searchField)

        clearSearchButton.translatesAutoresizingMaskIntoConstraints = false
        clearSearchButton.addTarget(self, action: #selector(clearSearchTapped), for: .touchUpInside)
        searchChromeView.contentView.addSubview(clearSearchButton)

        // Internal search chrome constraints
        let searchIcon = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        let searchIconLeading = searchIconView.leadingAnchor.constraint(
            equalTo: searchChromeView.contentView.leadingAnchor, constant: 12)
        let searchIconWidth = searchIconView.widthAnchor.constraint(equalToConstant: 20)
        let clearButtonTrailing = clearSearchButton.trailingAnchor.constraint(
            equalTo: searchChromeView.contentView.trailingAnchor, constant: -10)
        let clearButtonWidth = clearSearchButton.widthAnchor.constraint(equalToConstant: 24)
        let searchFieldLeading = searchField.leadingAnchor.constraint(
            equalTo: searchIconView.trailingAnchor, constant: 8)
        let searchFieldTrailing = searchField.trailingAnchor.constraint(
            equalTo: clearSearchButton.leadingAnchor, constant: -6)
        [searchIconLeading, searchIconWidth, clearButtonTrailing, clearButtonWidth, searchFieldLeading,
         searchFieldTrailing].forEach { $0.priority = .defaultHigh }

        NSLayoutConstraint.activate([
            searchIconLeading,
            searchIconView.centerYAnchor.constraint(
                equalTo: searchChromeView.contentView.centerYAnchor),
            searchIconWidth,
            searchIconView.heightAnchor.constraint(equalToConstant: 20),

            clearButtonTrailing,
            clearSearchButton.centerYAnchor.constraint(
                equalTo: searchChromeView.contentView.centerYAnchor),
            clearButtonWidth,
            clearSearchButton.heightAnchor.constraint(equalToConstant: 24),

            searchFieldLeading,
            searchFieldTrailing,
            searchField.centerYAnchor.constraint(
                equalTo: searchChromeView.contentView.centerYAnchor),
        ])
        _ = searchIcon  // suppress unused warning

        // ── Bottom floating tab capsule + close ──
        bottomTabBarContainer.clipsToBounds = true
        bottomTabBarContainer.layer.cornerRadius = bottomFloatingControlHeight * 0.5
        bottomTabBarContainer.layer.cornerCurve = .continuous
        bottomTabBarContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomTabBarContainer)

        bottomTabBar.translatesAutoresizingMaskIntoConstraints = false
        bottomTabBar.delegate = self
        bottomTabBar.itemPositioning = .automatic
        bottomTabBarContainer.addSubview(bottomTabBar)

        closeChromeView.clipsToBounds = true
        closeChromeView.layer.cornerRadius = bottomFloatingControlHeight * 0.5
        closeChromeView.layer.cornerCurve = .continuous
        closeChromeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeChromeView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeChromeView.contentView.addSubview(closeButton)

        // Compact floating chrome flush to panel bottom (small edge inset only).
        NSLayoutConstraint.activate([
            bottomTabBarContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomTabBarContainer.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -bottomFloatingEdgeInset),
            bottomTabBarContainer.heightAnchor.constraint(
                equalToConstant: bottomFloatingControlHeight),
            bottomTabBarContainer.widthAnchor.constraint(equalToConstant: 210),

            // Pinned on all four edges AND height-constrained, so the bar cannot fall back
            // to its intrinsic height and spill out of the capsule.
            bottomTabBar.leadingAnchor.constraint(
                equalTo: bottomTabBarContainer.leadingAnchor, constant: -12),
            bottomTabBar.trailingAnchor.constraint(
                equalTo: bottomTabBarContainer.trailingAnchor, constant: 12),
            bottomTabBar.centerYAnchor.constraint(equalTo: bottomTabBarContainer.centerYAnchor),

            closeChromeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            // Centred on the capsule rather than pinned to the panel bottom, so the two
            // read as one row however tall the capsule ends up.
            closeChromeView.centerYAnchor.constraint(
                equalTo: bottomTabBarContainer.centerYAnchor),
            closeChromeView.widthAnchor.constraint(equalToConstant: bottomFloatingControlHeight),
            closeChromeView.heightAnchor.constraint(equalToConstant: bottomFloatingControlHeight),

            closeButton.leadingAnchor.constraint(
                equalTo: closeChromeView.contentView.leadingAnchor),
            closeButton.trailingAnchor.constraint(
                equalTo: closeChromeView.contentView.trailingAnchor),
            closeButton.topAnchor.constraint(equalTo: closeChromeView.contentView.topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: closeChromeView.contentView.bottomAnchor),
        ])

        var items: [UITabBarItem] = []
        for tab in ChatGifPanelTab.allCases {
            items.append(UITabBarItem(title: tab.title, image: nil, tag: tab.rawValue))
        }
        bottomTabBar.items = items
        bottomTabBar.selectedItem = items.first

        // Plain glyph, not `xmark.circle.fill` — that symbol carries its own filled disc,
        // which read as a second plate on top of the toolbar's material.
        let closeConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: closeConfig),
            for: .normal
        )
        closeButton.tintColor = secondaryTextColor

        selectionFeedback.prepare()
        refreshChrome()
        rebuildSearchChrome()
        rebuildTopStripButtons()
        rebuildEmojiSections()
        updateContentInsets()
        applyActiveTabState(animated: false)
    }

    private func updateContentInsets() {
        let insets = UIEdgeInsets(top: headerZoneHeight, left: 0, bottom: bottomFloatingInset, right: 0)
        applyContentInsets(insets, to: emojiCollectionView)
        applyContentInsets(insets, to: stickerPackPanel.contentScrollView)
        #if canImport(GiphyUISDK)
        if let pickerView = pickerViewController?.view, let sv = findScrollView(in: pickerView) {
            applyContentInsets(insets, to: sv)
        }
        #endif
    }

    /// Setting `contentInset.top` does not move content that is already at rest — the
    /// offset has to be pinned to `-top` too, or the first rows sit under the header.
    private func applyContentInsets(_ insets: UIEdgeInsets, to scrollView: UIScrollView) {
        // Ours is the only top inset; without this the safe area is added on top of it.
        scrollView.contentInsetAdjustmentBehavior = .never
        let wasAtTop = scrollView.contentOffset.y <= -scrollView.contentInset.top + 0.5
        scrollView.contentInset = insets
        scrollView.verticalScrollIndicatorInsets = insets
        if wasAtTop, !scrollView.isDragging, !scrollView.isDecelerating {
            scrollView.contentOffset.y = -insets.top
        }
    }

    /// Frame-based layout — called from layoutSubviews.
    private func applyFrameLayout() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let hInset: CGFloat = 10
        let stripTop: CGFloat = 6

        // Header (category chips + search) — position is base; scroll applies translateY/alpha
        headerView.bounds = CGRect(x: 0, y: 0, width: w, height: headerZoneHeight)
        if headerView.transform == .identity {
            headerView.frame = CGRect(x: 0, y: 0, width: w, height: headerZoneHeight)
        } else {
            // Keep size while preserving scroll-driven transform.
            let t = headerView.transform
            headerView.transform = .identity
            headerView.frame = CGRect(x: 0, y: 0, width: w, height: headerZoneHeight)
            headerView.transform = t
        }
        // One row: search on the left, category chips scrolling beside it. Two stacked
        // rows made the header a block that pushed content under the composer.
        let rowHeight = searchHeight
        headerChromeView.frame = CGRect(
            x: hInset, y: stripTop, width: max(0, w - hInset * 2), height: rowHeight)
        let chromeWidth = headerChromeView.bounds.width
        let searchWidth = isSearchExpanded ? chromeWidth : min(150, chromeWidth * 0.42)
        searchChromeView.frame = CGRect(
            x: 0, y: 0, width: searchWidth, height: rowHeight)
        let stripX = searchChromeView.frame.maxX + topControlsSpacing
        topStripScrollView.frame = CGRect(
            x: stripX,
            y: 0,
            width: max(0, chromeWidth - stripX),
            height: rowHeight
        )
        topStripScrollView.alpha = isSearchExpanded ? 0 : 1

        // Content: full-bleed horizontal pages
        contentContainerView.frame = bounds
        pagesScrollView.frame = bounds
        pagesScrollView.contentSize = CGSize(width: w * 3, height: h)

        // Page 0 GIFs · 1 Stickers · 2 Emoji
        mediaContainerView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        stickerPackPanel.translatesAutoresizingMaskIntoConstraints = true
        stickerPackPanel.frame = CGRect(x: w, y: 0, width: w, height: h)
        emojiCollectionView.frame = CGRect(x: w * 2, y: 0, width: w, height: h)

        // Keep page offset in sync with active tab (no jump when resizing)
        let pageX = CGFloat(activeTab.rawValue) * w
        if abs(pagesScrollView.contentOffset.x - pageX) > 1, !pagesScrollView.isDragging,
            !pagesScrollView.isDecelerating
        {
            isProgrammaticPageScroll = true
            pagesScrollView.contentOffset = CGPoint(x: pageX, y: 0)
            isProgrammaticPageScroll = false
        }

        // Recents ride just under the header on the GIF page; the browse grid keeps the
        // rest. Hidden entirely when the user has sent nothing.
        if recentsCollectionView.superview !== mediaContainerView {
            mediaContainerView.addSubview(recentsCollectionView)
        }
        let recentsHeight: CGFloat = 96
        let showRecents = !recentGifEntries.isEmpty && currentSearchText().isEmpty
        recentsCollectionView.isHidden = !showRecents
        recentsCollectionView.frame = CGRect(
            x: 0, y: headerZoneHeight, width: w, height: showRecents ? recentsHeight : 0)
        mediaContainerView.bringSubviewToFront(recentsCollectionView)

        stateLabel.frame = mediaContainerView.bounds
        loadingView.frame = mediaContainerView.bounds
        loadingSpinner.center = CGPoint(x: w * 0.5, y: h * 0.5 - 18)
        // State/loading stay above Giphy inside page 0
        if stateLabel.superview !== mediaContainerView {
            mediaContainerView.addSubview(stateLabel)
            mediaContainerView.addSubview(loadingView)
        }

        // Bottom gradient mask (shorter — tighter chrome)
        let bottomMaskH: CGFloat = 56
        bottomMaskView.frame = CGRect(x: 0, y: h - bottomMaskH, width: w, height: bottomMaskH)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomMaskGradient.frame = bottomMaskView.bounds
        CATransaction.commit()

        // Z-order: content → bottom mask → floating controls → header
        bringSubviewToFront(bottomMaskView)
        bringSubviewToFront(bottomTabBarContainer)
        bringSubviewToFront(closeChromeView)
        bringSubviewToFront(headerView)
    }

    private func refreshChrome() {
        let blurStyle: UIBlurEffect.Style =
            isDarkMode ? .systemChromeMaterialDark : .systemChromeMaterialLight
        if #available(iOS 26.0, *) {
            let backgroundGlass = UIGlassEffect()
            backgroundGlass.isInteractive = true
            glassBackground.effect = backgroundGlass
            let headerGlass = UIGlassEffect()
            headerGlass.isInteractive = true
            headerChromeView.effect = headerGlass
            searchChromeView.effect = nil
            let closeGlass = UIGlassEffect()
            closeGlass.isInteractive = true
            closeChromeView.effect = closeGlass
        } else {
            glassBackground.effect = UIBlurEffect(style: .systemMaterial)
            headerChromeView.effect = UIBlurEffect(style: blurStyle)
            searchChromeView.effect = nil
            closeChromeView.effect = UIBlurEffect(style: blurStyle)
        }

        headerChromeView.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        searchChromeView.backgroundColor = .clear

        // Update gradient mask colours to match current background
        let bgColor =
            isDarkMode
            ? UIColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1)
            : UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        bottomMaskGradient.colors = [bgColor.withAlphaComponent(0).cgColor, bgColor.cgColor]

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        tabAppearance.shadowColor = .clear
        tabAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)

        let itemAppearance = tabAppearance.stackedLayoutAppearance
        let inactive = secondaryTextColor
        itemAppearance.normal.iconColor = inactive
        itemAppearance.normal.titleTextAttributes = [
            .foregroundColor: inactive,
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        itemAppearance.normal.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -12)
        itemAppearance.selected.iconColor = primaryTextColor
        itemAppearance.selected.titleTextAttributes = [
            .foregroundColor: primaryTextColor,
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        itemAppearance.selected.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -12)
        tabAppearance.stackedLayoutAppearance = itemAppearance
        tabAppearance.inlineLayoutAppearance = itemAppearance
        tabAppearance.compactInlineLayoutAppearance = itemAppearance

        bottomTabBar.standardAppearance = tabAppearance
        bottomTabBar.scrollEdgeAppearance = tabAppearance
        closeButton.tintColor = secondaryTextColor
    }

    private func rebuildSearchChrome() {
        let searchConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        searchIconView.image = UIImage(
            systemName: "magnifyingglass", withConfiguration: searchConfig)
        searchIconView.tintColor = secondaryTextColor.withAlphaComponent(0.5)

        let clearConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        clearSearchButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: clearConfig),
            for: .normal
        )
        clearSearchButton.tintColor = secondaryTextColor
        clearSearchButton.isHidden = currentSearchText().isEmpty
        searchField.textColor = primaryTextColor
        searchField.tintColor = primaryTextColor
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.attributedPlaceholder = NSAttributedString(
            string: activeTab.searchPlaceholder,
            attributes: [.foregroundColor: secondaryTextColor.withAlphaComponent(0.5)]
        )
    }

    private func rebuildTopStripButtons() {
        topStripStack.arrangedSubviews.forEach { view in
            topStripStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch activeTab {
        case .gifs:
            for (index, filter) in gifQuickFilters.enumerated() {
                let button = makeStripButton(
                    symbolName: filter.symbolName,
                    selected: selectedGifFilterID == filter.id,
                    showsAddBadge: false
                )
                button.tag = index
                button.accessibilityLabel = filter.query
                button.addTarget(
                    self, action: #selector(gifQuickFilterTapped(_:)), for: .touchUpInside)
                topStripStack.addArrangedSubview(button)
            }
        case .stickers:
            ensureStickerPackSelection()
            let installedStickerPacks = ChatStickerPackStore.shared.installedPacks
            // Header shows only what exists. With no packs installed there is nothing to
            // filter, and a strip of buttons over an empty grid reads as a mock panel.
            guard !installedStickerPacks.isEmpty else { break }

            if !ChatStickerPackStore.shared.recentStickers.isEmpty {
                let recentButton = makeStripButton(
                    title: "🕘",
                    selected: stickerShowingRecent,
                    showsAddBadge: false
                )
                recentButton.accessibilityLabel = "Recently Used"
                recentButton.addTarget(
                    self, action: #selector(stickerRecentTapped), for: .touchUpInside)
                topStripStack.addArrangedSubview(recentButton)
            }

            for (index, pack) in installedStickerPacks.enumerated() {
                let button = makeStripButton(
                    title: pack.icon,
                    selected: !stickerShowingRecent && selectedStickerPackID == pack.id,
                    showsAddBadge: false
                )
                button.tag = index
                button.accessibilityLabel = pack.name
                button.addTarget(
                    self, action: #selector(stickerStarterPackTapped(_:)), for: .touchUpInside)
                topStripStack.addArrangedSubview(button)
            }
        case .emoji:
            let categories = [ChatEmojiCategory.recent] + ChatEmojiCategory.browseCases
            for (index, category) in categories.enumerated() {
                let selected = selectedEmojiCategory == category
                let button = makeStripButton(
                    title: category.icon,
                    selected: selected,
                    showsAddBadge: false
                )
                button.tag = index
                button.accessibilityLabel = category.title
                button.addTarget(
                    self, action: #selector(emojiCategoryTapped(_:)), for: .touchUpInside)
                topStripStack.addArrangedSubview(button)
            }
        }
    }

    private func makeStripButton(
        title: String? = nil,
        symbolName: String? = nil,
        selected: Bool,
        showsAddBadge: Bool
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()

        if let symbolName {
            // Muted outline SF Symbol; selected uses primary tint + chip background.
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            config.image = UIImage(systemName: symbolName, withConfiguration: symbolConfig)
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            button.configuration = config
            button.tintColor = selected ? primaryTextColor : secondaryTextColor
        } else if let title {
            let isEmoji = title.count <= 2
            config.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: isEmoji ? 6 : 10, bottom: 0, trailing: isEmoji ? 6 : 10)
            button.configuration = config
            button.setTitle(title, for: .normal)
            button.setTitleColor(primaryTextColor, for: .normal)
            button.titleLabel?.font = .systemFont(
                ofSize: isEmoji ? 24 : 15,
                weight: isEmoji ? .regular : .semibold
            )
        }

        button.backgroundColor = selected ? selectedChipColor : .clear
        if activeTab == .emoji {
            button.alpha = 1.0
            button.transform = selected ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity
        }

        button.layer.cornerRadius = 17
        button.layer.cornerCurve = .continuous
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: 34)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        if showsAddBadge {
            let badge = UILabel()
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.text = "+"
            badge.textAlignment = .center
            badge.font = .systemFont(ofSize: 13, weight: .bold)
            badge.textColor = .white
            badge.backgroundColor = accentBadgeColor
            badge.layer.cornerRadius = 10
            badge.layer.cornerCurve = .continuous
            badge.clipsToBounds = true
            button.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 20),
                badge.heightAnchor.constraint(equalToConstant: 20),
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 3),
                badge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: 3),
            ])
        }

        return button
    }

    private func applyActiveTabState(animated: Bool) {
        if activeTab == .stickers {
            ensureStickerPackSelection()
        }
        rebuildSearchChrome()
        rebuildTopStripButtons()

        // All three pages stay mounted; we only translateX the pager.
        mediaContainerView.isHidden = false
        stickerPackPanel.isHidden = false
        emojiCollectionView.isHidden = false

        switch activeTab {
        case .emoji:
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
            rebuildEmojiSections()
        case .stickers:
            stateLabel.isHidden = true
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
            applyStickerPanelState()
        case .gifs:
            stateLabel.isHidden = true
            if panelVisible {
                installEmbeddedPickerIfNeeded()
            }
            #if canImport(GiphyUISDK)
                let shouldShowLoading = animated && pickerViewController == nil
            #else
                let shouldShowLoading = false
            #endif
            updateEmbeddedPickerContent(showLoading: shouldShowLoading)
        }

        let w = max(bounds.width, 1)
        let targetX = CGFloat(activeTab.rawValue) * w
        isProgrammaticPageScroll = true
        if animated, bounds.width > 1 {
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction]
            ) {
                self.pagesScrollView.contentOffset = CGPoint(x: targetX, y: 0)
            } completion: { _ in
                self.isProgrammaticPageScroll = false
            }
        } else {
            pagesScrollView.contentOffset = CGPoint(x: targetX, y: 0)
            isProgrammaticPageScroll = false
        }

        // Keep search-expand height rule for the active tab.
        if searchField.isFirstResponder {
            setSearchExpanded(true)
        }
        observeActivePageScroll()
        setNeedsLayout()
    }

    /// Category strip + search: translateY up and fade as the active page scrolls.
    ///
    /// Measured from the inset origin, not raw `contentOffset.y`. A page at rest sits at
    /// `-contentInset.top`, so the raw offset was already negative before a finger moved —
    /// the header hid at the wrong time, or never.
    private func updateHeaderForScroll(_ scrollView: UIScrollView) {
        let travel = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let progress = min(1, max(0, travel / 56))
        headerView.transform = CGAffineTransform(translationX: 0, y: -progress * 36)
        headerView.alpha = 1 - progress * 0.92
        headerView.isUserInteractionEnabled = progress < 0.85
    }

    private func reloadRecentGifs() {
        recentGifEntries = ChatGifRecentsStore.shared.entries
        recentsCollectionView.reloadData()
        setNeedsLayout()
    }

    private func applyStickerPanelState() {
        stickerPackPanel.setSearchQuery(currentSearchText())
        if stickerShowingRecent {
            stickerPackPanel.setDisplayModeRecent()
        } else {
            stickerPackPanel.setDisplayedPack(id: selectedStickerPackID)
        }
    }

    // MARK: - Scroll-hosted header


    private func findScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let sv = sub as? UIScrollView { return sv }
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    @objc private func gifQuickFilterTapped(_ sender: UIButton) {
        guard sender.tag >= 0, sender.tag < gifQuickFilters.count else { return }
        let filter = gifQuickFilters[sender.tag]
        selectionFeedback.selectionChanged()
        selectedGifFilterID = filter.id
        updateCurrentSearchText(filter.query, synchronizeField: true, clearPresetSelection: false)
        searchField.resignFirstResponder()
        rebuildTopStripButtons()
    }

    @objc private func stickerStarterPackTapped(_ sender: UIButton) {
        let installedStickerPacks = ChatStickerPackStore.shared.installedPacks
        guard sender.tag >= 0, sender.tag < installedStickerPacks.count else { return }
        let pack = installedStickerPacks[sender.tag]
        selectionFeedback.selectionChanged()
        stickerShowingRecent = false
        selectedStickerPackID = pack.id
        persistSelectedStickerPackID()
        searchField.resignFirstResponder()
        rebuildTopStripButtons()
        applyStickerPanelState()
    }

    @objc private func stickerRecentTapped() {
        selectionFeedback.selectionChanged()
        stickerShowingRecent = true
        searchField.resignFirstResponder()
        rebuildTopStripButtons()
        applyStickerPanelState()
    }

    @objc private func emojiCategoryTapped(_ sender: UIButton) {
        let categories = [ChatEmojiCategory.recent] + ChatEmojiCategory.browseCases
        guard sender.tag >= 0, sender.tag < categories.count else { return }
        let category = categories[sender.tag]
        selectionFeedback.selectionChanged()
        selectedEmojiCategory = (selectedEmojiCategory == category) ? nil : category
        updateCurrentSearchText("", synchronizeField: true, clearPresetSelection: false)
        searchField.resignFirstResponder()
        rebuildTopStripButtons()
        rebuildEmojiSections()
    }

    @objc private func searchTextDidChange() {
        updateCurrentSearchText(
            searchField.text ?? "", synchronizeField: false, clearPresetSelection: true)
    }

    @objc private func clearSearchTapped() {
        updateCurrentSearchText("", synchronizeField: true, clearPresetSelection: true)
        searchField.becomeFirstResponder()
    }

    @objc private func closeTapped() {
        delegate?.chatGifPanelDidRequestClose(self)
    }

    private func updateCurrentSearchText(
        _ rawValue: String,
        synchronizeField: Bool,
        clearPresetSelection: Bool
    ) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTextByTab[activeTab] = value

        if synchronizeField, searchField.text != value {
            searchField.text = value
        }

        if clearPresetSelection {
            switch activeTab {
            case .gifs:
                selectedGifFilterID = nil
            case .stickers:
                break
            case .emoji:
                if !value.isEmpty {
                    selectedEmojiCategory = nil
                }
            }
            rebuildTopStripButtons()
        }

        clearSearchButton.isHidden = value.isEmpty

        switch activeTab {
        case .emoji:
            rebuildEmojiSections()
        case .gifs:
            updateEmbeddedPickerContent(showLoading: false)
        case .stickers:
            stickerPackPanel.setSearchQuery(value)
        }
    }

    private func currentSearchText() -> String {
        searchTextByTab[activeTab] ?? ""
    }

    private func ensureStickerPackSelection() {
        let installedStickerPacks = ChatStickerPackStore.shared.installedPacks
        guard !installedStickerPacks.isEmpty else {
            selectedStickerPackID = nil
            return
        }

        if let selectedStickerPackID,
            installedStickerPacks.contains(where: { $0.id == selectedStickerPackID })
        {
            return
        }

        selectedStickerPackID = installedStickerPacks.first?.id
        persistSelectedStickerPackID()
    }

    private func persistSelectedStickerPackID() {
        guard let selectedStickerPackID else {
            UserDefaults.standard.removeObject(forKey: Self.selectedStickerPackDefaultsKey)
            return
        }
        UserDefaults.standard.set(
            selectedStickerPackID, forKey: Self.selectedStickerPackDefaultsKey)
    }

    private func setSearchExpanded(_ expanded: Bool) {
        guard expanded != isSearchExpanded else { return }
        isSearchExpanded = expanded
        // Chips yield to the field while typing; height stays fixed (host lifts the bar).
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState]) {
            self.applyFrameLayout()
        }
        onPreferredHeightChange?()
    }

    private func rebuildEmojiSections() {
        let query = currentSearchText().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !query.isEmpty {
            let matches = emojiCatalog.filter {
                $0.value.contains(query) || $0.searchText.localizedCaseInsensitiveContains(query)
            }
            emojiSections =
                matches.isEmpty
                ? []
                : [ChatEmojiSection(title: "Search Results", items: matches)]
        } else if let selectedEmojiCategory {
            if selectedEmojiCategory == .recent {
                let recents = resolvedRecentEmojiEntries()
                emojiSections =
                    recents.isEmpty
                    ? []
                    : [ChatEmojiSection(title: ChatEmojiCategory.recent.title, items: recents)]
            } else {
                emojiSections = [
                    ChatEmojiSection(
                        title: selectedEmojiCategory.title,
                        items: emojiCatalog.filter { $0.category == selectedEmojiCategory }
                    )
                ]
            }
        } else {
            var sections: [ChatEmojiSection] = []
            let recents = resolvedRecentEmojiEntries()
            if !recents.isEmpty {
                sections.append(
                    ChatEmojiSection(title: ChatEmojiCategory.recent.title, items: recents))
            }
            for category in ChatEmojiCategory.browseCases {
                let items = emojiCatalog.filter { $0.category == category }
                if !items.isEmpty {
                    sections.append(ChatEmojiSection(title: category.title, items: items))
                }
            }
            emojiSections = sections
        }

        emojiCollectionView.reloadData()
        if activeTab == .stickers, ChatStickerPackStore.shared.installedPacks.isEmpty {
            stateLabel.text = "No sticker packs yet."
            stateLabel.textColor = secondaryTextColor
            stateLabel.isHidden = false
            return
        }
        let shouldShowEmpty = activeTab == .emoji && emojiSections.allSatisfy(\.items.isEmpty)
        if shouldShowEmpty {
            stateLabel.text =
                query.isEmpty
                ? "No emoji available yet."
                : "No emoji found for \"\(query)\"."
            stateLabel.textColor = secondaryTextColor
            stateLabel.isHidden = false
        } else if activeTab == .emoji {
            stateLabel.isHidden = true
        }
    }

    private func resolvedRecentEmojiEntries() -> [ChatEmojiEntry] {
        recentEmojiValues.compactMap { value in
            emojiCatalog.first(where: { $0.value == value })
        }
    }

    private func registerRecentEmoji(_ emoji: String) {
        recentEmojiValues.removeAll(where: { $0 == emoji })
        recentEmojiValues.insert(emoji, at: 0)
        if recentEmojiValues.count > 32 {
            recentEmojiValues = Array(recentEmojiValues.prefix(32))
        }
        UserDefaults.standard.set(recentEmojiValues, forKey: Self.recentEmojiDefaultsKey)
    }

    private static func loadRecentEmojiValues() -> [String] {
        let stored = UserDefaults.standard.array(forKey: recentEmojiDefaultsKey) as? [String]
        return stored ?? []
    }

    private static func loadSelectedStickerPackID() -> String? {
        let stored = UserDefaults.standard.string(forKey: selectedStickerPackDefaultsKey)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    @discardableResult
    private func configureGiphySDKIfNeeded() -> Bool {
        #if canImport(GiphyUISDK)
            let key = ChatGifPanelConfig.shared.apiKey.trimmingCharacters(
                in: .whitespacesAndNewlines)
            print("[NativeGif][iOS] configureGiphySDKIfNeeded keyLength=\(key.count)")
            guard !key.isEmpty else { return false }
            Giphy.configure(apiKey: key)
            print("[NativeGif][iOS] Giphy.configure succeeded")
            return true
        #else
            print("[NativeGif][iOS] GiphyUISDK unavailable")
            return false
        #endif
    }

    #if canImport(GiphyUISDK)
        private func currentGiphyTheme() -> GPHTheme {
            GPHTheme(type: isDarkMode ? .darkBlur : .lightBlur)
        }

        private func resolvedGiphyContent() -> GPHContent {
            let query = currentSearchText().trimmingCharacters(in: .whitespacesAndNewlines)

            if !query.isEmpty {
                return .search(
                    withQuery: query,
                    mediaType: .gif,
                    language: .english,
                    includeDynamicResults: true
                )
            }

            // A quick-filter chip is a search, not a browse.
            if let filterID = selectedGifFilterID,
                let filter = gifQuickFilters.first(where: { $0.id == filterID })
            {
                return .search(
                    withQuery: filter.query,
                    mediaType: .gif,
                    language: .english,
                    includeDynamicResults: true
                )
            }
            return .trendingGifs
        }
    #endif

    private func installEmbeddedPickerIfNeeded() {
        #if canImport(GiphyUISDK)
            guard activeTab == .gifs else { return }
            guard let host = hostViewController else {
                print("[NativeGif][iOS] installEmbeddedPickerIfNeeded missing hostViewController")
                showStateLabel("GIF host is unavailable right now.")
                return
            }

            // If a picker is already attached to a *different* parent, tear it down first.
            if let existing = pickerViewController {
                if existing.parent === host {
                    return
                }
                print(
                    "[NativeGif][iOS] reparent GiphyGridController from \(String(describing: existing.parent)) → \(host)"
                )
                removeEmbeddedPicker()
            }

            guard configureGiphySDKIfNeeded() else {
                print("[NativeGif][iOS] installEmbeddedPickerIfNeeded missing API key")
                showStateLabel("Configure a Giphy API key to enable GIF search.")
                return
            }

            print("[NativeGif][iOS] creating GiphyGridController host=\(type(of: host))")

            let picker = GiphyGridController()
            picker.delegate = self
            picker.theme = currentGiphyTheme()
            picker.direction = .vertical
            picker.fixedSizeCells = false
            // Same rendition as send path so cell image / GPHCache hits are reusable.
            picker.renditionType = Self.gridGifRendition
            picker.additionalSafeAreaInsets = .zero
            picker.content = resolvedGiphyContent()

            // Add child before attaching view so hierarchy stays consistent.
            host.addChild(picker)
            mediaContainerView.addSubview(picker.view)
            picker.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                picker.view.leadingAnchor.constraint(equalTo: mediaContainerView.leadingAnchor),
                picker.view.trailingAnchor.constraint(equalTo: mediaContainerView.trailingAnchor),
                picker.view.topAnchor.constraint(equalTo: mediaContainerView.topAnchor),
                picker.view.bottomAnchor.constraint(equalTo: mediaContainerView.bottomAnchor),
            ])
            picker.view.backgroundColor = .clear
            picker.view.isOpaque = false
            picker.didMove(toParent: host)

            pickerViewController = picker
            stateLabel.isHidden = true
            updateEmbeddedPickerContent(showLoading: panelVisible)
            updateContentInsets()
        #else
            showStateLabel("Install the Giphy native SDK to enable GIF search.")
        #endif
    }

    private func updateEmbeddedPickerContent(showLoading: Bool) {
        #if canImport(GiphyUISDK)
            guard activeTab == .gifs else { return }
            guard let picker = pickerViewController else {
                if panelVisible {
                    installEmbeddedPickerIfNeeded()
                }
                return
            }

            // Heal hierarchy if host was swapped under us.
            if let host = hostViewController, picker.parent !== host {
                print("[NativeGif][iOS] healing Giphy parent mismatch — reinstall")
                removeEmbeddedPicker()
                installEmbeddedPickerIfNeeded()
                return
            }

            picker.content = resolvedGiphyContent()
            if showLoading {
                loadingSpinner.startAnimating()
                loadingView.isHidden = false
            } else {
                loadingSpinner.stopAnimating()
                loadingView.isHidden = true
            }
            stateLabel.isHidden = true
            picker.update()
        #endif
    }

    private func removeEmbeddedPicker() {
        #if canImport(GiphyUISDK)
            guard let picker = pickerViewController else { return }
            picker.willMove(toParent: nil)
            picker.view.removeFromSuperview()
            // removeFromParent is safe even if parent is already nil.
            if picker.parent != nil {
                picker.removeFromParent()
            }
            pickerViewController = nil
        #endif
    }

    private func showStateLabel(_ text: String) {
        loadingSpinner.stopAnimating()
        loadingView.isHidden = true
        stateLabel.text = text
        stateLabel.textColor = secondaryTextColor
        stateLabel.isHidden = false
    }

    private func normalizedNonEmptyString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    #if canImport(GiphyUISDK)
        /// Grid + send share this so visible cell / GPHCache bytes match the URL we emit.
        private static let gridGifRendition: GPHRenditionType = .downsized

        private func resolvedPrimaryImage(from images: GPHImages?) -> GPHImage? {
            guard let images else { return nil }
            if let preferred = images.rendition(Self.gridGifRendition) { return preferred }
            if let downsized = images.downsized { return downsized }
            if let fixedWidth = images.fixedWidth { return fixedWidth }
            if let fixedHeight = images.fixedHeight { return fixedHeight }
            if let original = images.original { return original }
            if let preview = images.preview { return preview }
            if let fixedWidthSmall = images.fixedWidthSmall { return fixedWidthSmall }
            return nil
        }

        private func findGPHMediaView(in view: UIView) -> GPHMediaView? {
            if let mediaView = view as? GPHMediaView { return mediaView }
            for subview in view.subviews {
                if let found = findGPHMediaView(in: subview) { return found }
            }
            return nil
        }

        /// Prefer the cell's already-decoded GIF, then exact-URL cache; nil falls back to fetch.
        private func localGifData(from cell: UICollectionViewCell?, renditionURL: String?) -> Data? {
            if let cell,
                let mediaView = findGPHMediaView(in: cell),
                let yyImage = mediaView.image as? GiphyYYImage,
                let data = yyImage.animatedImageData,
                !data.isEmpty
            {
                return data
            }
            if let renditionURL,
                let url = URL(string: renditionURL),
                let cached = GPHCache.shared.cache.cachedResponse(for: URLRequest(url: url)),
                !cached.data.isEmpty
            {
                return cached.data
            }
            return nil
        }

        private func resolvedPreviewURL(
            from images: GPHImages?,
            primaryImage: GPHImage?,
            fallbackURL: String
        ) -> String {
            if let preview = normalizedNonEmptyString(images?.preview?.gifUrl) {
                return preview
            }
            if let fixedWidthSmallStill = normalizedNonEmptyString(
                images?.fixedWidthSmallStill?.stillGifUrl)
            {
                return fixedWidthSmallStill
            }
            if let fixedWidthStill = normalizedNonEmptyString(images?.fixedWidthStill?.stillGifUrl)
            {
                return fixedWidthStill
            }
            if let originalStill = normalizedNonEmptyString(images?.originalStill?.stillGifUrl) {
                return originalStill
            }
            if let primaryStill = normalizedNonEmptyString(primaryImage?.stillGifUrl) {
                return primaryStill
            }
            return fallbackURL
        }
    #endif

    private var isDarkMode: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    private var primaryTextColor: UIColor {
        isDarkMode
            ? UIColor(white: 0.95, alpha: 0.96)
            : UIColor(white: 0.12, alpha: 0.96)
    }

    private var secondaryTextColor: UIColor {
        isDarkMode
            ? UIColor(white: 0.84, alpha: 0.62)
            : UIColor(white: 0.12, alpha: 0.42)
    }

    private var selectedChipColor: UIColor {
        isDarkMode
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.1)
    }

    private var accentBadgeColor: UIColor {
        UIColor(red: 0.90, green: 0.75, blue: 0.48, alpha: 0.92)
    }

    private static let recentEmojiDefaultsKey = "chat.gif.panel.recent.emoji"
    private static let selectedStickerPackDefaultsKey = "chat.gif.panel.selected.sticker.pack"

    private let gifQuickFilters: [ChatGifQuickFilter] = [
        .init(id: "love", symbolName: "heart", query: "love"),
        .init(id: "like", symbolName: "hand.thumbsup", query: "like"),
        .init(id: "dislike", symbolName: "hand.thumbsdown", query: "dislike"),
        .init(id: "party", symbolName: "party.popper", query: "party"),
        .init(id: "happy", symbolName: "face.smiling", query: "happy"),
        .init(id: "sad", symbolName: "cloud.rain", query: "sad"),
        .init(id: "angry", symbolName: "flame", query: "angry"),
        .init(id: "neutral", symbolName: "minus.circle", query: "neutral"),
    ]

    /// Was a hand-typed list of ~90; now the full set.
    private lazy var emojiCatalog: [ChatEmojiEntry] = ChatEmojiCatalogBuilder.build()
}

extension ChatGifPanelView: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        setSearchExpanded(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        setSearchExpanded(false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension ChatGifPanelView: UITabBarDelegate {
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let nextTab = ChatGifPanelTab(rawValue: item.tag), nextTab != activeTab else {
            return
        }
        activeTab = nextTab
        if nextTab == .stickers {
            ensureStickerPackSelection()
        }
        searchField.resignFirstResponder()
        if searchField.text != currentSearchText() {
            searchField.text = currentSearchText()
        }
        selectionFeedback.selectionChanged()
        updateTabButtonSelection()
        applyActiveTabState(animated: true)
    }

    fileprivate func updateTabButtonSelection() {
        guard let items = bottomTabBar.items,
            let match = items.first(where: { $0.tag == activeTab.rawValue })
        else { return }
        bottomTabBar.selectedItem = match
    }
}

extension ChatGifPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView === recentsCollectionView ? 1 : emojiSections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
        -> Int
    {
        if collectionView === recentsCollectionView { return recentGifEntries.count }
        return emojiSections[section].items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if collectionView === recentsCollectionView {
            guard
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ChatGifRecentCell.reuseIdentifier, for: indexPath
                ) as? ChatGifRecentCell
            else { return UICollectionViewCell() }
            let entry = recentGifEntries[indexPath.item]
            let url = ChatGifRecentsStore.shared.fileURL(for: entry)
            if let data = try? Data(contentsOf: url) {
                cell.imageView.image = chatMediaDecodedImagePublic(from: data, shouldAnimate: true)
            }
            return cell
        }
        guard
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatGifPanelEmojiCell.reuseIdentifier,
                for: indexPath
            ) as? ChatGifPanelEmojiCell
        else {
            return UICollectionViewCell()
        }

        let item = emojiSections[indexPath.section].items[indexPath.item]
        cell.configure(emoji: item.value, highlighted: false)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === recentsCollectionView {
            let entry = recentGifEntries[indexPath.item]
            let url = ChatGifRecentsStore.shared.fileURL(for: entry)
            let localData = try? Data(contentsOf: url)
            selectionFeedback.selectionChanged()
            delegate?.chatGifPanel(
                self,
                didSelectGif: ChatGifSelection(
                    id: entry.id,
                    url: url.absoluteString,
                    previewUrl: url.absoluteString,
                    width: entry.width,
                    height: entry.height,
                    localData: localData
                ))
            return
        }
        let item = emojiSections[indexPath.section].items[indexPath.item]
        registerRecentEmoji(item.value)
        delegate?.chatGifPanel(self, didSelectEmoji: item.value)
        if activeTab == .emoji && currentSearchText().isEmpty {
            rebuildEmojiSections()
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        if collectionView === recentsCollectionView {
            return collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: "ChatGifPanelEmptyHeaderView",
                for: indexPath
            )
        }

        guard
            kind == UICollectionView.elementKindSectionHeader,
            emojiSections.indices.contains(indexPath.section),
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: ChatGifPanelEmojiHeaderView.reuseIdentifier,
                for: indexPath
            ) as? ChatGifPanelEmojiHeaderView
        else {
            return UICollectionReusableView()
        }

        header.configure(title: emojiSections[indexPath.section].title, color: secondaryTextColor)
        return header
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        if collectionView === recentsCollectionView {
            return (collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize
                ?? CGSize(width: 96, height: 96)
        }

        let columns: CGFloat = bounds.width < 360 ? 7 : 8
        let horizontalPadding: CGFloat = 24
        let spacing: CGFloat = 8 * (columns - 1)
        let width = floor((collectionView.bounds.width - horizontalPadding - spacing) / columns)
        return CGSize(width: max(34, width), height: max(40, width))
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        guard collectionView === emojiCollectionView,
              emojiSections.indices.contains(section) else {
            return .zero
        }
        let title = emojiSections[section].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? .zero : CGSize(width: collectionView.bounds.width, height: 36)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === pagesScrollView {
            guard !isProgrammaticPageScroll, pagesScrollView.bounds.width > 1 else { return }
            let page = Int(round(pagesScrollView.contentOffset.x / pagesScrollView.bounds.width))
            guard let tab = ChatGifPanelTab(rawValue: page), tab != activeTab else { return }
            activeTab = tab
            updateTabButtonSelection()
            if tab == .stickers { ensureStickerPackSelection() }
            // Refresh strip/search for the page without re-animating pager.
            rebuildSearchChrome()
            rebuildTopStripButtons()
            switch tab {
            case .gifs:
                if panelVisible { installEmbeddedPickerIfNeeded() }
                updateEmbeddedPickerContent(showLoading: false)
            case .stickers:
                applyStickerPanelState()
            case .emoji:
                rebuildEmojiSections()
            }
            observeActivePageScroll()
            if searchField.isFirstResponder { setSearchExpanded(true) }
            return
        }

        // Vertical content scroll → header translateY + fade
        if scrollView === emojiCollectionView
            || scrollView === stickerPackPanel.contentScrollView
            || scrollView === findScrollView(in: mediaContainerView)
        {
            updateHeaderForScroll(scrollView)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === pagesScrollView {
            observeActivePageScroll()
        }
    }

    private func observeActivePageScroll() {
        contentOffsetObservation?.invalidate()
        contentOffsetObservation = nil
        let target: UIScrollView?
        switch activeTab {
        case .gifs:
            target = findScrollView(in: mediaContainerView)
        case .stickers:
            target = stickerPackPanel.contentScrollView
        case .emoji:
            target = emojiCollectionView
        }
        guard let target else {
            headerView.transform = .identity
            headerView.alpha = 1
            headerView.isUserInteractionEnabled = true
            return
        }
        updateHeaderForScroll(target)
        contentOffsetObservation = target.observe(\.contentOffset, options: [.new]) {
            [weak self] sv, _ in
            self?.updateHeaderForScroll(sv)
        }
    }
}

#if canImport(GiphyUISDK)
    extension ChatGifPanelView: GPHGridDelegate {
        func contentDidUpdate(resultCount: Int, error: (any Error)?) {
            print(
                "[NativeGif][iOS] contentDidUpdate resultCount=\(resultCount) error=\(error != nil)"
            )
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
            if activeTab != .emoji {
                stateLabel.isHidden = true
            }
        }

        func didSelectMedia(media: GPHMedia, cell: UICollectionViewCell) {
            emitSelection(media: media, cell: cell)
        }

        func didSelectMoreByYou(query: String) {}

        func didScroll(offset: CGFloat) {
            // Header is hosted inside the scroll view itself, so no manual sync is needed.
        }

        func errorDidOccur(_ error: any Error) {
            print("[NativeGif][iOS] grid error: \(error.localizedDescription)")
            showStateLabel("Unable to load \(activeTab.title.lowercased()) right now.")
        }

        func syntheticErrorDidOccur() {
            print("[NativeGif][iOS] grid synthetic error")
            showStateLabel("Unable to load \(activeTab.title.lowercased()) right now.")
        }

        private func emitSelection(media: GPHMedia, cell: UICollectionViewCell) {
            let images = media.images
            let primaryImage = resolvedPrimaryImage(from: images)
            let normalizedMediaID = media.id.isEmpty ? UUID().uuidString.lowercased() : media.id
            let primaryURL = normalizedNonEmptyString(primaryImage?.gifUrl)

            guard
                let url = primaryURL
            else {
                guard let fallbackUrl = normalizedNonEmptyString(media.url) else { return }
                let localData = localGifData(from: cell, renditionURL: fallbackUrl)
                delegate?.chatGifPanel(
                    self,
                    didSelectGif: ChatGifSelection(
                        id: normalizedMediaID,
                        url: fallbackUrl,
                        previewUrl: fallbackUrl,
                        width: 0,
                        height: 0,
                        localData: localData
                    )
                )
                return
            }

            let previewUrl = resolvedPreviewURL(
                from: images,
                primaryImage: primaryImage,
                fallbackURL: url
            )
            let localData = localGifData(from: cell, renditionURL: url)

            delegate?.chatGifPanel(
                self,
                didSelectGif: ChatGifSelection(
                    id: normalizedMediaID,
                    url: url,
                    previewUrl: previewUrl,
                    width: primaryImage?.width ?? 0,
                    height: primaryImage?.height ?? 0,
                    localData: localData
                )
            )
        }
    }
#endif

// MARK: - ChatStickerPackPanelDelegate

extension ChatGifPanelView: ChatStickerPackPanelDelegate {
    func stickerPackPanel(
        _ panel: ChatStickerPackPanel, didSelectSticker sticker: ChatStickerSelection
    ) {
        delegate?.chatGifPanel(self, didSelectSticker: sticker)
    }
}
