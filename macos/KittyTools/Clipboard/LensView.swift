// 剪贴板卡片内容：沿用代码着色、颜色值复制、链接预览和文件缩略图，完整检查器也共用这里的格式化函数。
// 预览尺寸由卡片决定；只有当前选中的链接才加载网页信息，缓存与隐私规则沿用 LinkPreview。

import AppKit
import SwiftUI

enum Lens {
  /// 行头（= ClipRowView.height）、元信息行、底
  static let head: CGFloat = 40
  static let meta: CGFloat = 22
  static let bottom: CGFloat = 8
  /// 最高的透镜（代码 / JSON）比普通行多出来的：窗口一直按它预留，↑↓ 永远不改窗口高度
  static let reserve: CGFloat = 128 + meta + bottom

  /// 行头：普通行 40；图片行展开时是上面 8 + 长到 108 高的图
  static func head(for item: ClipItem, imageRows: Bool) -> CGFloat {
    imageRows && item.kind == .image
      ? ClipRowView.picturePadding + ClipRowView.expandedPictureHeight : head
  }

  /// 正文区高度（查表，mac-whisker §6）。imageRows：设置「列表里直接显示图片」开着（图片没有正文区，图在行头里长大）
  static func bodyHeight(for item: ClipItem, form: ContentForm?, imageRows: Bool = false) -> CGFloat
  {
    switch item.kind {
    case .image: imageRows ? 0 : 108
    case .file: 76
    case .text:
      switch form {
      case .color: 72
      case .code, .json: 128
      case .link: 90
      // 行标题已经原样显示全了：不再画第二遍（只按条目自己的数据判断，仍是常数）
      case nil: ClipRowView.showsWholeText(item) ? 0 : isShort(item.text ?? "") ? 36 : 90
      }
    }
  }

  /// 透镜总高 = 行头 + 正文 + 元信息 + 底（最高 198，标题已显示全的文本最矮 70；图片行展开 146，比没展开的 64 多 82）
  static func height(for item: ClipItem, form: ContentForm?, imageRows: Bool = false) -> CGFloat {
    head(for: item, imageRows: imageRows) + bodyHeight(for: item, form: form, imageRows: imageRows)
      + meta + bottom
  }

  /// 没有换行且不超过 60 字：两行高就够，免得一行字下面空一大块
  static func isShort(_ text: String) -> Bool {
    let trimmed = text.prefix(400).trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count <= 60 && !trimmed.contains(where: \.isNewline)
  }

  /// 透镜正文里贴着正文区左边的字（文本正文、文件名）用的具体颜色（= 行标题的颜色），不用默认的层级色：
  /// 正文区是裁切的，层级色的字贴着裁切区的边时，SwiftUI 把字画成白的、颜色放在裁切那一层的滤镜（multiplyColor）上；
  /// 截图自检的出图（cacheDisplay）不画图层滤镜，这些字就是白的。真机不受影响（2026-10-12 照透镜的结构写了个最小复现，
  /// 同一棵图层树 cacheDisplay 出来是白字、CARenderer 按真实合成画出来颜色是对的），给具体颜色只是让截图和真机一个样
  static let ink = Color(nsColor: .labelColor)

  /// 搜索词命中的底色（systemYellow 0.35，和 ⌘Y 大卡的 NSTextView 高亮同色）
  static let hitColor = Color(nsColor: .systemYellow).opacity(0.35)

  /// VoiceOver 的透镜值：「类型 · 前 200 字」；没有正文区的（行标题已经把全文念过了）只说类型
  static func accessibilityValue(for item: ClipItem, form: ContentForm?) -> String {
    guard bodyHeight(for: item, form: form) > 0 else { return typeTitle(item, form: form) }
    let body =
      switch item.kind {
      case .text: String((item.text ?? "").prefix(200))
      case .image: item.ocrText.map { String($0.prefix(200)) } ?? ""
      case .file: item.title
      }
    return "\(typeTitle(item, form: form)) · \(body)"
  }

