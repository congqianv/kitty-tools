// 横向剪贴板卡片：NSCollectionView 只创建可见项；卡片复用现有模型的点击、拖出、菜单、预览与粘贴。
// 搜索框一直拿着键盘，集合视图只负责布局和滚动，不另存一套选中状态，不读写剪贴板或数据库。

import AppKit
import SwiftUI

struct ClipboardCards: NSViewRepresentable {
  let model: ClipboardPanelModel
  let items: [ClipItem]
  let selectedID: UUID?
  let showsPreview: Bool
  let imageRows: Bool
  let showsShortcuts: Bool
  @AppStorage(Prefs.clipboardLinkPreview) private var linkPreview = true
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = CardScrollView()
    let layout = NSCollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = 16
    layout.minimumInteritemSpacing = 16
    layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    let collection = CardCollectionView()
    collection.collectionViewLayout = layout
    collection.backgroundColors = [.clear]
    collection.isSelectable = false
    collection.dataSource = context.coordinator
    collection.delegate = context.coordinator
    collection.didLayOut = { [weak coordinator = context.coordinator] in
      coordinator?.reportCardFrame()
    }
    collection.register(CardItem.self, forItemWithIdentifier: CardItem.identifier)
    scroll.documentView = collection
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = .automatic
    scroll.verticalScrollElasticity = .none
    scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.collection = collection
    context.coordinator.observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak coordinator = context.coordinator] _ in
      MainActor.assumeIsolated { coordinator?.reportCardFrame() }
    }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    guard let collection = coordinator.collection else { return }
    let newSnippet = model.showsNewSnippetRow(in: items)
    let changed = coordinator.items != items || coordinator.newSnippet != newSnippet
    let reveal =
      changed || coordinator.selectedID != selectedID
      || coordinator.generation != model.listGeneration
    coordinator.parent = self
    coordinator.selectedID = selectedID
    coordinator.generation = model.listGeneration
    coordinator.newSnippet = newSnippet
    collection.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    if changed {
      coordinator.items = items
      coordinator.indices = Dictionary(
        uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
      coordinator.days = Dictionary(
        uniqueKeysWithValues: ClipboardPanelView.daySections(items).flatMap { section in
          section.rows.map { ($0.element.id, section.title) }
        })
      collection.reloadData()
    }
    // 不在 SwiftUI 更新的半途回写 model；布局完成后再让新选中的卡片露出来、报告预览起点。
    coordinator.needsReveal = coordinator.needsReveal || reveal
    coordinator.refresh?.cancel()
    coordinator.refresh = Task { @MainActor [weak coordinator] in
      await Task.yield()
      guard !Task.isCancelled, let coordinator, let collection = coordinator.collection else {
        return
      }
      collection.layoutSubtreeIfNeeded()
      if coordinator.needsReveal, let id = coordinator.selectedID,
        let index = coordinator.indices[id]
      {
        collection.scrollToItems(
          at: [IndexPath(item: index + (coordinator.newSnippet ? 1 : 0), section: 0)],
          scrollPosition: .nearestVerticalEdge)
      }
      coordinator.needsReveal = false
      coordinator.parent.model.settleList()
      for cell in collection.visibleItems() {
        guard let cell = cell as? CardItem, let path = collection.indexPath(for: cell) else {
          continue
        }
        coordinator.configure(cell, at: path)
      }
      coordinator.reportCardFrame()
    }
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.refresh?.cancel()
    if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    coordinator.observer = nil
    coordinator.collection?.dataSource = nil
    coordinator.collection?.delegate = nil
  }

  /// 拖高时卡片跟着长大，一行始终只放一张卡片的高度，避免 FlowLayout 意外排成两行。
  static func cardSize(in height: CGFloat) -> NSSize {
    let side = max(120, height - 24)
    return NSSize(width: min(max(side, 260), 380), height: side)
  }

  final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var parent: ClipboardCards
    weak var collection: NSCollectionView?
    var items: [ClipItem] = []
    var indices: [UUID: Int] = [:]
    var days: [UUID: String] = [:]
    var selectedID: UUID?
    var generation = -1
    var needsReveal = false
    var newSnippet = false
    var observer: NSObjectProtocol?
    var refresh: Task<Void, Never>?

    init(_ parent: ClipboardCards) { self.parent = parent }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
      -> Int
    {
      items.count + (newSnippet ? 1 : 0)
    }

    func collectionView(
      _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
      let cell = collectionView.makeItem(withIdentifier: CardItem.identifier, for: indexPath)
      if let cell = cell as? CardItem { configure(cell, at: indexPath) }
      return cell
    }

    fileprivate func configure(_ cell: CardItem, at path: IndexPath) {
      if newSnippet && path.item == 0 {
        cell.setContent(
          AnyView(
            Button { [model = parent.model] in
              model.dialog = .newSnippet
            } label: {
              VStack(spacing: 12) {
                Image(systemName: "plus").font(.system(size: 28, weight: .light))
                Text("新建片段").font(.system(size: 14, weight: .medium))
                KeyCap("⌘N")
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(Style.controlFill, in: .rect(cornerRadius: Style.Radius.panel))
              .contentShape(.rect)
            }.buttonStyle(.plain)
          ))
        return
      }
      let index = path.item - (newSnippet ? 1 : 0)
      guard items.indices.contains(index) else { return }
      let item = items[index]
      cell.setContent(
        AnyView(
          ClipboardCard(
            item: item, model: parent.model, index: index, day: days[item.id] ?? "",
            selected: item.id == parent.selectedID, showsPreview: parent.showsPreview,
            imageRows: parent.imageRows, showsShortcuts: parent.showsShortcuts,
            allowsLinkPreview: parent.linkPreview
          )
          .id(item.id)
        ))
    }

    func reportCardFrame() {
      guard let collection, let id = selectedID, let index = indices[id],
        let attributes = collection.layoutAttributesForItem(
          at: IndexPath(item: index + (newSnippet ? 1 : 0), section: 0)),
        let content = collection.window?.contentView
      else { return }
      let visible = attributes.frame.intersection(collection.visibleRect)
      guard !visible.isEmpty else {
        if parent.model.cardFrame?.id == id { parent.model.cardFrame = nil }
        return
      }
      let rect = collection.convert(visible, to: content)
      let topDown = CGRect(
        x: rect.minX, y: content.isFlipped ? rect.minY : content.bounds.height - rect.maxY,
        width: rect.width, height: rect.height)
      if parent.model.cardFrame?.id != id || parent.model.cardFrame?.rect != topDown {
        parent.model.cardFrame = (id, topDown)
      }
    }
  }
}

