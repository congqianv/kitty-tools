// 剪贴板卡片面板：顶部胶囊搜索、筛选和操作，下面只放横向复用的内容卡片。
// 数据、搜索、片段展开、撤销和粘贴都交给 ClipboardPanelModel；窗口仍用不激活前台的 OverlayPanel。
// 高度与条数、当前选中项无关；顶部拖边改变卡片大小，菜单和编辑对话框打开时临时扩高。

import SwiftUI

struct ClipboardPanelView: View {
  /// day = 那天的零点：分组和行的身份按它，不按标题（过了午夜「今天」改叫「昨天」，还是同一组、同一批行）
  typealias DaySection = (day: Date, title: String, rows: [(offset: Int, element: ClipItem)])
  /// 列表的第一条和条数：新条目进来的信号（itemsChanged）
  private struct FirstAndCount: Equatable {
    var id: UUID?
    var count: Int
  }

  @Bindable var model: ClipboardPanelModel
  @AppStorage(Prefs.clipboardHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.clipboardShowPreview) private var showsLens = true
  /// 图片卡片显示缩略图；关掉时显示图片信息，完整预览仍然可用。
  @AppStorage(Prefs.clipboardImageRows) private var imageRows = true
  /// 沿用旧的大小偏好：0 = 默认卡片大小。
  @AppStorage(Prefs.clipboardPanelRows) private var maxRows = 0.0
  /// 默认粘贴为纯文本：顶部状态区按住 ⌥ 的提示、右键菜单的替代粘贴跟着换名字
  @AppStorage(Prefs.clipboardPastePlain) private var pastesPlain = false
  @State private var trusted = Permissions.isAccessibilityTrusted
  /// 正按着的 ⌘ / ⌥
  @State private var heldKeys: EventModifiers = []
  /// 按住超过 150 ms 才算「按住」（S4）：⌘ 亮出 ⌘1–9 键帽，⌘ / ⌥ 把顶部状态区左边换成对应的替代动作。
  /// 按 ⌘K、⌘D 这类组合键时一闪而过的 ⌘ 不换，顶部状态区不闪；松开立刻收
  @State private var shownKeys: EventModifiers = []
  /// 菜单锚点来自按钮的实际位置，不假定搜索栏居中或窗口宽度固定。
  @State private var filterButtonFrame = CGRect.zero
  @State private var actionsButtonFrame = CGRect.zero
  @State private var groupsButtonFrame = CGRect.zero
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 截图自检和非停靠位置的默认宽度；停靠时按当前屏幕可见宽度铺开。
  static let width: CGFloat = 1100
  static let searchHeight: CGFloat = 56
  static let statusHeight: CGFloat = 32
  static let bannerHeight: CGFloat = 30
  /// 浮起菜单距面板边缘的最小留白。
  static let inset: CGFloat = 6
  /// 默认卡片区高度（包含卡片四周留白）。
  static let maxListHeight: CGFloat = 324
  /// 沿用旧版大小档位，避免改动同步 / 导出格式；每档对应 20 pt。
  static let rowRange = 6.5...14.5

  /// 列表区最高多高：拖出来的行数（0 = 默认）每多一行加一行高
  static func maxListHeight(rows: Double) -> CGFloat {
    rows > 0
      ? maxListHeight + CGFloat(min(max(rows, rowRange.lowerBound), rowRange.upperBound) - 8.5) * 20
      : maxListHeight
  }

  /// 面板里列表区以外的高度：搜索栏、发丝线、授权横幅、顶部状态区
  static func chrome(banner: Bool) -> CGFloat {
    searchHeight + 0.5 + (banner ? bannerHeight : 0)
  }

  /// 顶部拖边可调整的高度范围，沿用旧版大小档位。
  static func heightRange(banner: Bool) -> ClosedRange<CGFloat> {
    chrome(banner: banner) + maxListHeight(rows: rowRange.lowerBound)...chrome(banner: banner)
      + maxListHeight(rows: rowRange.upperBound)
  }

  /// 拖到这么高对应最多几行：按半行吸附，夹在 rowRange 里（纯函数，配单测）
  static func rows(forHeight height: CGFloat, banner: Bool) -> Double {
    let rows = 8.5 + Double((height - chrome(banner: banner) - maxListHeight) / 20)
    return min(max((rows - 0.5).rounded() + 0.5, rowRange.lowerBound), rowRange.upperBound)
  }
  /// 筛选面板 / ⌘K 开着时列表区至少这么高（8.5 行菜单 + 上下余量），短列表时面板先长到放得下
  static let paletteListHeight: CGFloat = ActionMenu.rowHeight * 8.5 + 26
  /// 面板根视图的坐标系（多选顶部状态区按钮报位置用）
  nonisolated private static let space = "clipboardPanel"