  static func typeTitle(_ item: ClipItem, form: ContentForm?) -> String {
    switch item.kind {
    case .text:
      form?.title ?? (item.richType != nil ? String(localized: "富文本") : String(localized: "文本"))
    case .image: String(localized: "图片")
    case .file: String(localized: "文件")
    }
  }

  /// NSAttributedString（语法着色）→ SwiftUI Text 认的 AttributedString：只搬字色和字体
  static func swiftUI(_ source: NSAttributedString) -> AttributedString {
    var result = AttributedString()
    source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) {
      attributes, range, _ in
      var run = AttributedString((source.string as NSString).substring(with: range))
      if let color = attributes[.foregroundColor] as? NSColor {
        run.swiftUI.foregroundColor = Color(nsColor: color)
      }
      if let font = attributes[.font] as? NSFont { run.swiftUI.font = Font(font as CTFont) }
      result += run
    }
    return result
  }
}

extension AttributedString {
  /// 给搜索词的每个命中加黄底（比较口径同搜索：不分大小写、全半角、变音符号）
  mutating func highlight(_ query: String) {
    for token in Search.tokens(query) {
      var start = startIndex
      while start < endIndex, let range = self[start...].range(of: token, options: Search.options) {
        self[range].swiftUI.backgroundColor = Lens.hitColor
        start = range.upperBound
      }
    }
  }
}

/// 透镜的正文区 + 元信息行（行头由列表画）
struct LensView: View {
  let item: ClipItem
  let form: ContentForm?
  let model: ClipboardPanelModel
  /// 设置「列表里直接显示图片」：图片的图在行头里，这里只画元信息行
  var imageRows = false
  var selected = true

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geometry in
        content
          .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
          .clipped()
          .fading(when: fades)
      }
      meta.frame(height: Lens.meta)
    }
  }

  @ViewBuilder private var content: some View {
    switch item.kind {
    case .text:
      if form == .color, let color = ContentForm.color(in: item.text ?? "") {
        ColorLens(color: color)
      } else if form == .link, let url = ContentForm.firstLink(in: item.text ?? "") {
        if selected {
          LinkCard(url: url, text: item.text ?? "", compact: true)
        } else {
          Text(highlighted(item.text ?? "")).font(.system(size: 13)).foregroundStyle(Lens.ink)
        }
      } else if form == .code || form == .json {
        CodeLens(text: model.displayText(of: item), json: form == .json, query: model.query)
      } else if Lens.isShort(item.text ?? "") {
        Text(highlighted(item.text ?? ""))
          .font(.system(size: 13))
          .lineSpacing(3)
          .lineLimit(2)
          // 给具体的颜色，同下面的长文本：层级色的字贴着裁切区的边时在截图自检里画成白的（clip-lens-wrapped），见 Lens.ink
          .foregroundStyle(Lens.ink)
      } else {
        let text = String((item.text ?? "").prefix(20_000))
        let shown =
          Search.excerpt(of: text, query: model.query, before: 40, after: 600)
          ?? String(text.prefix(640))
        Text(highlighted(shown))
          .font(.system(size: 13))
          .lineSpacing(3)
          .foregroundStyle(Lens.ink)  // 渐隐遮罩里不能用层级色，见 fading
          .fixedSize(horizontal: false, vertical: true)
      }
    case .image:
      ImageLens(item: item, images: model.store.images)
    case .file:
      FileStrip(paths: item.filePaths ?? [])
    }
  }

  /// 会超出正文区的（长文本、代码 / JSON）底部渐隐；短文本、颜色、链接、图片、文件本来就放得下
  private var fades: Bool {
    item.kind == .text && form != .color && form != .link && !Lens.isShort(item.text ?? "")
  }

  private func highlighted(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    attributed.highlight(model.query)
    return attributed
  }

  /// 来源和时间由卡片头尾显示；这里只留内容大小与 JSON 原文 / 美化开关。
  private var meta: some View {
    HStack(spacing: 0) {
      Text(metaText).lineLimit(1)
      Spacer(minLength: 8)
      if form == .json {
        Button(model.prettyJSON ? "原文" : "美化") { model.prettyJSON.toggle() }
          .buttonStyle(.plain)
          .foregroundStyle(Style.brandInk)
          .pointerStyle(.link)
          .help(model.prettyJSON ? "显示原文（这次呼出里一直有效）" : "美化 JSON")
      }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }

  private var metaText: String {
    let detail: String? =
      switch item.kind {
      case .text: Self.characterCount(item.text ?? "")
      case .image:
        item.image.map {
          "\($0.width)×\($0.height) · \($0.byteCount.formatted(.byteCount(style: .file)))"
        }
      case .file:
        String(
          localized: "clipboard.lens.fileCount", defaultValue: "\(item.filePaths?.count ?? 0) 个",
          comment: "透镜元信息里文件条目有几个文件")
      }
    return detail ?? Lens.typeTitle(item, form: form)
  }

  /// 「70 字」（透镜、⌘Y 大卡的元信息同一个）
  static func characterCount(_ text: String) -> String {
    String(localized: "\(text.count) 字")
  }

  /// 今天写 14:02，更早写 9月25日 14:02（跨年带年份）。跟着界面语言（Locale.current）：英文「Sep 25 2:02 PM」，
  /// 12 / 24 小时制按系统设置（中文是两位的 14:02、09:05，和以前定死 zh-Hans 时一样）
  static func exactTime(_ date: Date) -> String {
    let time = date.formatted(.dateTime.hour().minute())
    if Calendar.current.isDateInToday(date) { return time }
    let day =
      Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
      ? date.formatted(.dateTime.month().day())
      : date.formatted(.dateTime.year().month().day())
    return "\(day) \(time)"
  }
}