private final class CardCollectionView: NSCollectionView {
  var didLayOut: (() -> Void)?
  override var acceptsFirstResponder: Bool { false }

  override func layout() {
    if let layout = collectionViewLayout as? NSCollectionViewFlowLayout,
      let height = enclosingScrollView?.contentSize.height
    {
      let size = ClipboardCards.cardSize(in: height)
      if layout.itemSize != size { layout.itemSize = size }
    }
    super.layout()
    // 首次 updateNSView 可能早于加入窗口；真正排完再报告，预览不能拿到空的起点。
    DispatchQueue.main.async { [weak self] in self?.didLayOut?() }
  }
}

private final class CardScrollView: NSScrollView {
  override func scrollWheel(with event: NSEvent) {
    // 普通鼠标只有纵向滚轮，把它映射到卡片轨道；触控板的水平滚动和惯性仍由 AppKit 处理。
    guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let documentView else {
      super.scrollWheel(with: event)
      return
    }
    let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 24)
    let limit = max(0, documentView.bounds.width - contentSize.width)
    contentView.scroll(to: NSPoint(x: min(max(contentView.bounds.minX - delta, 0), limit), y: 0))
    reflectScrolledClipView(contentView)
  }
}

private final class CardItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("ClipboardCard")
  private var host: CardHost?

  override func loadView() { view = NSView() }

  func setContent(_ content: AnyView) {
    if let host {
      host.rootView = content
    } else {
      let host = CardHost(rootView: content)
      host.sizingOptions = []
      host.frame = view.bounds
      host.autoresizingMask = [.width, .height]
      view.addSubview(host)
      self.host = host
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    host?.rootView = AnyView(EmptyView())
  }
}

/// 非激活浮层里的第一下点击也执行，鼠标选卡片后键盘仍留在搜索框。
private final class CardHost: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var acceptsFirstResponder: Bool { false }
}

private struct ClipboardCard: View {
  let item: ClipItem
  let model: ClipboardPanelModel
  let index: Int
  let day: String
  let selected: Bool
  let showsPreview: Bool
  let imageRows: Bool
  let showsShortcuts: Bool
  let allowsLinkPreview: Bool
  @GestureState private var dragging = false
  @State private var hovered = false

