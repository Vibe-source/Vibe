import UIKit

enum ChatImageEditEventType: String {
  case reply = "mediaReplyRequested"
  case edit = "mediaEditRequested"
  case resend = "mediaResendRequested"
  case sendNew = "mediaSendNewRequested"
  case showInChat = "mediaShowInChatRequested"
  case delete = "mediaDeleteRequested"
  /// Forward inside the app — the chat's own share sheet, not the system one.
  case share = "mediaShareRequested"
}

struct ChatImageEditActionPayload {
  let eventType: ChatImageEditEventType
  let messageId: String?
  let mediaURL: String
  let caption: String?
  let editedImageURL: URL?
}

/// One page in the native image open sheet (single image or multi-image set).
struct ChatImageEditGalleryPage {
  let mediaURL: String
  let image: UIImage?
  /// Message id this page came from — swiping across a chat moves between
  /// messages, so the action menu has to follow the photo, not the opener.
  let messageId: String?
  /// Second header line (the message date, as in the reference).
  let subtitle: String?

  init(
    mediaURL: String, image: UIImage?, messageId: String? = nil, subtitle: String? = nil
  ) {
    self.mediaURL = mediaURL
    self.image = image
    self.messageId = messageId
    self.subtitle = subtitle
  }
}

enum ChatImageEditModule {
  static func presentEditor(
    from presenter: UIViewController,
    sourceView: UIView? = nil,
    messageId: String?,
    mediaURL: String,
    initialImage: UIImage?,
    initialCaption: String?,
    headerTitle: String? = nil,
    headerSubtitle: String? = nil,
    dismissPresenterOnSend: Bool = false,
    galleryPages: [ChatImageEditGalleryPage] = [],
    startIndex: Int = 0,
    /// When true, open directly in markup mode (draw/text). Default is view-only until Edit.
    startInEditMode: Bool = false,
    /// Only a multi-image *message* gets the thumbnail strip; swiping across a
    /// whole chat would turn it into a scroll bar for hundreds of photos.
    allowsFilmstrip: Bool = true,
    /// Supplies the cell the photo should grow out of and shrink back into. Held
    /// weakly by the transition, so the chat owning it is enough to keep it alive.
    zoomSourceProvider: ChatMediaZoomSourceProviding? = nil,
    onAction: @escaping (ChatImageEditActionPayload) -> Void
  ) {
    let pages: [ChatImageEditGalleryPage] = {
      if galleryPages.count > 1 { return galleryPages }
      if !galleryPages.isEmpty { return galleryPages }
      return [ChatImageEditGalleryPage(mediaURL: mediaURL, image: initialImage)]
    }()
    let controller = ChatImageEditViewController(
      messageId: messageId,
      mediaURL: mediaURL,
      initialImage: initialImage,
      initialCaption: initialCaption,
      headerTitle: headerTitle,
      headerSubtitle: headerSubtitle,
      dismissPresenterOnSend: dismissPresenterOnSend,
      galleryPages: pages,
      startIndex: startIndex,
      startInEditMode: startInEditMode,
      allowsFilmstrip: allowsFilmstrip
    )
    controller.modalPresentationStyle = .overFullScreen
    _ = sourceView
    let transition = ChatMediaZoomTransition()
    transition.sourceProvider = zoomSourceProvider
    controller.zoomTransition = transition
    controller.transitioningDelegate = transition
    controller.onAction = onAction
    presenter.present(controller, animated: true)
  }
}