extension View {
  /// 正文区底部 12 pt 渐隐（裁切后的长正文）。只在要渐隐时挂遮罩：遮罩让正文离屏合成，材质上的层级前景色
  /// （.primary / .tertiary 的混合）在里面画出来发白、发虚（截图自检实测），所以渐隐的正文一律用具体的系统颜色
  @ViewBuilder fileprivate func fading(when fades: Bool) -> some View {
    if fades {
      mask {
        VStack(spacing: 0) {
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 12)
        }
      }
    } else {
      self
    }
  }
}

/// 代码 / JSON：SF Mono 12 行距 2、语法着色、tertiary 行号；有搜索词时从命中那一行的上一行开始
private struct CodeLens: View {
  let text: String
  let json: Bool
  let query: String

  var body: some View {
    let (first, lines) = shownLines()
    let digits = CGFloat(String(first + lines.count).count)
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("\(first + index + 1)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))  // 在渐隐遮罩里，见 fading
            .frame(width: digits * 7 + 2, alignment: .trailing)
          Text(line).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// 第一行的下标 + 要显示的几行（已着色、已高亮）。
  /// ponytail: 只取前 2 万字、显示 10 行、每行前 300 字（透镜 128 pt 放 7 行半，多的本来就裁掉）
  private func shownLines() -> (first: Int, lines: [AttributedString]) {
    let source = String(text.prefix(20_000))
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    let first =
      Search.firstHit(in: source, query: query).map {
        max(0, source[..<$0.lowerBound].count(where: { $0 == "\n" }) - 1)
      } ?? 0
    let shown = lines[first..<min(first + 10, lines.count)].map { String($0.prefix(300)) }
    let colored = SyntaxHighlight.attributed(
      shown.joined(separator: "\n"), language: json ? .json : .code,
      font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    var location = 0
    return (
      first,
      shown.map { line in
        let length = (line as NSString).length
        defer { location += length + 1 }
        var run = Lens.swiftUI(
          colored.attributedSubstring(from: NSRange(location: location, length: length)))
        run.highlight(query)
        return run
      }
    )
  }
}

/// 颜色：左 120×72 色块（棋盘格底、HEX 22 Rounded，黑白字按亮度），右边两列四枚值胶囊，点一下复制、图标换对勾
private struct ColorLens: View {
  let color: ContentForm.RGBA
  @State private var copied: Int?

  var body: some View {
    let values = ColorCard.values(color)
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    VStack(alignment: .leading, spacing: 8) {
      shape.fill(Color(color))
        .background(Checkerboard().clipShape(shape))
        .overlay(shape.strokeBorder(Style.swatchRim, lineWidth: 1))
        .overlay {
          Text(values[0])
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .foregroundStyle(ColorCard.isLight(color) ? .black.opacity(0.8) : .white)
        }
        .frame(minHeight: 12, maxHeight: .infinity)
      HStack(spacing: 6) {
        ForEach(0..<4) { index in chip(values, index) }
      }
      .frame(height: 22)
    }
  }

  private func chip(_ values: [String], _ index: Int) -> some View {
    Button {
      // 面板开着时复制的色值块不记进历史（记新条目会把选中跳走，mac-native §5）；焦点在搜索框，主动播报
      Paster.write(string: values[index])
      Island.announce("已复制 \(values[index])")
      copied = index
      Task {
        try? await Task.sleep(for: Style.copiedHold)
        if copied == index { copied = nil }
      }
    } label: {
      Group {
        if copied == index {
          Image(systemName: "checkmark")
        } else {
          Text(verbatim: ["HEX", "RGB", "HSL", "Swift"][index])
        }
      }
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .frame(maxWidth: .infinity)
      .frame(height: 22)
      .background(Style.controlFill, in: .capsule)
      .contentShape(.capsule)
    }
    .accessibilityLabel("复制 \(values[index])")
    .buttonStyle(PressScale())
    .help("复制 \(values[index])")
  }
}

/// 图片：8 pt 棋盘格上的缩略图（高 108、保持比例、左对齐），尺寸和大小在下面的元信息行。识别文字不在这里显示
/// （用户 2026-09-27 嫌干扰；对标 Maccy / Paste / PastePal 都只拿它做搜索）：靠它搜到时行标题接命中那段，
/// 全文在 ⌘Y 大卡里，⌘K「复制图中文字」
private struct ImageLens: View {
  let item: ClipItem
  let images: ImageStore

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    let ratio = item.image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
    ZStack {
      Checkerboard(cell: 8)
      // 比例超出 60–360 宽时图片在格子里留边，图片自己也裁圆角
      ThumbnailView(
        id: item.id, images: images, maxPixel: ThumbnailView.lensPixel, contentMode: .fit
      ).clipShape(shape)
    }
    .frame(width: min(max(108 * ratio, 60), 360), height: 108)
    .clipShape(shape)
    .overlay(shape.hairlineBorder())
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 文件：一排最多 6 个 48 pt Quick Look 缩略图 + 11 pt 文件名，多的写「+N」。每一格 72 宽，缩略图和文件名都靠左：
/// 第一格贴着透镜的左边线，和上面的标题、下面的元信息行共一条线（在格子里居中的话，缩略图那一格比标题右移 12）
private struct FileStrip: View {
  let paths: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(paths.prefix(3), id: \.self) { path in
        HStack(spacing: 8) {
          FileThumbnail(path: path, side: 32).frame(width: 32, height: 32, alignment: .leading)
          Text(URL(filePath: path).lastPathComponent)
            .font(.system(size: 11))
            .foregroundStyle(Lens.ink)  // 靠左后贴着正文区的边，见 Lens.ink
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(path)
      }
      if paths.count > 3 {
        Text("+\(paths.count - 3)")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(height: 48)
      }
    }
  }
}