  private var form: ContentForm? { model.contentForm(of: item) }
  private var checked: Bool { model.multiSelection.contains(item.id) }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.panel, style: .continuous)
    Button {
      model.click(item)
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        header.padding(.horizontal, 12).padding(.vertical, 8)
          .background(Style.Family.clipboard.opacity(0.12))
        GeometryReader { geometry in
          content
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .padding(12)
        .layoutPriority(-1)
        footer.padding(.horizontal, 12).padding(.bottom, 8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .controlBackgroundColor), in: shape)
      .overlay { if hovered && !selected { shape.fill(Style.hoverFill) } }
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(
          selected || checked ? Style.brand : Color(nsColor: .separatorColor),
          lineWidth: selected || checked ? 2 : 1)
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .contextMenu { ActionContextMenu { model.actions(for: item, targets: [item]) } }
    .simultaneousGesture(
      DragGesture(minimumDistance: 6).updating($dragging) { _, started, _ in
        guard !started else { return }
        started = true
        ClipDrag.begin(
          model.dragItems(for: item),
          previews: [ClipDrag.preview(item, form: form, images: model.store.images)]
        ) { [model] in if !model.isPinned { model.hidePanel() } }
      }
    )
    .background { HoverTracker { hovered = $0 } }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(item.title)
    .accessibilityValue(Lens.accessibilityValue(for: item, form: form))
    .accessibilityAddTraits(selected || checked ? [.isSelected, .isButton] : .isButton)
    .accessibilityAction { model.select(item) }
    .accessibilityAction(named: "粘贴") { model.paste([item]) }
    .accessibilityAction(named: "放大预览") {
      model.select(item)
      model.toggleQuickLook()
    }
    .accessibilityAction(named: item.favorite ? "取消收藏" : "收藏") { model.toggleFavorite([item.id]) }
  }

  private var header: some View {
    HStack(spacing: 8) {
      if let icon = AppIcons.icon(for: item.sourceBundleID) {
        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
      } else {
        Image(systemName: form?.symbol ?? item.kind.symbol).frame(width: 24, height: 24)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(Lens.typeTitle(item, form: form)).font(.system(size: 13, weight: .semibold))
        if let source = item.sourceTitle {
          Text(source).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if checked {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Style.brand)
      } else if item.favorite {
        Image(systemName: "star.fill").foregroundStyle(Style.brandInk)
      }
      if showsShortcuts && index < 9 { KeyCap("⌘\(index + 1)") }
    }
  }

  @ViewBuilder private var content: some View {
    if item.kind == .image && imageRows {
      ThumbnailView(
        id: item.id, images: model.store.images, maxPixel: ThumbnailView.lensPixel,
        contentMode: .fit
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Checkerboard())
      .clipped()
    } else if showsPreview && item.kind != .image {
      LensView(item: item, form: form, model: model, selected: selected && allowsLinkPreview)
    } else {
      Text(excerpt)
        .font(.system(size: 13, design: form == .code || form == .json ? .monospaced : .default))
        .foregroundStyle(Lens.ink)
        .lineSpacing(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
  }

  private var excerpt: AttributedString {
    // 卡片只排有限长度的摘要；完整富文本、代码与文件预览仍由空格 / ⌘Y 的检查器展示。
    let text = showsPreview ? model.displayText(of: item) : item.title
    let source = String(text.prefix(20_000))
    let shown =
      Search.excerpt(of: source, query: model.query, before: 40, after: 600)
      ?? String(source.prefix(640))
    var value = AttributedString(shown.isEmpty ? item.title : shown)
    value.highlight(model.query)
    return value
  }

  private var footer: some View {
    HStack(spacing: 6) {
      if item.isSnippet { Image(systemName: "text.badge.star").help("片段") }
      if let note = item.note, !note.isEmpty {
        Text(note).lineLimit(1)
      } else if let group = model.store.groups.first(where: { $0.id == item.groupID }) {
        Text(group.name).lineLimit(1)
      } else if let image = item.image {
        Text(verbatim: "\(image.width)×\(image.height)").lineLimit(1)
      } else {
        Text(day).lineLimit(1)
      }
      Spacer(minLength: 0)
      Text(item.copiedAt, format: .dateTime.hour().minute()).monospacedDigit()
    }
    .font(.system(size: 10))
    .foregroundStyle(.secondary)
  }
}