  var body: some View {
    let items = model.visibleItems
    let selected = model.selectedItem(in: items)
    VStack(spacing: 0) {
      header(count: items.count)
      Hairline()
      if !trusted { permissionBanner }
      cardArea(items, selected: selected)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { DialogOverlay(model: model) }
    }
    .overlay(alignment: .topLeading) {
      GeometryReader { geometry in
        if let palette = model.palette {
          let button =
            palette == .filters
            ? filterButtonFrame
            : palette == .actions ? actionsButtonFrame : groupsButtonFrame
          let below =
            Self.chrome(banner: !trusted)
            + (showsStatus(count: items.count) ? Self.statusHeight : 0)
          let origin = Self.menuOrigin(
            button: button, panelWidth: geometry.size.width, below: below)
          ActionMenu(
            items: model.filteredActions, selection: model.actionSelection,
            emptyText: palette == .filters
              ? "没有匹配的筛选"
              : palette == .groups || model.submenuTitle != nil ? "没有匹配的收藏夹" : "没有匹配的操作",
            header: palette == .actions ? model.submenuTitle : nil,
            onBack: model.leaveSubmenu, anchor: .topTrailing, maxRows: 8.5,
            onHover: { model.actionSelection = $0 }, onRun: model.run
          )
          .offset(x: origin.x, y: origin.y)
        }
      }
    }
    .animation(
      Style.Motion.snap.animation(reduced: reduceMotion) ?? .easeOut(duration: Style.fadeIn),
      value: model.palette
    )
    .onChange(
      of: Self.height(
        for: model, banner: !trusted, maxRows: maxRows,
        showsModifiers: !shownKeys.isEmpty && !items.isEmpty),
      initial: true
    ) { _, height in model.resize(height) }
    .onModifierKeysChanged(mask: [.command, .option]) { _, keys in heldKeys = keys }
    .task(id: heldKeys) {
      shownKeys.formIntersection(heldKeys)
      try? await Task.sleep(for: .milliseconds(150))
      if !Task.isCancelled { shownKeys = heldKeys }
    }
    // 第一条和条数一起看：图片按复制时间插到第 2 条时第一条没变（第四轮体检 E24①）
    .onChange(of: FirstAndCount(id: model.store.items.first?.id, count: model.store.items.count)) {
      model.itemsChanged()
    }
    .coordinateSpace(.named(Self.space))
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
    }
  }

  // MARK: 高度

  /// 原来的行数偏好继续表示大小档位，不迁移数据；空态、筛选和换条目不改变卡片区高度。
  static func height(
    for model: ClipboardPanelModel,
    showsLens: Bool = UserDefaults.standard.bool(forKey: Prefs.clipboardShowPreview),
    banner: Bool = !Permissions.isAccessibilityTrusted,
    maxRows: Double = UserDefaults.standard.double(forKey: Prefs.clipboardPanelRows),
    imageRows: Bool = UserDefaults.standard.bool(forKey: Prefs.clipboardImageRows),
    showsModifiers: Bool = false
  ) -> CGFloat {
    let content = maxListHeight(rows: maxRows)
    let minimum: CGFloat = model.dialog != nil ? 420 : model.palette != nil ? paletteListHeight : 0
    let status: CGFloat =
      model.toast != nil || !model.multiSelection.isEmpty || showsModifiers
      ? statusHeight : 0
    return chrome(banner: banner) + status + max(content, minimum)
  }

  /// 菜单的右缘跟着触发按钮，且不越过面板两侧；始终在搜索 / 操作区下面。
  static func menuOrigin(button: CGRect, panelWidth: CGFloat, below: CGFloat) -> CGPoint {
    CGPoint(
      x: min(
        max(button.maxX - ActionMenu.width, inset),
        max(inset, panelWidth - ActionMenu.width - inset)),
      y: max(button.maxY + 6, below + 4))
  }

  private func showsStatus(count: Int) -> Bool {
    model.toast != nil || !model.multiSelection.isEmpty || (count > 0 && !shownKeys.isEmpty)
  }

  private func header(count: Int) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        searchBar.frame(minWidth: 180, maxWidth: .infinity)
        if !showsStatus(count: count) {
          barStatus(count: count).fixedSize(horizontal: true, vertical: false)
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        actionButtons(count: count).fixedSize(horizontal: true, vertical: false)
      }
      .padding(.horizontal, 16)
      .frame(height: Self.searchHeight)
      if showsStatus(count: count) {
        ScrollView(.horizontal, showsIndicators: false) {
          barStatus(count: count)
            .disabled(model.dialog != nil && model.toast == nil)
            .font(.system(size: 12)).foregroundStyle(.secondary).buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.statusHeight)
      }
    }
  }

  // MARK: 搜索线

  private var searchBar: some View {
    let tokens = model.tokens
    return HStack(spacing: 10) {
      SearchLine(symbol: searchSymbol) {
        ForEach(tokens) { token in
          TokenChip(
            token: token, armed: model.armsLastToken && token.id == tokens.last?.id,
            open: { model.palette = .filters }, remove: { model.remove(token.kind) }
          )
          .disabled(model.dialog != nil)
          .transition(.opacity)
        }
        CommandTextField(
          text: model.palette != nil ? $model.actionQuery : $model.query,
          placeholder: placeholder, fontSize: 15, onCommand: model.handleCommand,
          onSpace: model.handleSpace
        )
        .frame(minWidth: 100, maxWidth: .infinity)
      }
      .frame(height: 36)
      .background(Style.inputFill, in: .capsule)
      .frame(maxWidth: 720)
      Button {
        model.palette = model.palette == .filters ? nil : .filters
      } label: {
        Image(systemName: "line.3.horizontal.decrease").frame(width: 32, height: 32)
      }
      .buttonStyle(.plain)
      .help("筛选范围、收藏夹、类型、来源")
      .accessibilityLabel("筛选范围、收藏夹、类型、来源")
      .accessibilityAddTraits(model.palette == .filters ? .isSelected : [])
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .named(Self.space))
      } action: {
        filterButtonFrame = $0
      }
      .disabled(model.dialog != nil)
    }
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: tokens.map(\.id))
    .frame(height: 36)
  }

  private var searchSymbol: String {
    switch model.palette {
    case .filters: "line.3.horizontal.decrease"
    case .actions: "command"
    case .groups: "folder"
    case nil: "magnifyingglass"
    }
  }

  private var placeholder: String {
    let text: LocalizedStringResource =
      switch model.palette {
      case .filters: "筛选范围、收藏夹、类型、来源"
      // 子列表只有「移到收藏夹」这一个
      case .actions: model.submenuTitle == nil ? "搜索操作" : "搜索收藏夹"
      case .groups: "搜索收藏夹"
      case nil: model.tokens.isEmpty ? "搜索剪贴板，Tab 筛选" : "搜索"
      }
    return String(localized: text)
  }

  private var permissionBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "lock.shield").foregroundStyle(Color(nsColor: .systemOrange))
      Text("授权「辅助功能」后才能直接粘贴回原 App，现在只会写进剪贴板")
      Spacer()
      // 没问过只弹系统框、问过了才打开系统设置（第五轮体检 U11：原来两样一起来）
      Button("去授权") { Permissions.grant(.accessibility) }
        .buttonStyle(.plain)
        .foregroundStyle(Style.brandInk)
        .pointerStyle(.link)
    }
    .font(.system(size: 12))
    .lineLimit(1)
    .padding(.horizontal, 16)
    .frame(height: Self.bannerHeight)
    .background(Color(nsColor: .systemOrange).opacity(0.08))
  }

  // MARK: 卡片

  @ViewBuilder private func cardArea(_ items: [ClipItem], selected: ClipItem?) -> some View {
    if items.isEmpty && !model.showsNewSnippetRow(in: items) {
      emptyState
    } else {
      ClipboardCards(
        model: model, items: items, selectedID: selected?.id,
        showsPreview: showsLens, imageRows: imageRows,
        showsShortcuts: shownKeys.contains(.command))
    }
  }

  /// 按天分组：今天 / 昨天 / M月d日 / yyyy年M月d日（有搜索词时也是，标题后的数字就是命中条数）。
  /// 行号是在整个列表里的序号（⌘数字用）。列表按复制时间新→旧，同一天是连续的：只在换天时算零点、格式化一次，
  /// 落在当前这组那天里的直接归进去（每条都算 startOfDay 的话 800 条要 3 ms，每次按键都重算一遍）
  static func daySections(_ items: [ClipItem]) -> [DaySection] {
    let calendar = Calendar.current
    var sections: [DaySection] = []
    var day: Range<Date>?
    for row in items.enumerated() {
      if let day, day.contains(row.element.copiedAt) {
        sections[sections.count - 1].rows.append(row)
      } else {
        let start = calendar.startOfDay(for: row.element.copiedAt)
        day = start..<(calendar.date(byAdding: .day, value: 1, to: start) ?? .distantFuture)
        // 标题规则和翻译历史同一个纯函数（有单测）
        sections.append((start, HistoryView.dayTitle(start, now: .now, calendar: calendar), [row]))
      }
    }
    return sections
  }

  // MARK: 空态

  /// 共用的空状态（Shell/Style 的 EmptyState）：28 pt 符号 + 14 semibold 标题 + 说明 / 品牌粉文字按钮
  @ViewBuilder private var emptyState: some View {
    if model.isEmptyGroup {
      EmptyState(symbol: "folder", title: "这个收藏夹还是空的") {
        Text("在别的条目上按 ⌘K，选「移到收藏夹」放进来").foregroundStyle(.secondary)
      }
    } else if model.isFiltered {
      EmptyState(symbol: "magnifyingglass", title: "没有匹配的条目") {
        Button("清除搜索和筛选", action: model.clearSearchAndFilters)
          .buttonStyle(.plain)
          .foregroundStyle(Style.brandInk)
          .pointerStyle(.link)
      }
    } else if model.scope == .favorites {
      EmptyState(symbol: "star", title: "还没有收藏") {
        Text("选中条目按 ⌘D 收藏；收藏不受保留天数影响").foregroundStyle(.secondary)
      }
    } else {
      EmptyState(symbol: "doc.on.clipboard", title: "还没有剪贴板历史") {
        Text("复制的文本、图片和文件会出现在这里").foregroundStyle(.secondary)
      }
    }
  }

  // MARK: 顶部操作

  private func actionButtons(count: Int) -> some View {
    HStack(spacing: 12) {
      if barState(count: count) == "count" {
        UpdateBarHint { model.hidePanel() }.disabled(model.dialog != nil)
      }
      Group {
        if count > 0 {
          if model.multiSelection.isEmpty {
            Button {
              model.pasteSelection()
            } label: {
              hint("粘贴", key: "↩", primary: true)
            }
            .help("粘贴到当前 App（↩）")
          }
          Button {
            model.palette = model.palette == .actions ? nil : .actions
          } label: {
            hint("操作", key: "⌘K")
          }
          .help("全部操作（⌘K）")
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Self.space))
          } action: {
            actionsButtonFrame = $0
          }
          Hairline(vertical: true).frame(height: 16)
        }
        Button("剪贴板设置", systemImage: "gearshape", action: model.openSettings)
          .labelStyle(.iconOnly)
          .help("剪贴板设置（⌘,）")
        // 固定只管点外面不收起（Esc、⌘W 照样关）；和 ⌘P 同一个开关，顶部状态区就地提示
        Button(
          hideOnUnfocus ? "固定面板" : "取消固定", systemImage: hideOnUnfocus ? "pin" : "pin.fill",
          action: model.togglePinned
        )
        .labelStyle(.iconOnly)
        .foregroundStyle(hideOnUnfocus ? AnyShapeStyle(.secondary) : AnyShapeStyle(Style.brandInk))
        .contentTransition(.symbolEffect(.replace))
        .help(hideOnUnfocus ? "固定面板（⌘P）" : "取消固定（⌘P）")
        .accessibilityAddTraits(hideOnUnfocus ? [] : .isSelected)
      }
      .disabled(model.dialog != nil)
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .buttonStyle(.plain)
  }

  /// 顶部状态区左边现在显示哪一种（换的时候 blurReplace）
  private func barState(count: Int) -> String {
    if let toast = model.toast { return "toast \(toast)" }
    if !model.multiSelection.isEmpty { return "multi" }
    if count > 0, shownKeys.contains(.option) { return "option" }
    if count > 0, shownKeys.contains(.command) { return "command" }
    return "count"
  }

  @ViewBuilder private func barStatus(count: Int) -> some View {
    if let toast = model.toast {
      BarNoticeView(notice: toast, undo: model.undoDelete)
    } else if !model.multiSelection.isEmpty {
      multiSelectVerbs
    } else if count > 0, shownKeys.contains(.option) {
      Button {
        model.pasteSelection(plainText: !pastesPlain)
      } label: {
        hint(model.alternatePasteTitle, key: "⌥↩", leadingKey: true)
      }
    } else if count > 0, shownKeys.contains(.command) {
      HStack(spacing: 12) {
        Button(action: { model.copySelection() }) {
          hint("仅复制", key: "⌘↩", leadingKey: true)
        }
        Text("·").foregroundStyle(.tertiary)
        HStack(spacing: 6) {
          KeyCap("⌘1–9")
          Text("直接粘贴")
        }
      }
    } else {
      HStack(spacing: 8) {
        // 菜单栏「暂停记录剪贴板」开着（D4）：复制的东西不会出现在这里，说一声
        if model.isRecordingPaused {
          Label("已暂停记录", systemImage: "pause.circle")
          Text("·").foregroundStyle(.tertiary)
        }
        Text(countText(count))
          .contentTransition(.numericText())
          .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: count)
      }
    }
  }

  /// 多选时顶部状态区左边：一排「动词 + 键帽」按钮；对象是勾选项里看得见的（model.targets，搜索 / 筛选换了列表后不算看不见的）。
  /// 「收藏夹…」打开收藏夹列表（ActionMenu，和 ⌘K 的「移到收藏夹」子列表同一份）
  @ViewBuilder private var multiSelectVerbs: some View {
    let items = model.targets
    let ids = Set(items.map(\.id))
    HStack(spacing: 12) {
      // 实在放不下时先截它（勾选标记看得见选了哪些），动词不截
      Text("已选 \(items.count) 条").lineLimit(1).layoutPriority(-1)
      Button(action: { model.pasteSelection() }) {
        hint(ClipboardPanelModel.PasteMode(items).verb, key: "↩", primary: true)
      }
      Button(action: { model.toggleFavorite(ids) }) {
        hint(items.allSatisfy(\.favorite) ? "取消收藏" : "收藏", key: "⌘D")
      }
      Button {
        model.palette = model.palette == .groups ? nil : .groups
      } label: {
        Text("收藏夹…").foregroundStyle(.primary).contentShape(.rect)
      }
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .named(Self.space))
      } action: {
        groupsButtonFrame = $0
      }
      .accessibilityAddTraits(model.palette == .groups ? .isSelected : [])
      Button(action: { model.delete(ids) }) { hint("删除", key: "⌘⌫", danger: true) }
      Button(action: { model.multiSelection = [] }) { hint("取消", key: "Esc") }
    }
  }

  /// 「动词 键帽」；primary：↩ 是品牌粉实心键帽（主按钮）；leadingKey：键帽在前（按住修饰键时的替代动作）；
  /// danger：删除这类，动词用危险色（mac-whisker §3「危险色」）
  private func hint(
    _ title: LocalizedStringResource, key: String, primary: Bool = false, leadingKey: Bool = false,
    danger: Bool = false
  ) -> some View {
    HStack(spacing: 6) {
      if leadingKey { KeyCap(key) }
      // 一行：英文的动词长，挤的时候截断，别从词中间折成两行
      Text(title).lineLimit(1)
        .foregroundStyle(danger ? AnyShapeStyle(Style.danger) : AnyShapeStyle(.primary))
      if !leadingKey {
        KeyCap(key, primary: primary)
      }
    }
    .contentShape(.rect)
  }

  private func countText(_ count: Int) -> LocalizedStringResource {
    let total = model.store.items.count
    return count == total ? "\(total) 条" : "\(count) / \(total) 条"
  }
}

/// 搜索框里的粉色筛选标签：高 22、12 medium、品牌粉 0.12 底 + brandInk 字（⌫ 待删时 0.30 底），尾部 8 pt ×（字到 × 6）。
/// 点标签打开筛选面板，点 × 移除
private struct TokenChip: View {
  let token: ClipboardPanelModel.Token
  let armed: Bool
  let open: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(action: open) {
        Text(token.title)
          .lineLimit(1)
          .padding(.leading, 10)
          .padding(.trailing, 6)
          .frame(height: 22)
          .contentShape(.rect)
      }
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .frame(width: 8, height: 22)
          .padding(.trailing, 8)
          .contentShape(.rect)
      }
    }
    .buttonStyle(.plain)
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Style.brandInk)
    .background(Style.brand.opacity(armed ? 0.30 : 0.12), in: .capsule)
    .fixedSize()
    .animation(Style.Motion.snap.animation(), value: armed)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("筛选：\(token.title)")
    .accessibilityHint("按删除键移除")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { open() }
    .accessibilityAction(named: "移除", remove)
  }
}
