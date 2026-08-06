// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'NexHub';

  @override
  String get navBrowse => '浏览';

  @override
  String get navNovel => '小说';

  @override
  String get navMedia => '媒体';

  @override
  String get navComic => '漫画';

  @override
  String get navSettings => '设置';

  @override
  String get homeTitle => '浏览';

  @override
  String get settingsTitle => '设置';

  @override
  String get sourceManagementTitle => '源管理';

  @override
  String get downloadSettingsTitle => '下载';

  @override
  String get downloadManagementTitle => '下载管理';

  @override
  String get aboutTitle => '关于';

  @override
  String get themeTitle => '外观';

  @override
  String get tabLibrary => '书架';

  @override
  String get tabOnline => '在线';

  @override
  String get tabSubscribe => '订阅';

  @override
  String get tabSources => '源管理';

  @override
  String get browseLocalFiles => '本地文件';

  @override
  String get browseLocalFilesSubtitle => '浏览本机小说、视频和漫画';

  @override
  String get browseNetworkFiles => '网络文件';

  @override
  String get browseNetworkFilesSubtitle => '浏览 HTTP 文件服务器';

  @override
  String get browseWebScrape => '网页爬取';

  @override
  String get browseWebScrapeSubtitle => '从网页提取小说、漫画、视频或文章';

  @override
  String get browseRss => 'RSS 订阅';

  @override
  String get browseRssSubtitle => '管理和浏览 RSS 订阅源';

  @override
  String get browseSniff => '嗅探';

  @override
  String get browseSniffSubtitle => '嗅探网页视频并在应用内播放';

  @override
  String get subTabLocal => '本地';

  @override
  String get subTabHistory => '历史记录';

  @override
  String get subTabFavorite => '收藏';

  @override
  String get filter => '筛选';

  @override
  String get filterTitle => '筛选';

  @override
  String get sortBy => '排序';

  @override
  String get sortRecent => '最近';

  @override
  String get sortTitle => '标题';

  @override
  String get filterByStatus => '状态';

  @override
  String get filterByCategory => '分类';

  @override
  String get filterByProgress => '进度';

  @override
  String get allLabel => '全部';

  @override
  String get progressReading => '在看';

  @override
  String get progressNotStarted => '未看';

  @override
  String get filterReset => '重置';

  @override
  String get filterApply => '应用';

  @override
  String get play => '播放';

  @override
  String get readChapter => '阅读';

  @override
  String episodesWithLine(Object line) {
    return '剧集 · $line';
  }

  @override
  String get recommendations => '猜你喜欢';

  @override
  String episodeN(Object n) {
    return '第 $n 集';
  }

  @override
  String get cancel => '取消';

  @override
  String get confirm => '确认';

  @override
  String get delete => '删除';

  @override
  String get save => '保存';

  @override
  String get import => '导入';

  @override
  String get export => '导出';

  @override
  String get close => '关闭';

  @override
  String get search => '搜索';

  @override
  String get retry => '重试';

  @override
  String get ok => '确定';

  @override
  String get next => '下一集';

  @override
  String get previous => '上一集';

  @override
  String get emptyLibrary => '书架还是空的';

  @override
  String get emptySearch => '没有找到结果';

  @override
  String get emptyDownloads => '还没有下载';

  @override
  String get emptySources => '还没有添加源';

  @override
  String get emptyBrowse => '这里什么都没有';

  @override
  String get emptyLocalNovel => '暂无本地小说';

  @override
  String get emptyLocalMedia => '暂无本地媒体';

  @override
  String get emptyLocalComic => '暂无本地漫画';

  @override
  String get emptyLocalNovelAction => '导入小说';

  @override
  String get emptyLocalMediaAction => '导入媒体';

  @override
  String get emptyLocalComicAction => '导入漫画';

  @override
  String get loading => '加载中…';

  @override
  String get noResults => '暂无结果';

  @override
  String get loadFailed => '加载失败';

  @override
  String chapterLoadPartial(Object count) {
    return '目录加载未完成，当前显示 $count 章（网络可能不稳定）';
  }

  @override
  String get noMoreResults => '没有更多了';

  @override
  String get authorColon => '作者：';

  @override
  String get tagColon => '标签：';

  @override
  String get searchFailed => '搜索失败，请重试';

  @override
  String get searching => '搜索中…';

  @override
  String updatedAt(Object time) {
    return '更新于 $time';
  }

  @override
  String get statusOngoing => '连载中';

  @override
  String get statusCompleted => '已完成';

  @override
  String get deprecated => '已弃用';

  @override
  String get mirrorSettings => '镜像与隐藏设置';

  @override
  String get stealthMode => '隐身模式';

  @override
  String get gridView => '网格视图';

  @override
  String get listView => '列表视图';

  @override
  String get toggleLayout => '切换视图';

  @override
  String get all => '全部';

  @override
  String get emptyCategory => '该分类暂无内容';

  @override
  String get emptyContent => '暂无内容';

  @override
  String get contentExpired => '内容已过期，请重新搜索';

  @override
  String get sourceNotFound => '内容源不可用，请更换源或重新搜索';

  @override
  String get onlineBrowse => '在线浏览';

  @override
  String get refreshList => '刷新列表';

  @override
  String get goToVerification => '去验证';

  @override
  String get openSourceWebsite => '打开源站';

  @override
  String get errorGeneric => '出了点问题';

  @override
  String get errorNetwork => '网络错误，请重试';

  @override
  String get errorParse => '解析内容失败';

  @override
  String get errorVerification => '需要验证，请完成验证';

  @override
  String get verificationFailed => '验证失败，请稍后重试';

  @override
  String get errorVideoExpired => '视频链接已失效，请重试';

  @override
  String get danmaku => '弹幕';

  @override
  String get danmakuSend => '发送弹幕';

  @override
  String get danmakuSendHint => '输入弹幕内容';

  @override
  String get danmakuStyle => '弹幕样式';

  @override
  String get danmakuStyleScroll => '滚动';

  @override
  String get danmakuStyleTop => '顶部';

  @override
  String get danmakuStyleBottom => '底部';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get useMonet => '使用动态取色（莫奈）';

  @override
  String get customColor => '自定义主题色';

  @override
  String get presetColor => '预设颜色';

  @override
  String get deleteConfirmTitle => '删除确认';

  @override
  String deleteConfirmContent(String name) {
    return '确定删除「$name」吗？此操作不可撤销。';
  }

  @override
  String get deleteRecordOnly => '仅删除记录';

  @override
  String get deleteRecordAndFile => '删除记录和文件';

  @override
  String get addSource => '添加源';

  @override
  String get importSource => '导入源';

  @override
  String get exportSource => '导出源';

  @override
  String get aboutDescription => 'NexHub —— 四合一媒体聚合客户端（动漫 / 漫画 / 小说 / 影视）。';

  @override
  String get videoSourceLine => '线路';

  @override
  String get defaultLine => '默认线路';

  @override
  String get errorWebView => '需要网页验证';

  @override
  String get verifying => '验证中…';

  @override
  String get mirrorTest => '测速';

  @override
  String get sourceHealthy => '正常';

  @override
  String get resolveTimeout => '解析超时';

  @override
  String resolveFailed(Object message) {
    return '解析失败：$message';
  }

  @override
  String get categories => '分类';

  @override
  String chapterN(Object n) {
    return '第 $n 话';
  }

  @override
  String pageIndicator(Object cur, Object total) {
    return '第 $cur / $total 页';
  }

  @override
  String readerDoublePageIndicator(Object first, Object last, Object total) {
    return '$first-$last / $total';
  }

  @override
  String get prevChapter => '上一章';

  @override
  String get nextChapter => '下一章';

  @override
  String get readerLastChapterReached => '已经是最后一章了';

  @override
  String get readerFirstChapterReached => '已经是第一章了';

  @override
  String get readerSettings => '阅读设置';

  @override
  String get readerMode => '阅读模式';

  @override
  String get readerBackground => '背景';

  @override
  String get readerOrientation => '屏幕方向';

  @override
  String get readerTapZone => '点击区域';

  @override
  String get readerZoom => '双击缩放';

  @override
  String get noImages => '本章暂无可读图片';

  @override
  String get preloading => '预加载下一章…';

  @override
  String get readerModeSingleLTR => '单页（左→右）';

  @override
  String get readerModeSingleRTL => '单页（右→左）';

  @override
  String get readerModeSingleVertical => '单页（竖向）';

  @override
  String get readerModeWebtoon => '条漫';

  @override
  String get readerModeWebtoonWithGap => '条漫（带间距）';

  @override
  String get readerOrientationDefault => '默认';

  @override
  String get readerOrientationSystem => '跟随系统';

  @override
  String get readerOrientationPortrait => '竖屏';

  @override
  String get readerOrientationLandscape => '横屏';

  @override
  String get readerOrientationLockPortrait => '锁定竖屏';

  @override
  String get readerOrientationLockLandscape => '锁定横屏';

  @override
  String get readerOrientationReversePortrait => '反向竖屏';

  @override
  String get readerBgBlack => '黑色';

  @override
  String get readerBgGray => '灰色';

  @override
  String get readerBgDarkGray => '深灰';

  @override
  String get readerBgEyeCare => '护眼绿';

  @override
  String get readerBgParchment => '羊皮纸';

  @override
  String get readerBgWarmLinen => '暖黄';

  @override
  String get readerBgLightBrown => '浅褐';

  @override
  String get readerBgBeanGreen => '豆沙绿';

  @override
  String get readerBgMint => '淡青';

  @override
  String get readerBgApricot => '暖杏';

  @override
  String get readerBgGrayBlue => '浅灰蓝';

  @override
  String get readerBgWhite => '白色';

  @override
  String get readerBgAuto => '自动';

  @override
  String get readerTapLeftRight => '左右';

  @override
  String get readerTapLShape => 'L 形';

  @override
  String get readerTapKindle => 'Kindle';

  @override
  String get readerTapBothSides => '两侧';

  @override
  String get readerTapOff => '关闭';

  @override
  String get readerTapInvert => '点击翻转';

  @override
  String get readerTapInvertNone => '不反转';

  @override
  String get readerTapInvertLeftRight => '左右反转';

  @override
  String get readerTapInvertUpDown => '上下反转';

  @override
  String get readerTapInvertAll => '全反转';

  @override
  String get readerSideMargin => '左右留白';

  @override
  String get readerFlashEnabled => '翻页闪光';

  @override
  String get readerFlashTime => '闪光时长';

  @override
  String get readerFlashInterval => '闪光延迟';

  @override
  String get readerFlashColor => '闪光颜色';

  @override
  String get readerFlashBlack => '黑';

  @override
  String get readerFlashWhite => '白';

  @override
  String get readerFlashBlackWhite => '黑→白';

  @override
  String get readerTapPreviewHint => '点击区域预览（实时）';

  @override
  String get tapPreviewPrev => '上一页';

  @override
  String get tapPreviewNext => '下一页';

  @override
  String get tapPreviewToggle => '切换';

  @override
  String get filterInverted => '反色';

  @override
  String get favorite => '收藏';

  @override
  String get moreActions => '更多操作';

  @override
  String get demoNormal => '默认视图';

  @override
  String get demoEmpty => '显示空状态';

  @override
  String get demoError => '显示错误状态';

  @override
  String get noContent => '本章暂无内容';

  @override
  String get novelFontSize => '字号';

  @override
  String get novelLineHeight => '行距';

  @override
  String get novelParagraphSpacing => '段距';

  @override
  String get novelMargin => '边距';

  @override
  String get novelPageAnimation => '翻页动画';

  @override
  String get novelTextShadow => '文字阴影';

  @override
  String get novelAnimNone => '无动画';

  @override
  String get novelAnimSlide => '滑动';

  @override
  String get novelAnimScroll => '滚动';

  @override
  String get novelAnimFade => '淡入';

  @override
  String get novelAnimCover => '覆盖';

  @override
  String get novelAnimSimulation => '仿真';

  @override
  String get novelHfNone => '无';

  @override
  String get novelHfTime => '时间';

  @override
  String get novelHfBattery => '电量';

  @override
  String get novelHfChapterTitle => '章节标题';

  @override
  String get novelHfBookName => '书名';

  @override
  String get novelHfPageNumber => '页码';

  @override
  String get novelHfProgressPercent => '进度百分比';

  @override
  String novelChapterN(Object n) {
    return '第 $n 章';
  }

  @override
  String get download => '下载';

  @override
  String get downloads => '下载';

  @override
  String get downloadListTitle => '下载列表';

  @override
  String get downloadedContent => '已下载';

  @override
  String get downloadSettings => '下载设置';

  @override
  String get emptyDownloadList => '暂无下载任务';

  @override
  String get emptyDownloaded => '暂无已下载内容';

  @override
  String get clearAll => '清除全部';

  @override
  String get clearAllConfirm => '确定清除全部下载记录吗？已下载的文件不会被删除。';

  @override
  String get clearHistory => '清除历史';

  @override
  String get clearHistoryConfirm => '确定清除本模块的全部浏览历史吗？此操作不可恢复。';

  @override
  String get historyCleared => '历史已清除';

  @override
  String get batchPause => '批量暂停';

  @override
  String get batchResume => '批量继续';

  @override
  String get deleteSelected => '批量删除';

  @override
  String deleteSelectedConfirm(Object count) {
    return '确定删除选中的 $count 项下载记录吗？';
  }

  @override
  String get pause => '暂停';

  @override
  String get selectAll => '全选';

  @override
  String get select => '选择';

  @override
  String get deleteConfirm => '确定删除选中的下载吗？';

  @override
  String get statusPending => '等待中';

  @override
  String get statusDownloading => '下载中';

  @override
  String get statusPaused => '已暂停';

  @override
  String get statusFailed => '失败';

  @override
  String get statusWaitingForWifi => '等待 WiFi';

  @override
  String get statusCancelled => '已取消';

  @override
  String get downloadWifiOnly => '仅 WiFi 下载';

  @override
  String get downloadWifiOnlyHint => '仅在连接到 WiFi 时启动下载';

  @override
  String get comicDownloadFormat => '漫画下载格式';

  @override
  String get novelDownloadFormat => '小说下载格式';

  @override
  String get formatCbz => 'CBZ 压缩包';

  @override
  String get formatCbzSubtitle => '所有图片打包为单个 .cbz 文件';

  @override
  String get formatFolder => '散图文件夹';

  @override
  String get formatFolderSubtitle => '每章一个文件夹，散图存放';

  @override
  String get formatEpub => 'EPUB 电子书';

  @override
  String get formatEpubSubtitle => '标准电子书格式，支持目录';

  @override
  String get formatTxt => 'TXT 纯文本';

  @override
  String get formatTxtSubtitle => '纯文本格式，兼容性最广';

  @override
  String get emptyHistory => '暂无浏览记录';

  @override
  String get emptyFavorites => '暂无收藏';

  @override
  String get emptyRssFeeds => '暂无订阅源';

  @override
  String get emptyRssItems => '暂无文章';

  @override
  String get addRssFeed => '添加订阅源';

  @override
  String get rssFeedTitle => '标题';

  @override
  String get rssFeedTitleHint => '自定义标题（可选）';

  @override
  String get opening => '正在打开';

  @override
  String get verificationRequired => '需要验证';

  @override
  String get verificationHint => '此内容需要完成网页验证后才能访问。请点击下方按钮在浏览器中完成验证，然后返回重试。';

  @override
  String get openInBrowser => '外部打开';

  @override
  String get verificationDone => '已完成验证，重试';

  @override
  String get webViewNotAvailable => '当前平台不支持内嵌浏览器，请使用外部浏览器完成验证。';

  @override
  String get extractFromPage => '用此页抽取';

  @override
  String get extractHint => '在页面中完成验证后，点击「用此页抽取」自动提取内容地址；失败时回退到浏览器手动验证。';

  @override
  String get extracting => '抽取中…';

  @override
  String get extractSuccess => '抽取成功';

  @override
  String get extractNoResult => '未抽取到内容，请重试或手动验证';

  @override
  String get extractFailed => '抽取失败';

  @override
  String get captureFromPage => '抓取本页渲染内容';

  @override
  String get captureHint => '页面渲染完成后，点击「抓取本页渲染内容」即可用既有选择器解析列表/详情，无需手动编写脚本。';

  @override
  String get capturing => '抓取中…';

  @override
  String get snifferTitle => '视频嗅探';

  @override
  String get snifferAddressHint => '打开视频页面以嗅探';

  @override
  String get snifferHint => '打开视频页面后，动态加载的 m3u8/mp4 串流会自动在下方列出。';

  @override
  String get snifferNoResult => '尚未嗅探到视频串流';

  @override
  String get snifferCopy => '复制';

  @override
  String get snifferPlay => '播放';

  @override
  String get snifferInPagePlaying => '正在页内播放';

  @override
  String get snifferInPageHint => '该串流为 blob/MSE 格式，无法在外部播放器打开，已在当前页面内播放。';

  @override
  String get snifferCopyPageLink => '复制页面链接';

  @override
  String get snifferClear => '清空列表';

  @override
  String get snifferGo => '前往';

  @override
  String get snifferDeep => '深度嗅探';

  @override
  String get snifferSave => '保存';

  @override
  String get snifferFilterAll => '全部';

  @override
  String get snifferFilterVideo => '视频';

  @override
  String get snifferFilterAudio => '音频';

  @override
  String get snifferFilterOther => '其他';

  @override
  String get snifferSizeUnknown => '大小未知';

  @override
  String get snifferResolveTitle => '嗅探解析';

  @override
  String get snifferResolving => '正在嗅探视频地址…';

  @override
  String get snifferResolveTimeout => '未捕获到直链，可继续等待或取消';

  @override
  String get failed => '失败';

  @override
  String get share => '分享';

  @override
  String get shareCopied => '已复制到剪贴板';

  @override
  String get browserTitle => '浏览器';

  @override
  String get browserAddressHint => '输入网址或搜索';

  @override
  String get browserBack => '后退';

  @override
  String get browserForward => '前进';

  @override
  String get browserRefresh => '刷新';

  @override
  String get browserCopyLink => '复制链接';

  @override
  String get browserShare => '分享';

  @override
  String get browserLinkCopied => '链接已复制';

  @override
  String get browserUseAsVerification => '用此页完成验证';

  @override
  String get browserOpenSniffer => '视频嗅探模式';

  @override
  String get browserUseAsVerificationDone => '已用此页 Cookie 完成验证';

  @override
  String get browserNotAvailable => '当前平台不支持内置浏览器，请使用外部浏览器。';

  @override
  String get openInternalBrowser => '打开内置浏览器';

  @override
  String get downloadStarted => '下载已开始';

  @override
  String get downloadEpisodes => '选集下载';

  @override
  String get episodeRange => '选集范围';

  @override
  String get addToDownload => '加入下载';

  @override
  String get deselectAll => '全不选';

  @override
  String selectedCount(Object selected, Object total) {
    return '已选 $selected/$total';
  }

  @override
  String get rangeStart => '起始集';

  @override
  String get rangeEnd => '结束集';

  @override
  String get applyRange => '应用';

  @override
  String get alreadyDownloaded => '已下载';

  @override
  String get favoriteAdded => '已收藏';

  @override
  String get favoriteRemoved => '已取消收藏';

  @override
  String get aboutApp => '关于应用';

  @override
  String get appVersion => '版本';

  @override
  String get clearCache => '清除缓存';

  @override
  String get cacheCleared => '缓存已清除';

  @override
  String get privacySettings => '隐私设置';

  @override
  String get stealthSettings => '隐身设置';

  @override
  String get browseLocalTitle => '本地文件';

  @override
  String get browseLocalEmpty => '未找到可读的本地文件';

  @override
  String get browseLocalScan => '扫描文件';

  @override
  String get browseLocalFileTypeAll => '全部';

  @override
  String get browseLocalFileTypeNovel => '小说';

  @override
  String get browseLocalFileTypeComic => '漫画';

  @override
  String get browseLocalFileTypeVideo => '视频';

  @override
  String get browseLocalSelectFolder => '选择文件夹';

  @override
  String get browseNetworkTitle => '网络文件';

  @override
  String get browseNetworkUrlHint => '输入 HTTP 文件服务器地址';

  @override
  String get browseNetworkConnect => '连接';

  @override
  String get browseNetworkEmpty => '未找到文件';

  @override
  String get browseNetworkHistory => '历史地址';

  @override
  String get browseNetworkParentDir => '上级目录';

  @override
  String get browseNetworkFileSize => '大小';

  @override
  String get scrapeModeGeneral => '通用';

  @override
  String get scrapeModeNovel => '小说';

  @override
  String get scrapeModeComic => '漫画';

  @override
  String get scrapeModeVideo => '视频';

  @override
  String get scrapeModeArticle => '文章';

  @override
  String get scrapeUrlHint => '输入要爬取的网页 URL';

  @override
  String get scrapeStart => '开始爬取';

  @override
  String get scrapeResultTitle => '页面标题';

  @override
  String get scrapeResultLinks => '所有链接';

  @override
  String get scrapeResultText => '正文内容';

  @override
  String get scrapeResultImages => '图片列表';

  @override
  String get scrapeResultVideos => '视频列表';

  @override
  String get scrapeOpenInReader => '在阅读器中打开';

  @override
  String get scrapeOpenInPlayer => '在播放器中打开';

  @override
  String get scrapeNoResults => '未提取到内容';

  @override
  String get scrapeSelectorHint => 'CSS 选择器（可选）';

  @override
  String get scrapeAdvanced => '高级选项';

  @override
  String get rssFeedUrl => '订阅地址';

  @override
  String get rssFeedUrlHint => 'https://example.com/feed.xml';

  @override
  String get rssFeedDescription => '描述';

  @override
  String get rssFeedModule => '绑定模块';

  @override
  String get rssFeedModuleNone => '全局（浏览页）';

  @override
  String get rssFeedTestConnection => '测试连接';

  @override
  String get rssFeedTesting => '测试中…';

  @override
  String get rssFeedTestSuccess => '连接成功';

  @override
  String get rssFeedTestFailed => '连接失败';

  @override
  String get rssFeedPreview => '预览';

  @override
  String get rssFeedSaved => '订阅源已保存';

  @override
  String get articleDetailAuthor => '作者';

  @override
  String get articleDetailPublishedAt => '发布时间';

  @override
  String get articleDetailReadFull => '阅读全文';

  @override
  String get articleDetailSource => '来源';

  @override
  String get articleDetailEmpty => '文章无内容';

  @override
  String get articleReadingSettings => '阅读设置';

  @override
  String get articleFontSize => '字号';

  @override
  String get articleLineHeight => '行距';

  @override
  String get articleNightMode => '夜间模式';

  @override
  String get mirrorListTitle => '镜像列表';

  @override
  String get mirrorTesting => '测速中…';

  @override
  String mirrorTestResultMs(Object ms) {
    return '$ms ms';
  }

  @override
  String get mirrorTestFailed => '失败';

  @override
  String get mirrorCurrent => '当前';

  @override
  String get mirrorSwitched => '镜像已切换';

  @override
  String get mirrorStealthLocked => '隐身模式已强制开启';

  @override
  String get mirrorNoMirrors => '此源无镜像配置';

  @override
  String get collectApiImportTitle => '采集 API 导入';

  @override
  String get collectApiUrlHint => 'https://example.com/api.php/provide/vod/';

  @override
  String get collectApiDetect => '识别';

  @override
  String get collectApiDetecting => '识别中…';

  @override
  String get collectApiDetectSuccess => '识别成功';

  @override
  String get collectApiDetectFailed => '识别失败';

  @override
  String get collectApiSiteName => '站点名称';

  @override
  String get collectApiCategories => '分类';

  @override
  String get collectApiPreview => '内容预览';

  @override
  String get collectApiSourceName => '源名称';

  @override
  String get collectApiSourceId => '源 ID';

  @override
  String get collectApiSave => '保存源';

  @override
  String get collectApiSaved => '源已保存';

  @override
  String get collectApiInvalidUrl => '无效的 URL';

  @override
  String get sourceImportFromUrl => '从 URL 导入';

  @override
  String get sourceImportFromFile => '从文件导入';

  @override
  String get sourceImportFromJson => '手动输入 JSON';

  @override
  String get sourceImportUrlHint => '源 JSON 的 URL';

  @override
  String get sourceImportFilePicker => '选择 JSON 文件';

  @override
  String get sourceImportJsonHint => '粘贴源 JSON 配置';

  @override
  String get sourceImportValidate => '校验';

  @override
  String get sourceImportValid => '校验通过';

  @override
  String get sourceImportInvalid => '校验失败';

  @override
  String get sourceImportErrors => '错误信息';

  @override
  String get sourceImportCollectApiDetected => '检测到 MacCMS 采集 API';

  @override
  String get sourceImportCollectApiRedirect => '使用采集 API 导入';

  @override
  String get sourceImportSaved => '源已导入';

  @override
  String get contentImportTitle => '导入内容';

  @override
  String get contentImportSelectFile => '选择文件';

  @override
  String get contentImportSupportedFormats => '支持的格式';

  @override
  String get contentImportHistory => '导入历史';

  @override
  String get contentImportEmpty => '暂无导入记录';

  @override
  String get contentImportOpened => '已打开';

  @override
  String comicDirImported(Object name) {
    return '已导入漫画：$name';
  }

  @override
  String get contentImportNovelFormats => '.txt, .epub';

  @override
  String get contentImportComicFormats => '.cbz, 图片文件夹';

  @override
  String get contentImportMediaFormats => '.mp4, .mkv, .avi';

  @override
  String get downloadedGroupChapters => '章节列表';

  @override
  String get downloadedGroupFormat => '格式';

  @override
  String get downloadedGroupOpen => '打开';

  @override
  String get downloadedGroupFileMissing => '文件不存在';

  @override
  String get downloadedGroupDeleteConfirm => '确定删除此下载项吗？';

  @override
  String get browsePageTitle => '浏览';

  @override
  String get rssSubscribeTitle => 'RSS 订阅';

  @override
  String get emptyRssSubscribe => '还没有 RSS 订阅';

  @override
  String get addSubscription => '添加订阅';

  @override
  String get subscribeAddressLabel => '订阅地址';

  @override
  String get rsshubRoutesTitle => 'RSSHub 路由';

  @override
  String get rsshubRouteRecommend => 'RSSHub 路由推荐';

  @override
  String get rsshubRouteHint => '点击路由自动填入 RSSHub 实例地址';

  @override
  String get novelLibraryName => '小说库';

  @override
  String get mediaLibraryName => '媒体库';

  @override
  String get comicLibraryName => '漫画库';

  @override
  String get emptySubscribe => '暂无订阅源';

  @override
  String get sourceListTab => '源列表';

  @override
  String get networkImportTab => '网络导入';

  @override
  String get localImportTab => '本地导入';

  @override
  String get sourceListEmpty => '暂无源';

  @override
  String get networkImportHint => '粘贴源地址（.json/.txt）';

  @override
  String get networkImportPasteHint => '粘贴地址并点击获取';

  @override
  String get localImportTitle => '从本地文件导入';

  @override
  String get localImportFormats => '支持 .json、.txt、.xml';

  @override
  String get selectFile => '选择文件';

  @override
  String get selectFolder => '选择文件夹';

  @override
  String get noLocalSource => '未找到源文件';

  @override
  String get localImportHint => '选择单个文件或文件夹，扫描其中的源文件（.json/.txt/.xml）';

  @override
  String importPreviewTitle(Object count) {
    return '找到 $count 个文件';
  }

  @override
  String get confirmImport => '确认导入';

  @override
  String importSelectedCount(Object count) {
    return '已选 $count 项';
  }

  @override
  String importTypeOnly(Object type) {
    return '仅导入【$type】类型源';
  }

  @override
  String importTypeFiltered(int count) {
    return '已跳过 $count 个其他类型源';
  }

  @override
  String importNoMatchingType(Object type, int count) {
    return '所选内容中无【$type】类型源（已跳过 $count 个其他类型）';
  }

  @override
  String sourceImportResult(int success, int total) {
    return '成功导入 $success/$total 个源';
  }

  @override
  String batchImportHint(int count) {
    return '已识别 $count 个源，勾选后批量导入（含小说 / 媒体 / 漫画）';
  }

  @override
  String get sourceUnrecognized => '无法识别为有效源（小说 / 媒体 / 漫画）';

  @override
  String importDistributedHint(int count) {
    return '将按类型自动归入对应模块（含 $count 个其他模块源）';
  }

  @override
  String get settingsGroupDownload => '下载管理';

  @override
  String get settingsGroupTools => '工具';

  @override
  String get settingsGroupPlugins => '插件';

  @override
  String get settingsGroupData => '数据';

  @override
  String get settingsGroupPlayback => '播放与阅读';

  @override
  String get settingsGroupContentSources => '内容源';

  @override
  String get settingsGroupNetwork => '网络';

  @override
  String get settingsGroupSubscriptions => '订阅与通知';

  @override
  String get settingsGroupDownloadsData => '下载与数据';

  @override
  String get webScrapeSetting => '网页爬取';

  @override
  String get webScrapeSettingSameAsBrowse => '与浏览页网页爬取一样';

  @override
  String get subscriptionManagement => '订阅管理';

  @override
  String get subscriptionManagementDesc => '分类型统一管理，可以设置 RSS 订阅';

  @override
  String get rsshubInstance => 'RSSHub Instance';

  @override
  String get rsshubInstanceDesc => '自部署 RSSHub 地址';

  @override
  String get rsshubSettingsTitle => 'RSSHub 设置';

  @override
  String get rssNotifications => 'RSS 更新通知';

  @override
  String get rssNotificationsDesc => '检测订阅源新条目';

  @override
  String get rssNotificationsTitle => 'RSS 更新通知';

  @override
  String get rssNotificationEnabled => '启用更新检测';

  @override
  String get rssNotificationEnabledSubtitle => '前台定期轮询已订阅源';

  @override
  String get rssUpdateInterval => '检测间隔';

  @override
  String get interval15m => '15 分钟';

  @override
  String get interval30m => '30 分钟';

  @override
  String get interval1h => '1 小时';

  @override
  String get interval2h => '2 小时';

  @override
  String get interval4h => '4 小时';

  @override
  String get rssCheckNow => '立即检测';

  @override
  String rssTotalNewCount(int count) {
    return '当前未读：$count';
  }

  @override
  String get rssCheckDone => '检测完成';

  @override
  String get rssNotificationHint => '仅应用在前台时轮询；检测到新条目会在订阅源卡片显示未读数。';

  @override
  String get currentInstance => '当前实例';

  @override
  String get presetInstances => '预置实例';

  @override
  String get presetInstanceOfficial => '官方';

  @override
  String get customInstance => '自定义实例';

  @override
  String get restoreDefault => '恢复默认';

  @override
  String get rsshubTestAll => '一键测速';

  @override
  String get rsshubTestingAll => '正在测速全部实例…';

  @override
  String rsshubTestAllDone(Object count) {
    return '已测速 $count 个实例';
  }

  @override
  String get saveCustomInstance => '保存自定义';

  @override
  String get instanceTestFail => '测试失败';

  @override
  String get instanceTestSuccess => '连接成功';

  @override
  String get rsshubTroubleshoot => '故障排除';

  @override
  String get rsshubTroubleshootHint =>
      '如果遇到问题：\n• 确保地址可访问且无防火墙限制\n• 尝试更换预置实例\n• 自建 RSSHub 用户请检查服务是否正常运行';

  @override
  String get danmakuSettings => '弹弹play 弹幕';

  @override
  String get danmakuSettingsDesc => '弹幕配置';

  @override
  String get danmakuConfigTitle => '弹弹play 弹幕配置';

  @override
  String get unconfigured => '未配置';

  @override
  String get configured => '已配置';

  @override
  String get appIdLabel => 'AppId';

  @override
  String get appIdHint => '请输入 AppId';

  @override
  String get appSecretLabel => 'AppSecret';

  @override
  String get appSecretHint => '请输入 AppSecret';

  @override
  String get saveDanmaku => '保存';

  @override
  String get danmakuDesc =>
      '在 https://daplay.danmaku.net 获取您的配置 AppId 和 AppSecret。配置后可在播放器中看到弹弹play弹幕。';

  @override
  String get pluginManagement => '管理插件';

  @override
  String get dataImportExport => '导入/导出';

  @override
  String get dataImportExportTitle => '导入/导出';

  @override
  String get importData => '导入数据';

  @override
  String get importDataDesc => '导入订阅、插件和进度';

  @override
  String get exportData => '导出数据';

  @override
  String get exportDataDesc => '导出所有数据到文件';

  @override
  String get exportSubscription => '导出订阅';

  @override
  String get exportSubscriptionDesc => '仅导出 RSS 订阅';

  @override
  String get exportPlugins => '导出插件';

  @override
  String get exportPluginsDesc => '导出插件配置';

  @override
  String get selectExportFolder => '选择导出文件夹';

  @override
  String get exportFolderCustom => '可以自定义导出文件夹';

  @override
  String get downloadListTab => '下载列表';

  @override
  String get downloadedListTab => '已下载内容';

  @override
  String get maxConcurrentDownloads => '最大同时下载数';

  @override
  String get maxConcurrentDownloadsDesc => '同时进行的下载数量';

  @override
  String get downloadPath => '下载路径';

  @override
  String get downloadPathSet => '下载路径已更新';

  @override
  String get contentImportActions => '操作';

  @override
  String get downloadPathDesc => 'D:/Downloads';

  @override
  String get downloaderType => '下载器';

  @override
  String get downloaderInternal => '内置下载器';

  @override
  String get downloaderExternal => '外置下载器';

  @override
  String get threadCount => '线程数';

  @override
  String get threadCountDesc => '下载线程数量';

  @override
  String get comicFormatSetting => '漫画格式';

  @override
  String get novelFormatSetting => '小说格式';

  @override
  String get downloadTabsAll => '全部';

  @override
  String get downloadTabsNovel => '小说';

  @override
  String get downloadTabsMedia => '媒体';

  @override
  String get downloadTabsComic => '漫画';

  @override
  String get downloadedTabsAll => '全部';

  @override
  String get downloadedTabsNovel => '小说';

  @override
  String get downloadedTabsMedia => '媒体';

  @override
  String get downloadedTabsComic => '漫画';

  @override
  String get downloadedTabsArchived => '已删除下载';

  @override
  String get noDownloads => '暂无下载';

  @override
  String get downloadPause => '暂停';

  @override
  String get downloadResume => '继续';

  @override
  String get sourceCategoryNovel => '小说';

  @override
  String get sourceCategoryMedia => '媒体';

  @override
  String get sourceCategoryComic => '漫画';

  @override
  String sourceCategoryEmpty(Object category) {
    return '暂无$category源';
  }

  @override
  String rsshubLatencyMs(Object ms) {
    return '${ms}ms';
  }

  @override
  String get rsshubLatencyFailed => '失败';

  @override
  String get downloaderSelectTitle => '下载器选择';

  @override
  String get comicFormatSelectTitle => '漫画格式';

  @override
  String get comicFormatJpg => '单页 JPG';

  @override
  String get comicFormatPng => '单页 PNG';

  @override
  String get comicFormatCbz => 'CBZ 打包';

  @override
  String get novelFormatSelectTitle => '小说格式';

  @override
  String get novelFormatTxt => 'TXT';

  @override
  String get novelFormatEpub => 'EPUB';

  @override
  String get rsshubRouteBilibiliBangumi => 'B站番剧';

  @override
  String get rsshubRouteBilibiliBangumiPath =>
      '/bilibili/bangumi/media/:mediaid';

  @override
  String get rsshubRouteBilibiliMangaUpdate => 'B站漫画更新';

  @override
  String get rsshubRouteBilibiliMangaUpdatePath =>
      '/bilibili/manga/update/:comicid';

  @override
  String get rsshubRouteBilibiliUserVideo => 'B站UP主投稿';

  @override
  String get rsshubRouteBilibiliUserVideoPath => '/bilibili/user/video/:uid';

  @override
  String get rsshubRouteBilibiliRanking => 'B站排行榜';

  @override
  String get rsshubRouteBilibiliRankingPath =>
      '/bilibili/partion/ranking/:tid/:days?';

  @override
  String get rsshubRouteYoutubeChannel => 'YouTube频道';

  @override
  String get rsshubRouteYoutubeChannelPath => '/youtube/channel/:id';

  @override
  String get rsshubRouteTwitterUser => 'Twitter 用户';

  @override
  String get rsshubRouteLinovelib => '轻小说文库';

  @override
  String get rsshubRouteSfacg => 'SF轻小说';

  @override
  String get importMediaTitle => '导入媒体';

  @override
  String get importMediaFormatsHint => '支持 mp4、mkv、avi、mov 等常见视频格式';

  @override
  String get importMediaPickFile => '选择视频文件';

  @override
  String get importMediaPickFolder => '选择视频目录';

  @override
  String get importNovelTitle => '导入小说';

  @override
  String get importNovelFormatsHint => '支持 .txt 和 .epub 格式';

  @override
  String get importNovelPickFile => '选择文件';

  @override
  String get importNovelPickFolder => '选择目录';

  @override
  String get importComicTitle => '导入漫画';

  @override
  String get importComicFormatsHint => '支持 cbz、cbr、cbt 等常见漫画压缩格式';

  @override
  String get importComicPickFile => '选择漫画文件';

  @override
  String get importComicPickFolder => '选择漫画目录';

  @override
  String get novelBrightness => '亮度';

  @override
  String get playerLock => '锁定';

  @override
  String get playerUnlock => '解锁';

  @override
  String get playerAutoPlayNext => '自动连播';

  @override
  String get playerDecodeMode => '解码模式';

  @override
  String get playerDecodeAuto => '自动';

  @override
  String get playerDecodeSw => '软件解码';

  @override
  String get playerDecodeHw => '硬件解码';

  @override
  String get playerDecodeHwPlus => '硬件解码+';

  @override
  String get playerDecodeHwPlusHint => '花屏时推荐';

  @override
  String playerDecodeFallback(String mode) {
    return '检测到解码异常，已切换为$mode';
  }

  @override
  String get playerStats => '播放统计';

  @override
  String get playerStatsDecoder => '解码器';

  @override
  String get playerStatsHardware => '硬件解码';

  @override
  String get playerStatsSoftware => '软件解码';

  @override
  String get playerStatsVideoCodec => '视频编码';

  @override
  String get playerStatsPixelFormat => '像素格式';

  @override
  String get playerStatsResolution => '分辨率';

  @override
  String get playerStatsDroppedFrames => '掉帧（渲染 / 解码）';

  @override
  String get playerStatsBitrate => '视频码率';

  @override
  String get playerStatsBuffering => '缓冲进度';

  @override
  String get playerStatsUnavailable => '当前无法获取播放统计';

  @override
  String get playerAudioChannel => '音频通道';

  @override
  String get playerAudioStereo => '立体声';

  @override
  String get playerAudioMono => '单声道';

  @override
  String get playerAudioAutoProtect => '自动保护';

  @override
  String get playerAudioReverseStereo => '翻转立体声';

  @override
  String get playerAspectRatio => '画面比例';

  @override
  String get playerAspectDefault => '默认';

  @override
  String get playerAspectFill => '填充';

  @override
  String get playerAspect43 => '4:3';

  @override
  String get playerAspect169 => '16:9';

  @override
  String get playerPlaybackSpeed => '播放速度';

  @override
  String get playerLongPressSpeed => '长按播放速度';

  @override
  String get playerSubtitle => '字幕';

  @override
  String get playerSubtitleSettings => '字幕设置';

  @override
  String get playerSubtitleDelay => '字幕延迟(ms)';

  @override
  String get playerFontSize => '字体大小';

  @override
  String get playerSubtitleOutline => '字幕边框';

  @override
  String get playerTimer => '定时关闭';

  @override
  String get playerPlayInfo => '播放信息';

  @override
  String get playerExternalPlay => '外部播放';

  @override
  String get playerVideoExpired => '视频链接已失效，请重试';

  @override
  String get playerStallDetected => '播放卡顿，正在重连…';

  @override
  String get playerRetry => '重试';

  @override
  String get playerNextEpisode => '下一集';

  @override
  String get playerPreviousEpisode => '上一集';

  @override
  String get playerShare => '分享';

  @override
  String get danmakuFilterKeywords => '关键词过滤';

  @override
  String get danmakuTimeOffset => '时间偏移(秒)';

  @override
  String get danmakuArea => '显示区域';

  @override
  String get danmakuDuration => '持续时间(秒)';

  @override
  String get danmakuLineHeight => '行高';

  @override
  String get danmakuHideTop => '隐藏顶部';

  @override
  String get danmakuHideBottom => '隐藏底部';

  @override
  String get danmakuHideScroll => '隐藏滚动';

  @override
  String get danmakuFollowSpeed => '跟随倍速';

  @override
  String get danmakuAddKeyword => '添加关键词';

  @override
  String get danmakuKeywordHint => '输入关键词或正则表达式';

  @override
  String get danmakuSearch => '搜索弹幕';

  @override
  String get danmakuSearchHint => '输入动漫名称搜索';

  @override
  String get danmakuMatchEpisode => '匹配剧集';

  @override
  String get danmakuNoResult => '无搜索结果';

  @override
  String get danmakuLoadFailed => '弹幕加载失败';

  @override
  String get danmakuLoaded => '弹幕已加载';

  @override
  String get danmakuCacheHit => '弹幕已缓存';

  @override
  String get danmakuSourceTitle => '弹幕源';

  @override
  String get danmakuSourceHint => '选择弹幕来源';

  @override
  String get danmakuSourceDandanplay => '弹弹play';

  @override
  String get danmakuSourceBilibili => 'bilibili';

  @override
  String get danmakuSourceOff => '关闭';

  @override
  String get danmakuSourceDandanplayDesc => '自动按番剧名匹配';

  @override
  String get danmakuSourceBilibiliDesc => '按视频 av/BV 号匹配';

  @override
  String get danmakuSourceOffDesc => '不加载弹幕';

  @override
  String get danmakuDisplaySettingsTitle => '弹幕显示设置';

  @override
  String get danmakuDisplaySettingsDesc => '字体大小、不透明度、时间偏移等';

  @override
  String get danmakuFontSize => '字体大小';

  @override
  String get danmakuOpacity => '不透明度';

  @override
  String get playerSettingsTitle => '播放器设置';

  @override
  String get playerSettingsDesc => '解码模式、画面比例、播放速度等';

  @override
  String get playerDefaultDecodeMode => '默认解码模式';

  @override
  String get playerDefaultAudioChannel => '默认音频通道';

  @override
  String get playerDefaultAspectRatio => '默认画面比例';

  @override
  String get playerDefaultSpeed => '默认播放速度';

  @override
  String get playerDefaultAutoPlay => '默认自动连播';

  @override
  String get playerSubtitleFontSize => '字幕字体大小';

  @override
  String get subtitleTitle => '字幕';

  @override
  String get subtitleOffset => '偏移';

  @override
  String get subtitleShow => '显示字幕';

  @override
  String get subtitleNone => '无字幕';

  @override
  String get subtitleNoTracks => '无可用字幕轨道';

  @override
  String get subtitleStyleTitle => '字幕样式';

  @override
  String get subtitleFontSize => '字号';

  @override
  String get subtitleScale => '缩放';

  @override
  String get subtitleBorderSize => '边框宽度';

  @override
  String get subtitleShadowOffset => '阴影偏移';

  @override
  String get subtitleTextColor => '文字颜色';

  @override
  String get subtitleBorderColorLabel => '边框颜色';

  @override
  String get subtitleShadowColorLabel => '阴影颜色';

  @override
  String get subtitlePosition => '位置';

  @override
  String get subtitleAssOverride => '覆盖 ASS/SSA 样式';

  @override
  String subtitleTrackN(Object n) {
    return '轨道 $n';
  }

  @override
  String get readerSettingsTitle => '阅读器设置';

  @override
  String get readerSettingsDesc => '阅读模式、背景、方向等';

  @override
  String get readerGeneralGroup => '通用阅读偏好';

  @override
  String get novelReaderSettingsTitle => '小说阅读器设置';

  @override
  String get novelReaderSettingsDesc => '小说阅读全局默认设置';

  @override
  String get comicReaderSettingsTitle => '漫画阅读器设置';

  @override
  String get comicReaderSettingsDesc => '方向、点击区、滤镜、缩放手势等';

  @override
  String get novelTypographyGroup => '小说排版';

  @override
  String get novelShadow => '阴影开关';

  @override
  String get novelBackgroundPreset => '背景预设';

  @override
  String get novelTapZoneInvert => '点击区域翻转';

  @override
  String get comicFilterGroup => '图片滤镜';

  @override
  String get comicFilterBrightness => '亮度';

  @override
  String get comicFilterContrast => '对比度';

  @override
  String get comicFilterColorTemp => '色温';

  @override
  String get comicFilterInverted => '反色滤镜';

  @override
  String get comicTapZoneInvert => '点击区反转';

  @override
  String get novelZoomGroup => '缩放与排版';

  @override
  String get comicZoomGroup => '缩放与手势';

  @override
  String get readerDefaultMode => '默认阅读模式';

  @override
  String get readerDefaultBackground => '默认背景色';

  @override
  String get readerBackgroundWhite => '白色';

  @override
  String get readerBackgroundBeige => '米色';

  @override
  String get readerBackgroundDark => '深色';

  @override
  String get readerDefaultOrientation => '默认方向';

  @override
  String get readerOrientationHorizontal => '水平';

  @override
  String get readerOrientationVertical => '垂直';

  @override
  String get readerDoubleTapZoom => '双击缩放';

  @override
  String get readerOrientationLock => '方向锁定';

  @override
  String get layoutSettings => '布局设置';

  @override
  String get layoutSettingsDesc => '书架网格/列表、密度';

  @override
  String get bookshelfLayoutMode => '书架布局模式';

  @override
  String get bookshelfLayoutGrid => '网格';

  @override
  String get bookshelfLayoutList => '列表';

  @override
  String get bookshelfLayoutDensity => '网格密度';

  @override
  String get bookshelfDensityCompact => '紧凑';

  @override
  String get bookshelfDensityStandard => '标准';

  @override
  String get bookshelfDensityComfortable => '舒适';

  @override
  String get sourceHide => '隐藏';

  @override
  String get sourceShowHidden => '显示隐藏源';

  @override
  String get sourceEdit => '编辑源';

  @override
  String get sourceDelete => '删除源';

  @override
  String get sourceMigrate => '查看迁移说明';

  @override
  String get sourceEditBuiltinNotAllowed => '内置源不可编辑';

  @override
  String get sourceEditSaved => '源已更新';

  @override
  String get sourceEditFailed => '源更新失败';

  @override
  String get sourceEditJsonHint => '在此编辑该源的全部字段（JSON）。保存后将覆盖原配置，请确认格式正确。';

  @override
  String get sourceEditInvalidJson => 'JSON 格式或字段校验未通过，请检查后重试。';

  @override
  String get sourceDeleteBuiltinNotAllowed => '内置源不可删除';

  @override
  String get sourceDeleted => '源已删除';

  @override
  String get sourceDeleteFailed => '源删除失败';

  @override
  String get sourceDeprecatedHint => '此源已弃用，请使用替代源。';

  @override
  String get sourceNameLabel => '源名称';

  @override
  String get sourceUrlLabel => '源地址';

  @override
  String get back => '返回';

  @override
  String get sourceType => '类型';

  @override
  String get sourceTypeAnime => '动漫';

  @override
  String get sourceTypeManga => '漫画';

  @override
  String get sourceTypeNovel => '小说';

  @override
  String get playerTimerOff => '关闭定时';

  @override
  String playerTimerMinutes(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String get playerTimerCustom => '自定义';

  @override
  String get playerTimerCanceled => '已取消定时关闭';

  @override
  String get playerTimerFired => '定时关闭已触发，播放已暂停';

  @override
  String get noDescription => '暂无简介';

  @override
  String get aboutAppTitle => '关于';

  @override
  String get openSourceLicenses => '开源协议';

  @override
  String get thirdPartyLibraries => '第三方库';

  @override
  String get acknowledgements => '致谢';

  @override
  String get acknowledgementsLegado =>
      'NexHub 小说分页器以独立 Dart 实现借鉴了其 ChapterProvider 分页算法（未复制源码）。上游仓库未附带明确开源许可证，本致谢仅作启发署名。';

  @override
  String get acknowledgementsMihon =>
      '扩展源架构与漫画阅读器交互为 NexHub 的漫画解析与阅读体验提供了重要参考。以 Apache License 2.0 发布（© Mihon contributors）。';

  @override
  String get acknowledgementsRssHub =>
      '为 NexHub 的订阅功能提供 RSS 聚合服务。以 AGPL-3.0 发布（© DIYgod），NexHub 仅作客户端调用，未修改或再分发其源码。';

  @override
  String get acknowledgementsViewProject => '查看项目';

  @override
  String get acknowledgementsMoreLibs => '其余第三方库见「开源许可」列表。';

  @override
  String get projectRepository => '项目仓库';

  @override
  String get checkUpdate => '检查更新';

  @override
  String get updateChecking => '正在检查更新…';

  @override
  String get updateLatest => '已是最新版本';

  @override
  String updateAvailable(Object version) {
    return '发现新版本 $version';
  }

  @override
  String get updateAvailableHint => '是否前往发布页下载？';

  @override
  String get updateGoToDownload => '前往下载';

  @override
  String get updateCheckFailed => '检查更新失败，请稍后重试';

  @override
  String get settingsGroupLanguage => '语言';

  @override
  String get languageTitle => '界面语言';

  @override
  String get languageFollowSystem => '跟随系统';

  @override
  String get languageChinese => '简体中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get chapterList => '章节目录';

  @override
  String get currentChapter => '当前章';

  @override
  String get searchByAuthor => '按作者搜索';

  @override
  String get noRecommendation => '暂无推荐';

  @override
  String get restore => '恢复';

  @override
  String get archive => '归档';

  @override
  String get archivedEmpty => '没有已归档的内容';

  @override
  String get archivedHint => '归档后文件保留在磁盘，可随时恢复';

  @override
  String get deletePermanently => '彻底删除';

  @override
  String get restoreSuccess => '已恢复';

  @override
  String get statusArchived => '已归档';

  @override
  String get searchHistoryTitle => '搜索历史';

  @override
  String get clearSearchHistory => '清空历史';

  @override
  String get clearSearchHistoryConfirm => '确定清空所有搜索历史？';

  @override
  String get noSearchHistory => '暂无搜索历史';

  @override
  String get hotSearch => '热门搜索';

  @override
  String get noHotSearch => '暂无热词';

  @override
  String get importDataParsing => '正在解析…';

  @override
  String get importDataSuccess => '导入成功';

  @override
  String get importDataFailed => '导入失败';

  @override
  String get importDataInvalidFormat => '文件格式无效';

  @override
  String importDataSummary(int plugins, int favorites, int history) {
    return '已导入 $plugins 个插件 / $favorites 个收藏 / $history 条历史';
  }

  @override
  String get exportFolderDefault => '默认路径（文档）';

  @override
  String get exportDataSuccess => '导出成功';

  @override
  String get exportDataFailed => '导出失败';

  @override
  String get exportDataInProgress => '正在导出…';

  @override
  String exportDataFileSaved(String path) {
    return '已保存到 $path';
  }

  @override
  String get exportNothingToExport => '无数据可导出';

  @override
  String get notImplemented => '功能暂未实现';

  @override
  String get cast => '投屏';

  @override
  String get castNotSupportedYet => '投屏功能即将推出';

  @override
  String get cloudSync => '云同步';

  @override
  String get cloudSyncNotSupportedYet => '即将推出';

  @override
  String get cloudSyncNotConfigured => '未配置，点击设置';

  @override
  String get cloudSyncFeatureWebdav => 'WebDAV 备份';

  @override
  String get cloudSyncFeatureSync => '多端同步收藏与进度';

  @override
  String get enableRecommendedSources => '启用推荐源';

  @override
  String get enableRecommendedSourcesHint => '一键开启所有可用的推荐源';

  @override
  String recommendedSourcesEnabled(int count) {
    return '已启用 $count 个推荐源';
  }

  @override
  String get castToDevice => '投屏到设备';

  @override
  String castingTo(Object device) {
    return '正在投屏到 $device';
  }

  @override
  String get castNoDevices => '未找到投屏设备';

  @override
  String get castNotSupportedOnDevice => '当前设备不支持投屏';

  @override
  String get castDisconnect => '断开投屏';

  @override
  String get pip => '画中画';

  @override
  String get pipNotSupportedOnDevice => '当前设备不支持画中画';

  @override
  String get screenshot => '截图';

  @override
  String get screenshotSaved => '截图已保存';

  @override
  String get screenshotFailed => '截图失败';

  @override
  String get screenshotPathSetting => '截图保存路径';

  @override
  String get screenshotPathDefault => '默认路径（Documents/screenshots）';

  @override
  String get imageLoadFailed => '图片加载失败';

  @override
  String get seriesTitle => '系列';

  @override
  String get seasonsTitle => '季';

  @override
  String episodeCount(int count) {
    return '$count 集';
  }

  @override
  String seasonCount(int count) {
    return '$count 季';
  }

  @override
  String get imageFilter => '图片滤镜';

  @override
  String get brightness => '亮度';

  @override
  String get contrast => '对比度';

  @override
  String get colorTemperature => '色温';

  @override
  String get saturation => '饱和度';

  @override
  String get hue => '色相';

  @override
  String get resetFilter => '重置滤镜';

  @override
  String get saveImage => '保存图片';

  @override
  String get shareImage => '分享图片';

  @override
  String imageSavedTo(String path) {
    return '图片已保存到 $path';
  }

  @override
  String get imageSaveFailed => '图片保存失败';

  @override
  String get imagePathCopied => '图片路径已复制到剪贴板';

  @override
  String get chineseConverter => '繁简转换';

  @override
  String get noConvert => '不转换';

  @override
  String get traditionalToSimplified => '繁转简';

  @override
  String get simplifiedToTraditional => '简转繁';

  @override
  String get autoPageInterval => '自动翻页间隔';

  @override
  String get autoPageOff => '关闭';

  @override
  String get pauseAutoPage => '暂停自动翻页';

  @override
  String get resumeAutoPage => '恢复自动翻页';

  @override
  String get customFont => '自定义字体';

  @override
  String get fontSystem => '系统';

  @override
  String get fontSerif => '衬线';

  @override
  String get fontMonospace => '等宽';

  @override
  String get addBookmark => '添加书签';

  @override
  String get bookmarkList => '书签列表';

  @override
  String get bookmarkAdded => '书签已添加';

  @override
  String get deleteBookmark => '删除书签';

  @override
  String get noBookmarks => '暂无书签';

  @override
  String get bookmarkNoteHint => '备注（可选）';

  @override
  String novelChapterProgress(int current, int total) {
    return '第 $current 章 / 共 $total 章';
  }

  @override
  String get novelLetterSpacing => '字距';

  @override
  String get novelFontStyle => '字体样式';

  @override
  String get fontBold => '加粗';

  @override
  String get fontItalic => '斜体';

  @override
  String get fontUnderline => '下划线';

  @override
  String get novelTextColor => '正文颜色';

  @override
  String get novelTextColorFollowBg => '跟随背景自动配色';

  @override
  String get novelShadowColor => '阴影颜色';

  @override
  String get novelShadowColorAuto => '自动（正文色半透明）';

  @override
  String get novelSectionText => '阅读基础';

  @override
  String get novelSectionTitle => '章节标题';

  @override
  String get novelSectionColor => '颜色与背景';

  @override
  String get novelSectionPage => '翻页与手势';

  @override
  String get novelSectionMisc => '其他';

  @override
  String get novelShowChapterTitle => '正文显示章节标题';

  @override
  String get novelTitleFontScale => '标题字号倍数';

  @override
  String get novelTitleBold => '标题加粗';

  @override
  String get novelTitleColor => '标题颜色';

  @override
  String get novelTitleColorAuto => '跟随强调色';

  @override
  String get importShuyuan => '导入书源';

  @override
  String get shuyuanImportTitle => '导入书源';

  @override
  String get shuyuanImportHint => '支持书源规则（@css/@xpath/@json/@js + ## 正则）';

  @override
  String get shuyuanImportFromUrl => 'URL';

  @override
  String get shuyuanImportFromFile => '文件';

  @override
  String get shuyuanImportFromJson => 'JSON';

  @override
  String get shuyuanImportUrlHint => '书源 JSON 的 URL';

  @override
  String get shuyuanImportJsonHint => '粘贴书源 JSON 配置';

  @override
  String get shuyuanImportFilePicker => '选择书源文件';

  @override
  String get shuyuanImportParse => '解析';

  @override
  String get shuyuanImportParsing => '解析中…';

  @override
  String get shuyuanImportParseFailed => '解析失败，未识别到有效书源';

  @override
  String shuyuanImportPreview(int count) {
    return '预览（$count）';
  }

  @override
  String get shuyuanImportSaveAll => '全部导入';

  @override
  String get shuyuanImportEmpty => '暂无解析结果';

  @override
  String get shuyuanImportValid => '有效';

  @override
  String get shuyuanImportInvalid => '无效';

  @override
  String shuyuanImportSuccess(int count) {
    return '已导入 $count 个书源';
  }

  @override
  String shuyuanImportSelected(int count) {
    return '导入选中 $count 项';
  }

  @override
  String get shuyuanImportFailed => '导入失败';

  @override
  String get shareFailed => '分享失败';

  @override
  String get openInBrowserFailed => '无法打开浏览器';

  @override
  String get updatedAtLabel => '更新时间：';

  @override
  String get searchChapter => '搜索章节';

  @override
  String get noChaptersFound => '未找到匹配章节';

  @override
  String expandRemainingChapters(int count) {
    return '展开剩余 $count 章';
  }

  @override
  String get sortAscending => '升序';

  @override
  String get sortDescending => '降序';

  @override
  String get downloadSingleChapter => '下载单章';

  @override
  String get chapterBookmark => '章节书签';

  @override
  String get chapterRead => '已读标记';

  @override
  String get continueReading => '继续阅读';

  @override
  String get continueWatching => '继续观看';

  @override
  String get startFromBeginning => '从头开始';

  @override
  String get openInAppBrowser => '应用内打开';

  @override
  String get refreshMetadata => '刷新信息';

  @override
  String get removeFromFavorites => '从收藏移除';

  @override
  String get coverViewer => '封面';

  @override
  String get downloadPreset1 => '下载最新1集';

  @override
  String get downloadPreset5 => '下载最新5集';

  @override
  String get downloadPreset10 => '下载最新10集';

  @override
  String get downloadUnread => '下载未读';

  @override
  String get downloadFavorited => '下载已收藏';

  @override
  String get tagLabel => '标签';

  @override
  String get sourceLabel => '来源';

  @override
  String get reloadChapter => '重载本章';

  @override
  String get clearReadingProgress => '清除阅读进度';

  @override
  String get readingProgressCleared => '阅读进度已清除';

  @override
  String get novelMenuBookmarkList => '书签列表';

  @override
  String get novelMenuConfigureToolbar => '配置底部工具栏';

  @override
  String get novelTtsBackground => '后台朗读';

  @override
  String get novelSectionFont => '字体样式';

  @override
  String get searchInBook => '书内搜索';

  @override
  String get wholeBook => '全书';

  @override
  String get noSearchResults => '无搜索结果';

  @override
  String get customBgColor => '自定义背景色';

  @override
  String get tapZoneInvert => '点击反转';

  @override
  String get tapInvertNone => '不反转';

  @override
  String get tapInvertLeftRight => '左右反转';

  @override
  String get tapInvertAll => '全反转';

  @override
  String get tapZonePreview => '预览点按区域';

  @override
  String get tapZonePrev => '上一页';

  @override
  String get tapZoneNext => '下一页';

  @override
  String get tapZoneToggle => '切换界面';

  @override
  String get startReading => '开始朗读';

  @override
  String get stopReading => '停止朗读';

  @override
  String get noteList => '笔记列表';

  @override
  String get noNotes => '暂无笔记';

  @override
  String get add => '添加';

  @override
  String get testConnection => '测试连接';

  @override
  String get noCustomInstances => '暂无自定义实例';

  @override
  String get searchByDirector => '按导演搜索';

  @override
  String get searchByActor => '按演员搜索';

  @override
  String get searchByTag => '按标签搜索';

  @override
  String get searchAggregate => '聚合全部源';

  @override
  String get searchSingle => '单源';

  @override
  String get searchSelectSource => '选择一个源';

  @override
  String get searchByWork => '按作品名搜索';

  @override
  String get searchFieldAuthor => '作者';

  @override
  String get searchFieldDirector => '导演';

  @override
  String get searchFieldActor => '主演';

  @override
  String get searchFieldWork => '作品';

  @override
  String get rsshubRouteQidian => '起点';

  @override
  String get rsshubRouteJjwxc => '晋江文学城';

  @override
  String get rsshubRouteDoubanBooks => '豆瓣图书';

  @override
  String get rsshubRouteDmzj => '动漫之家';

  @override
  String get rsshubRouteJmcomic => '禁漫天堂';

  @override
  String browseNetworkSelectedCount(int count) {
    return '已选 $count 项';
  }

  @override
  String get browseNetworkOpenSelected => '打开';

  @override
  String get browseNetworkDownloadSelected => '下载';

  @override
  String browseNetworkDownloadStarted(int count) {
    return '开始下载 $count 个文件';
  }

  @override
  String browseNetworkDownloadDone(int count) {
    return '已下载 $count 项';
  }

  @override
  String get browseNetworkDownloadFailed => '下载失败';

  @override
  String get browseNetworkDownloadPathMissing => '下载路径不可用';

  @override
  String get unknown => '未知';

  @override
  String get rssFeedListTitle => 'RSS 订阅';

  @override
  String get rssTestAllSpeed => '一键测速';

  @override
  String get rssSpeedFailed => '测速失败';

  @override
  String rssSpeedMs(int ms) {
    return '${ms}ms';
  }

  @override
  String unrecognizedFile(String fileName) {
    return '未识别的文件：$fileName';
  }

  @override
  String importFailed(String reason) {
    return '导入失败：$reason';
  }

  @override
  String get folderScanFailed => '文件夹扫描失败，请检查权限或路径';

  @override
  String get emptyFolder => '文件夹为空或无可用文件';

  @override
  String get storagePermissionDenied => '存储权限被拒绝，无法选择文件';

  @override
  String get pickFileNoPath => '无法获取所选文件路径（可能是系统限制），请尝试其他文件';

  @override
  String get folderPickUnsupportedSaf =>
      '当前系统不支持选择文件夹导入（Android SAF 限制），请改用「选择文件」逐个添加';

  @override
  String get setAsShelfCover => '设为书架封面';

  @override
  String get openDownloadManager => '打开下载管理';

  @override
  String get details => '详情';

  @override
  String get coverUpdated => '封面已更新';

  @override
  String get coverUpdateFailed => '封面更新失败：未找到收藏条目';

  @override
  String get authorLabel => '作者';

  @override
  String get statusLabel => '状态';

  @override
  String get setAsCover => '设为封面';

  @override
  String get mediaInfo => '媒体信息';

  @override
  String get playExternal => '外部播放';

  @override
  String get loadExternalSubtitle => '导入外部字幕';

  @override
  String get loadExternalSubtitleFailed => '外部字幕加载失败';

  @override
  String get danmakuCustomUrl => '自定义 URL';

  @override
  String get danmakuCustomUrlHint => '输入弹幕源 URL';

  @override
  String get danmakuCustomUrlDesc => '从自定义 URL 加载弹幕';

  @override
  String get onlineTabHome => '首页';

  @override
  String get onlineTabSchedule => '周期表';

  @override
  String get onlineTabRanking => '排行';

  @override
  String get filterYear => '年份';

  @override
  String get filterRegion => '地区';

  @override
  String get filterSort => '排序';

  @override
  String get filterCategory => '分类';

  @override
  String get filterTag => '标签';

  @override
  String get sortHottest => '最热';

  @override
  String get sortRating => '评分';

  @override
  String get viewAll => '查看全部';

  @override
  String get latestUpdates => '最新更新';

  @override
  String get hotRecommendations => '热门推荐';

  @override
  String get weekdayMon => '周一';

  @override
  String get weekdayTue => '周二';

  @override
  String get weekdayWed => '周三';

  @override
  String get weekdayThu => '周四';

  @override
  String get weekdayFri => '周五';

  @override
  String get weekdaySat => '周六';

  @override
  String get weekdaySun => '周日';

  @override
  String get regionChina => '中国大陆';

  @override
  String get regionHongKong => '中国香港';

  @override
  String get regionTaiwan => '中国台湾';

  @override
  String get regionJapan => '日本';

  @override
  String get regionKorea => '韩国';

  @override
  String get regionUSA => '美国';

  @override
  String get regionOther => '其他';

  @override
  String get unsupportedRarFormat => '暂不支持 RAR 格式漫画';

  @override
  String get unsupportedEpubFormat => '暂不支持 EPUB 格式，请使用专用阅读器';

  @override
  String get unsupportedFormat => '暂不支持该格式';

  @override
  String get localFileLabel => '本地文件';

  @override
  String get localFileLoadFailed => '本地文件读取失败';

  @override
  String get playerDefaultOrientation => '锁定方向';

  @override
  String get playerOrientationAuto => '自动跟随';

  @override
  String get playerOrientationPortrait => '竖屏';

  @override
  String get playerOrientationLandscape => '横屏';

  @override
  String get playerGestureSeekMultiplier => '拖动进度倍率';

  @override
  String get playerSeekHalf => '0.5x';

  @override
  String get playerSeekNormal => '1x';

  @override
  String get playerSeekDouble => '2x';

  @override
  String get playerLongPressSpeedUp => '长按加速';

  @override
  String get playerDefaultVolume => '默认音量';

  @override
  String get playerResetEpisodeSettings => '重置该视频设置';

  @override
  String get playerResetEpisodeSettingsDone => '已恢复该视频的全局默认设置';

  @override
  String get playerCoreGroup => '播放核心';

  @override
  String get playerSubtitleGroup => '字幕';

  @override
  String get playerGestureGroup => '手势与控制';

  @override
  String get playerScreenshotGroup => '截图';

  @override
  String get novelDefaultGroupTitle => '小说默认';

  @override
  String get novelDefaultPageTurnAnimation => '翻页动画';

  @override
  String get novelDefaultFontSize => '默认字号';

  @override
  String get novelDefaultLineHeight => '默认行距';

  @override
  String get novelDefaultBackground => '背景色';

  @override
  String get novelDefaultTtsRate => '朗读语速';

  @override
  String get novelDefaultChineseConversion => '简繁转换';

  @override
  String get novelBgWhite => '白色';

  @override
  String get novelBgCream => '米黄';

  @override
  String get novelBgDarkGray => '深灰';

  @override
  String get novelBgBlack => '黑色';

  @override
  String get comicDefaultGroupTitle => '漫画默认';

  @override
  String get comicDefaultReadingDirection => '阅读方向';

  @override
  String get comicDefaultTapZoneLayout => '点击区域';

  @override
  String get comicDefaultInvertFilter => '反色滤镜';

  @override
  String get comicDefaultInitialZoom => '初始缩放';

  @override
  String get comicDefaultDoubleTapZoom => '双击缩放';

  @override
  String get comicDefaultScrollWheel => '滚轮方向';

  @override
  String get comicTapLayout1 => '布局 1';

  @override
  String get comicTapLayout2 => '布局 2';

  @override
  String get comicTapLayout3 => '布局 3';

  @override
  String get comicTapLayout4 => '布局 4';

  @override
  String get comicTapLayout5 => '布局 5';

  @override
  String get comicZoomFitWidth => '适应宽度';

  @override
  String get comicZoomFitHeight => '适应高度';

  @override
  String get comicZoomOriginal => '原始尺寸';

  @override
  String get comicZoom2x => '2x';

  @override
  String get comicZoom3x => '3x';

  @override
  String get comicWheelNatural => '自然';

  @override
  String get comicWheelInverted => '反向';

  @override
  String get comicDirLtr => '左→右';

  @override
  String get comicDirRtl => '右→左';

  @override
  String get comicDirVertical => '上下';

  @override
  String get comicDirWebtoon => '瀑布流';

  @override
  String get comicDirWebtoonGap => '瀑布流（带间距）';

  @override
  String get danmakuDisplayFontSize => '字体大小';

  @override
  String get danmakuDisplayOpacity => '透明度';

  @override
  String get danmakuDisplayScrollSpeed => '滚动速度';

  @override
  String get danmakuDisplayArea => '显示区域';

  @override
  String get danmakuDisplayMaxOnScreen => '同屏上限';

  @override
  String get danmakuSizeSmall => '小';

  @override
  String get danmakuSizeMedium => '中';

  @override
  String get danmakuSizeLarge => '大';

  @override
  String get danmakuSpeedSlow => '慢';

  @override
  String get danmakuSpeedMedium => '中';

  @override
  String get danmakuSpeedFast => '快';

  @override
  String get danmakuAreaQuarter => '1/4';

  @override
  String get danmakuAreaHalf => '半屏';

  @override
  String get danmakuAreaFull => '全屏';

  @override
  String get danmakuMaxTen => '10';

  @override
  String get danmakuMaxTwenty => '20';

  @override
  String get danmakuMaxFifty => '50';

  @override
  String get danmakuMaxHundred => '100';

  @override
  String get danmakuDisplayGroupFilter => '过滤与屏蔽';

  @override
  String get danmakuDisplayGroupAppearance => '外观';

  @override
  String get danmakuDisplayGroupDisplay => '显示';

  @override
  String get danmakuDisplayGroupDisplayRange => '显示范围';

  @override
  String get danmakuDisplayGroupSpeed => '速度';

  @override
  String get layoutTypeLabel => '布局类型';

  @override
  String get layoutGridLarge => '大网格';

  @override
  String get layoutGridMedium => '中网格';

  @override
  String get layoutGridSmall => '小网格';

  @override
  String get layoutListComfortable => '舒适列表';

  @override
  String get layoutListCompact => '紧凑列表';

  @override
  String get layoutGridColumns => '网格列数';

  @override
  String get layoutGridSpacing => '网格间距';

  @override
  String get layoutCoverRadius => '封面圆角';

  @override
  String get layoutTitleFontSize => '标题字号';

  @override
  String get layoutShowTitle => '显示标题';

  @override
  String get layoutTitleMaxLines => '标题行数';

  @override
  String get layoutShowAuthor => '显示作者';

  @override
  String get layoutShowProgress => '显示进度';

  @override
  String get layoutOpenSettings => '打开布局设置';

  @override
  String get bookshelfLayoutGroup => '书架布局';

  @override
  String get layoutTypeGroup => '全局布局类型';

  @override
  String get layoutGridCoverGroup => '网格与封面';

  @override
  String get layoutDisplayGroup => '显示选项';

  @override
  String get downloadStatusInProgress => '进行中';

  @override
  String get cloudSyncWebdavUrl => 'WebDAV 地址';

  @override
  String get cloudSyncWebdavUsername => '用户名';

  @override
  String get cloudSyncWebdavPassword => '密码';

  @override
  String get cloudSyncTestConnection => '测试连接';

  @override
  String cloudSyncConnectionSuccess(int ms) {
    return '连接成功（${ms}ms）';
  }

  @override
  String get cloudSyncConnectionFailed => '连接失败';

  @override
  String get cloudSyncAutoSync => '自动同步';

  @override
  String get cloudSyncSyncFrequencyManual => '手动';

  @override
  String get cloudSyncSyncFrequencyDaily => '每日';

  @override
  String get cloudSyncSyncFrequencyWeekly => '每周';

  @override
  String get cloudSyncSyncNow => '立即同步';

  @override
  String cloudSyncLastSyncTime(String time) {
    return '上次同步：$time';
  }

  @override
  String get cloudSyncNeverSynced => '尚未同步';

  @override
  String get cloudSyncSyncSuccess => '同步成功';

  @override
  String get cloudSyncSyncFailed => '同步失败';

  @override
  String get cloudSyncSaveConfig => '保存配置';

  @override
  String get readingProgress => '阅读进度';

  @override
  String get watchingProgress => '观看进度';

  @override
  String get totalChapters => '总章节';

  @override
  String get totalEpisodes => '总集数';

  @override
  String get chaptersRead => '已读';

  @override
  String get episodesWatched => '已看';

  @override
  String get progressLabel => '进度';

  @override
  String get layoutModeLabel => '布局模式';

  @override
  String get layoutListStyle => '列表风格';

  @override
  String get lastReadAt => '上次阅读';

  @override
  String get lastWatchedAt => '上次观看';

  @override
  String get anime => '番剧';

  @override
  String get episodeList => '选集';

  @override
  String chapterListWithCount(int count) {
    return '章节目录（$count）';
  }

  @override
  String episodeListWithCount(int count) {
    return '选集（$count）';
  }

  @override
  String lastReadInfo(String time, String chapter) {
    return '上次阅读：$time · $chapter';
  }

  @override
  String lastWatchedInfo(String time, String episode) {
    return '上次观看：$time · $episode';
  }

  @override
  String get notStartedYet => '尚未开始';

  @override
  String get timeJustNow => '刚刚';

  @override
  String timeMinutesAgo(int n) {
    return '$n 分钟前';
  }

  @override
  String timeHoursAgo(int n) {
    return '$n 小时前';
  }

  @override
  String timeDaysAgo(int n) {
    return '$n 天前';
  }

  @override
  String get expand => '展开';

  @override
  String get collapse => '收起';

  @override
  String expandCount(int count) {
    return '展开 $count 位';
  }

  @override
  String get sortSectionTitle => '排序';

  @override
  String get displayTitle => '显示选项';

  @override
  String sortByIndex(Object unitWord) {
    return '按$unitWord顺序';
  }

  @override
  String sortByName(Object unitWord) {
    return '按$unitWord名';
  }

  @override
  String get sortBySource => '按来源';

  @override
  String get sortByUploadDate => '按更新时间';

  @override
  String get sortAscendingLabel => '升序';

  @override
  String get sortDescendingLabel => '降序';

  @override
  String get filterUnread => '仅未读';

  @override
  String get filterDownloaded => '已下载';

  @override
  String get filterBookmarked => '已书签';

  @override
  String get displaySourceTitle => '来源标题';

  @override
  String displayNumber(Object unitWord) {
    return '$unitWord序号';
  }

  @override
  String get resetButton => '重置';

  @override
  String get doneButton => '完成';

  @override
  String get wordCount => '字数';

  @override
  String updatedTo(Object n) {
    return '更新至 $n';
  }

  @override
  String get unitWordChapter => '章';

  @override
  String get unitWordComicChapter => '话';

  @override
  String get unitWordEpisode => '集';

  @override
  String get prevPage => '上一页';

  @override
  String get nextPage => '下一页';

  @override
  String get nightMode => '夜间模式';

  @override
  String get toolToc => '目录';

  @override
  String get toolPrevChapter => '上一章';

  @override
  String get toolNextChapter => '下一章';

  @override
  String get toolNightMode => '夜间';

  @override
  String get toolAutoPage => '自动翻页';

  @override
  String get toolSettings => '设置';

  @override
  String get toolBookmark => '书签';

  @override
  String get toolBookmarkList => '书签列表';

  @override
  String get toolSearch => '书内搜索';

  @override
  String get toolTts => '朗读';

  @override
  String get configureBottomToolbar => '配置底部工具栏';

  @override
  String get bottomToolbarConfigTitle => '底部工具栏';

  @override
  String get slotsShown => '已显示';

  @override
  String get slotsHidden => '已隐藏（点 + 添加）';

  @override
  String get novelCacheBook => '缓存本书';

  @override
  String get novelResetBookPrefs => '恢复本书默认';

  @override
  String get novelResetBookDone => '已恢复本书默认设置';

  @override
  String get readerCropEdge => '裁边';

  @override
  String get readerRotatePage => '旋转页面';

  @override
  String get readerKeepScreenOn => '屏幕常亮';

  @override
  String get readerProgressBarOnRight => '进度条在右侧';

  @override
  String get readerShowPageNumber => '显示页码';

  @override
  String get readerSplitDoublePage => '双页拆分';

  @override
  String get readerSplitDoublePageHint => '已开启双页拆分，已切换到横排单页模式';

  @override
  String get readerInitialZoom => '初始缩放';

  @override
  String get readerZoomFitWidth => '适配宽度';

  @override
  String get readerZoomFitHeight => '适配高度';

  @override
  String get readerZoomOriginal => '原始大小';

  @override
  String get readerFullscreen => '全屏';

  @override
  String get readerLongPressMenu => '长按菜单';

  @override
  String get readerGrayscale => '灰度';

  @override
  String get readerPreventShrink => '防止缩小';

  @override
  String get readerChapterTransition => '章节过渡';

  @override
  String get comicDefaultFullscreen => '全屏';

  @override
  String get comicDefaultLongPressMenu => '长按菜单';

  @override
  String get comicDefaultGrayscale => '灰度';

  @override
  String get comicDefaultPreventShrink => '防止缩小';

  @override
  String get comicDefaultChapterTransition => '章节过渡';

  @override
  String get copyImage => '复制图片';

  @override
  String get copyImageSuccess => '图片已复制到剪贴板';

  @override
  String get copyImageFailed => '图片复制失败';

  @override
  String chapterTransitionCard(Object title) {
    return '章节：$title';
  }

  @override
  String get readerProgress => '进度';

  @override
  String get regexSearch => '正则';

  @override
  String get locateCurrent => '定位当前';

  @override
  String get scrollToTop => '置顶';

  @override
  String get scrollToBottom => '置底';

  @override
  String get bookmarkedHint => '已加书签';

  @override
  String get playerFullscreen => '全屏';

  @override
  String get playerExitFullscreen => '退出全屏';

  @override
  String get playerScreenshot => '截图';

  @override
  String get playerBrightness => '亮度';

  @override
  String get playerVolume => '音量';

  @override
  String get playerSuperRes => '超分辨率';

  @override
  String get playerLine => '播放线路';

  @override
  String get playerSelectLine => '选择线路';

  @override
  String get playerLineEmpty => '暂无播放线路（解析失败或源未提供视频地址）';

  @override
  String get playerLineSingleHint =>
      '当前源只返回了 1 条线路，无法切换。\n如需多线路切换，请联系源作者在视频解析 API 中返回 urls 数组。';

  @override
  String playerLineEpisodesProgress(int current, int total) {
    return '第 $current / $total 集';
  }

  @override
  String get playerEpisodes => '选集';

  @override
  String get playerPip => '画中画';

  @override
  String get playerCast => '投屏';

  @override
  String get playerMore => '更多';

  @override
  String get seekForward10 => '快进 10 秒';

  @override
  String get seekBackward10 => '快退 10 秒';

  @override
  String get novelTitleAlignLeft => '左对齐';

  @override
  String get novelTitleAlignCenter => '居中';

  @override
  String get novelTitleAlignRight => '右对齐';

  @override
  String get novelTitleAlignHidden => '隐藏';

  @override
  String get novelSectionToolbar => '底部工具栏';

  @override
  String get novelSectionTts => '朗读设置';

  @override
  String get ttsRate => '朗读语速';

  @override
  String get ttsSleepTimer => '睡眠定时';

  @override
  String get ttsSleepOff => '关闭';

  @override
  String get ttsSleepCustom => '自定义';

  @override
  String get ttsSleepCustomMinutes => '自定义分钟数';

  @override
  String ttsSleepRemaining(int min, int sec) {
    return '剩余 $min 分 $sec 秒';
  }

  @override
  String get ttsPrevSentence => '上一句';

  @override
  String get ttsPauseOrResume => '暂停 / 继续';

  @override
  String get ttsExit => '退出朗读';

  @override
  String get ttsNextSentence => '下一句';

  @override
  String minuteUnit(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String get novelFontFileGroup => '字体文件与强调色';

  @override
  String get novelChooseFontFile => '正文字体文件';

  @override
  String get novelTitleFontFile => '标题字体文件';

  @override
  String get novelResetConfirm => '确定要将所有小说阅读设置恢复为默认吗？此操作不可恢复。';

  @override
  String get novelSettingsSearch => '搜索设置';

  @override
  String get novelSettingsCommon => '常用';

  @override
  String get novelSettingsNoResult => '无匹配的设置项';

  @override
  String novelFontFileCurrent(String name) {
    return '已选：$name';
  }

  @override
  String get novelClearFontFile => '清除字体文件';

  @override
  String get novelEmphasisColor => '强调色';

  @override
  String get novelEmphasisColorAuto => '自动（标题色）';

  @override
  String get novelSectionShadowUnderline => '阴影与下划线';

  @override
  String get novelShadowBlur => '阴影模糊半径';

  @override
  String get novelShadowOffsetX => '阴影水平偏移';

  @override
  String get novelShadowOffsetY => '阴影垂直偏移';

  @override
  String get novelUnderlineColor => '下划线颜色';

  @override
  String get novelUnderlineColorAuto => '自动（正文色）';

  @override
  String get novelUnderlineDashed => '虚线下划线';

  @override
  String get novelUnderlineThickness => '下划线线宽';

  @override
  String get novelUnderlineDashLength => '实线段长';

  @override
  String get novelUnderlineDashGap => '间隙比例';

  @override
  String get novelTitlePosition => '标题显示位置';

  @override
  String get novelTitleSegmentMode => '标题分段模式';

  @override
  String get novelTitleSubScale => '次行字号倍率';

  @override
  String get novelTitleSegmentSpacing => '主次行间距';

  @override
  String get novelTitleSubLineSpacing => '次行行距';

  @override
  String get novelTitleTopMargin => '标题上边距';

  @override
  String get novelTitleBottomMargin => '标题下边距';

  @override
  String get novelSectionHeaderFooter => '页眉页脚';

  @override
  String get novelHeaderLeft => '页眉左侧';

  @override
  String get novelHeaderCenter => '页眉中间';

  @override
  String get novelHeaderRight => '页眉右侧';

  @override
  String get novelFooterLeft => '页脚左侧';

  @override
  String get novelFooterCenter => '页脚中间';

  @override
  String get novelFooterRight => '页脚右侧';

  @override
  String get novelHeaderFooterColor => '页眉页脚颜色';

  @override
  String get novelHeaderFooterMargin => '页眉页脚边距';

  @override
  String get novelHfPageAndProgress => '页码及进度';

  @override
  String get novelHfTimeAndBattery => '时间及电量';

  @override
  String get layoutDetailGroup => '布局细节';

  @override
  String get layoutProgressDisplay => '进度显示方式';

  @override
  String get progressBar => '进度条';

  @override
  String get progressText => '百分比';

  @override
  String get editRoute => '修改路由';

  @override
  String get routeTitle => '标题';

  @override
  String get routeUrl => '地址';

  @override
  String get routeSaved => '路由已保存';

  @override
  String get requiredHint => '此项为必填';

  @override
  String get localImportPickFile => '选择本地文件';

  @override
  String get sourceName => '名称';

  @override
  String get sourceBaseUrl => '基础地址';

  @override
  String get sourceCannotEdit => '内置源不可编辑';

  @override
  String get sourceCannotDelete => '内置源不可删除';

  @override
  String get comicVisualZoomGroup => '画面与缩放';

  @override
  String get comicPageProgressGroup => '页面与进度';

  @override
  String get generalSettingsGroup => '通用';

  @override
  String get launchScreenTitle => '启动界面';

  @override
  String get dateFormatTitle => '日期格式';

  @override
  String get dateFormatDefault => '默认（yyyy/mm/dd）';

  @override
  String get dateFormatMmDdYy => 'mm/dd/yy';

  @override
  String get dateFormatDdMmYy => 'dd/mm/yy';

  @override
  String get dateFormatYyyyMmDd => 'yyyy-mm-dd';

  @override
  String get dateFormatDdMmmYyyy => 'dd mmm yyyy';

  @override
  String get dateFormatMmmDd => 'mmm dd';

  @override
  String get dateFormatYyyy => 'yyyy';

  @override
  String get comicSettingsOverview => '当前设置概览';

  @override
  String get comicResetConfirm => '确定要将所有漫画阅读设置恢复为默认吗？此操作不可恢复。';

  @override
  String get on => '开';

  @override
  String get off => '关';

  @override
  String get readerGroupPageTap => '翻页与点击';

  @override
  String get readerGroupViewFilter => '画面与滤镜';

  @override
  String get readerGroupProgress => '进度与显示';

  @override
  String get readerGroupFlash => '闪屏效果';

  @override
  String get readerCommonSettings => '常用设置';

  @override
  String get readerGroupPageTapDesc => '调整翻页方式、屏幕方向、点击区域与缩放等基础阅读操作。';

  @override
  String get readerGroupViewFilterDesc => '调节亮度、对比度、色温与灰度等画面效果。';

  @override
  String get readerGroupProgressDesc => '控制页码、进度条、全屏、常亮与页面旋转等显示选项。';

  @override
  String get readerGroupFlashDesc => '设置翻页时的闪光提示效果（模拟翻页灯）。';

  @override
  String get readerSearchSettings => '搜索设置…';

  @override
  String get readerGroupMouseWheel => '鼠标滚轮';

  @override
  String get readerGroupMouseWheelDesc => '设置滚轮的作用（缩放页面或翻页）以及滚动方向。';

  @override
  String get readerWheelZoom => '缩放';

  @override
  String get readerWheelPage => '翻页';

  @override
  String get readerWheelAction => '作用';

  @override
  String get favoriteGroups => '收藏分组';

  @override
  String get noGroups => '暂无分组，点击下方按钮新建';

  @override
  String get groupAll => '全部';

  @override
  String get groupUngrouped => '未分组';

  @override
  String get manageGroups => '管理分组';

  @override
  String get newGroup => '新建分组';

  @override
  String get renameGroup => '重命名';

  @override
  String get renameHint => '请输入新名称';

  @override
  String get groupName => '分组名称';

  @override
  String get groupNameEmpty => '名称不能为空';

  @override
  String get groupNameDuplicate => '已存在同名分组';

  @override
  String get deleteGroup => '删除分组';

  @override
  String deleteGroupConfirm(Object name) {
    return '删除分组「$name」？仅解除条目与该分组的关联，收藏不受影响。';
  }

  @override
  String get setGroups => '设分组';

  @override
  String get filterByGroup => '分组';

  @override
  String groupItemCount(Object n) {
    return '$n 项';
  }

  @override
  String get hideCategory => '隐藏';

  @override
  String get showCategory => '显示';

  @override
  String get categoryHidden => '已隐藏';

  @override
  String get noGroupsHint => '还没有分类，点「新建分组」创建一个';

  @override
  String get comments => '评论';

  @override
  String commentsCount(Object n) {
    return '评论 ($n)';
  }

  @override
  String get writeComment => '写评论';

  @override
  String get replyComment => '回复';

  @override
  String get viewAllComments => '查看全部评论';

  @override
  String get allCommentsTitle => '全部评论';

  @override
  String get emptyComments => '暂无评论';

  @override
  String get beFirstToComment => '发表第一条评论';

  @override
  String get commentPublish => '发布';

  @override
  String get commentHint => '说点什么…';

  @override
  String get commentPublishSuccess => '评论已发布';

  @override
  String get commentPublishFailed => '发布失败';

  @override
  String get likeAction => '点赞';

  @override
  String get likeFailed => '点赞失败';

  @override
  String get reportAction => '举报';

  @override
  String get reportSuccess => '已举报';

  @override
  String get reportFailed => '举报失败';

  @override
  String get viewMoreReplies => '查看更多回复';

  @override
  String get commentsLoadFailed => '评论加载失败';

  @override
  String get loginToComment => '登录后评论';

  @override
  String get loginRequired => '该操作需要登录';

  @override
  String get sourceLogin => '源登录';

  @override
  String get webLogin => '网页登录';

  @override
  String get webLoginDesc => '在站点页面完成登录，自动捕获会话';

  @override
  String get pasteCookie => '粘贴 Cookie';

  @override
  String get pasteCookieDesc => '手动粘贴浏览器中的 Cookie 头';

  @override
  String get cookieHint => '如 token=abc; session=xyz';

  @override
  String get loginSuccess => '登录成功';

  @override
  String get loginExpired => '登录已失效，请重新登录';

  @override
  String get logoutAction => '退出登录';

  @override
  String get loggedInState => '已登录';

  @override
  String get loginDone => '完成';

  @override
  String get webviewLoginUnsupported => '当前平台不支持内置网页登录，请使用「粘贴 Cookie」方式。';

  @override
  String get bangumiSettings => 'Bangumi 同步';

  @override
  String get bangumiSettingsSubtitle => '推送收藏与进度到 bgm.tv';

  @override
  String get bangumiRatingSync => 'Bangumi 评分与同步';

  @override
  String get bangumiAccount => '账号';

  @override
  String get bangumiTokenHint => '粘贴个人 Access Token';

  @override
  String get bangumiTokenVerify => '验证并保存';

  @override
  String get bangumiGetToken => '获取 Token';

  @override
  String bangumiLoggedInAs(String name) {
    return '已登录：$name';
  }

  @override
  String get bangumiTokenSaved => 'Token 验证成功';

  @override
  String get bangumiTokenInvalid => 'Token 无效，请检查后重试';

  @override
  String get bangumiNotLoggedIn => '未登录';

  @override
  String get bangumiSyncNow => '立即同步';

  @override
  String get bangumiSyncDone => '同步完成';

  @override
  String get bangumiSyncFailed => '同步失败';

  @override
  String bangumiLastSync(String time) {
    return '上次同步：$time';
  }

  @override
  String get bangumiNeverSynced => '尚未同步';

  @override
  String get bangumiSyncTypes => '同步类型';

  @override
  String get bangumiSyncTypeAnime => '动漫与影视';

  @override
  String get bangumiSyncTypeManga => '漫画';

  @override
  String get bangumiSyncTypeNovel => '小说';

  @override
  String get bangumiSyncLog => '同步日志';

  @override
  String get bangumiLogSuccess => '已同步';

  @override
  String get bangumiLogSkipped => '跳过（无变化）';

  @override
  String get bangumiLogFailed => '失败';

  @override
  String get bangumiPendingBind => '待手动绑定';

  @override
  String get bangumiBindAndRate => 'Bangumi 绑定与评分';

  @override
  String get bangumiBindSubject => '绑定 Bangumi 条目';

  @override
  String get bangumiSearchHint => '搜索 Bangumi 条目';

  @override
  String get bangumiNoResults => '无匹配条目';

  @override
  String bangumiBoundTo(int id) {
    return '已绑定条目 #$id';
  }

  @override
  String get bangumiUnbind => '解除绑定';

  @override
  String get bangumiMarkCollected => '标记为看过';

  @override
  String get bangumiMyRating => '我的评分';

  @override
  String get bangumiRatingNone => '未评分';

  @override
  String get bangumiMyComment => '我的短评';

  @override
  String get bangumiCommentHint => '写点短评（将同步到 Bangumi）';

  @override
  String get bangumiSaved => '已保存';

  @override
  String get bangumiSyncOptions => '同步选项';

  @override
  String get bangumiPrivateCollection => '新收藏设为私有';

  @override
  String get bangumiPrivateCollectionHint => '仅影响新创建的收藏，不改动远端已有收藏';

  @override
  String get bangumiTagsSync => '收藏分组推送为标签';

  @override
  String get bangumiTagsSyncHint => '与远端标签合并，不丢失在 Bangumi 手动添加的标签';

  @override
  String get bangumiImport => '从 Bangumi 导入';

  @override
  String bangumiImportDone(int count) {
    return '导入完成：已绑定 $count 项';
  }

  @override
  String get bangumiForcedState => '同步状态覆盖';

  @override
  String get bangumiStateAuto => '自动判定';

  @override
  String get bangumiStateWish => '想看';

  @override
  String get bangumiStateDoing => '在看';

  @override
  String get bangumiStateCollect => '看过';

  @override
  String get bangumiStateOnHold => '搁置';

  @override
  String get bangumiStateDropped => '抛弃';

  @override
  String get bangumiPullFromRemote => '从 Bangumi 拉取';

  @override
  String get bangumiPullDone => '已拉取远端评分与短评';

  @override
  String get bangumiPullEmpty => '远端暂无该条目收藏';

  @override
  String get backupCategorySource => '源与订阅';

  @override
  String get backupCategoryBookmark => '收藏与书签';

  @override
  String get backupCategoryProgress => '进度与历史';

  @override
  String get backupCategorySettings => '设置与偏好';

  @override
  String get backupCategoryDownload => '下载任务';

  @override
  String get backupCategoryDanmaku => '弹幕缓存';

  @override
  String get backupCategoryOther => '其它';

  @override
  String get backupSelectScope => '选择备份内容';

  @override
  String get backupSelectAll => '全选';

  @override
  String get backupMerge => '合并（保留本地）';

  @override
  String get backupReplace => '覆盖（以备份为准）';

  @override
  String get backupMergeDesc => '把备份内容并入本地，本地已有的数据保留，同名项以备份覆盖';

  @override
  String get backupReplaceDesc => '用备份完全替换本地对应数据，此操作不可恢复';

  @override
  String get backupImportMode => '恢复方式';

  @override
  String get backupScopeNone => '请至少选择一类要备份的数据';

  @override
  String backupPreviewTitle(Object count) {
    return '即将恢复 $count 项数据';
  }

  @override
  String backupExported(Object count) {
    return '已导出备份（$count 项）';
  }

  @override
  String get pullNow => '从云端恢复';

  @override
  String get cloudSyncPullMode => '恢复方式';

  @override
  String get cloudSyncErrorNoConfig => '未配置 WebDAV，请先填写地址、账号与密码';

  @override
  String get cloudSyncErrorNoRemote => '云端没有可用的备份文件';

  @override
  String get cloudSyncErrorEncode => '打包备份失败，请重试';

  @override
  String get cloudSyncErrorNetwork => '网络错误，请检查 WebDAV 地址与网络连接';

  @override
  String cloudSyncErrorUnknown(Object detail) {
    return '同步出错：$detail';
  }

  @override
  String get cloudSyncStatusSection => '同步状态';

  @override
  String get cloudSyncStatusUpload => '上传备份';

  @override
  String get cloudSyncStatusRestore => '恢复数据';

  @override
  String get cloudSyncStatusSuccess => '成功';

  @override
  String get cloudSyncStatusFailed => '失败';

  @override
  String get cloudSyncStatusNoChanges => '无变化';

  @override
  String get cloudSyncStatusNotRun => '尚未执行';

  @override
  String cloudSyncStatusItems(Object count) {
    return '共 $count 项';
  }

  @override
  String cloudSyncNextSync(Object time) {
    return '下次自动同步：$time';
  }

  @override
  String get cloudSyncResolveConflicts => '解决冲突';

  @override
  String get cloudSyncConflictTitle => '同步冲突';

  @override
  String get cloudSyncConflictNone => '本地与云端没有冲突';

  @override
  String get cloudSyncConflictIntro => '下列分类在本地与云端版本不同，请为每个分类选择保留哪一侧：';

  @override
  String get cloudSyncConflictUseRemote => '使用云端';

  @override
  String get cloudSyncConflictKeepLocal => '保留本地';

  @override
  String get cloudSyncConflictMerge => '合并';

  @override
  String cloudSyncConflictCount(Object count) {
    return '$count 处冲突';
  }

  @override
  String get cloudSyncConflictLocal => '本地';

  @override
  String get cloudSyncConflictRemote => '云端';

  @override
  String get cloudSyncConflictApply => '应用并恢复';

  @override
  String get cloudSyncConflictLoading => '正在分析冲突…';

  @override
  String get bangumiSyncThis => '同步到 Bangumi';

  @override
  String get syncWorking => '正在同步到 Bangumi…';

  @override
  String get syncBusy => '正在同步中，请稍候';

  @override
  String get bangumiFavoriteFirst => '收藏后即可评分与短评';

  @override
  String get bangumiCollectionStatus => 'Bangumi 收藏状态';

  @override
  String get bangumiBindFirst => '请先绑定 Bangumi 条目';

  @override
  String get bangumiSiteRating => 'Bangumi 评分';

  @override
  String get bangumiSyncSettings => '同步设置';

  @override
  String get bangumiBindToViewRating => '绑定条目后查看 Bangumi 评分与评价';

  @override
  String bangumiRatingUsers(int count) {
    return '$count 人评分';
  }

  @override
  String bangumiRank(int rank) {
    return '排名 #$rank';
  }

  @override
  String get bangumiSummary => '简介';

  @override
  String get bangumiTags => '标签';

  @override
  String get bangumiNoRating => '暂无评分';

  @override
  String get bangumiLoadFailed => '加载失败';

  @override
  String get bangumiViewOnWeb => '在 Bangumi 打开';

  @override
  String get bangumiBrowseCollection => '浏览 Bangumi 收藏';

  @override
  String get bangumiCollectionEmpty => '该状态下暂无条目';

  @override
  String get bangumiSubjectTypeAnime => '动画';

  @override
  String get bangumiSubjectTypeBook => '书籍';

  @override
  String get bangumiSubjectTypeReal => '三次元';

  @override
  String get bangumiLoginWithOAuth => '使用 Bangumi 登录';

  @override
  String get bangumiOauthHint => '更安全的授权方式：在浏览器中完成 Bangumi 授权后自动返回应用。';

  @override
  String get bangumiOauthNotConfigured =>
      '尚未配置 OAuth：请在 Bangumi 开放平台创建应用并填入 Client ID / Secret。';

  @override
  String get bangumiOauthFailed => 'Bangumi 授权失败，请重试。';

  @override
  String get networkSettingsTitle => '网络设置';

  @override
  String get networkSettingsDesc => '代理、DNS、DoH/DoT、SNI、ECH 与 Hosts';

  @override
  String get networkInfoTitle => '关于网络设置';

  @override
  String get networkInfoBody =>
      '全局设置对应用内所有 HTTP 流量生效（封面、下载、同步、抓取）。原生组件（网页视图、播放器、投屏）走原生栈，不受影响。源级覆盖仅作用于该源的抓取。';

  @override
  String get networkHelpDoc => '帮助与文档';

  @override
  String get networkExperimentalNote => '实验性：受 Dart TLS 栈限制，可能无法在所有路径生效。';

  @override
  String get networkProxyTitle => '代理';

  @override
  String get networkProxyModeDirect => '直连';

  @override
  String get networkProxyModeSystem => '系统';

  @override
  String get networkProxyModeManual => '手动';

  @override
  String get networkProxyProtocolHttp => 'HTTP';

  @override
  String get networkProxyProtocolSocks5 => 'SOCKS5';

  @override
  String get networkProxyHost => '主机';

  @override
  String get networkProxyPort => '端口';

  @override
  String get networkProxyUsername => '用户名';

  @override
  String get networkProxyPassword => '密码';

  @override
  String get networkTestProxy => '测试代理';

  @override
  String networkTestSuccess(int ms) {
    return '成功（$ms 毫秒）';
  }

  @override
  String get networkTestFailed => '测试失败';

  @override
  String get networkDnsTitle => 'DNS';

  @override
  String get networkDnsModeSystem => '系统';

  @override
  String get networkDnsModeCustom => '自定义';

  @override
  String get networkDnsModeDoh => 'DoH';

  @override
  String get networkDnsModeDot => 'DoT';

  @override
  String get networkDnsServers => 'DNS 服务器';

  @override
  String get networkDnsServersEmpty => '未配置服务器';

  @override
  String get networkAddServer => '添加服务器';

  @override
  String get networkDnsCacheEnabled => '启用 DNS 缓存';

  @override
  String networkDnsCacheStatus(int count) {
    return '缓存条目：$count';
  }

  @override
  String get networkClearCache => '清理缓存';

  @override
  String get networkTestDns => '测试 DNS 解析';

  @override
  String get networkDnsTestHost => '待解析主机';

  @override
  String networkDnsTestResult(Object ips, int ms) {
    return '$ips（$ms 毫秒）';
  }

  @override
  String get networkDohTitle => 'DNS over HTTPS (DoH)';

  @override
  String get networkDohPreset => '预设';

  @override
  String get networkDohUrl => 'DoH 地址';

  @override
  String get networkTestDoh => '测试 DoH';

  @override
  String get networkDotTitle => 'DNS over TLS (DoT)';

  @override
  String get networkDotHost => 'DoT 主机';

  @override
  String get networkDotPort => 'DoT 端口';

  @override
  String get networkHostsTitle => '自定义 Hosts';

  @override
  String get networkHostsEmpty => '无 Hosts 条目';

  @override
  String get networkAddHost => '添加 Hosts 条目';

  @override
  String get networkHostsIp => 'IP 地址';

  @override
  String get networkHostsHost => '主机名';

  @override
  String get networkSniTitle => 'SNI';

  @override
  String get networkSniEnabled => '启用自定义 SNI';

  @override
  String get networkSniDefault => '默认 SNI 值';

  @override
  String get networkEchTitle => 'ECH（加密客户端问候）';

  @override
  String get networkEchEnabled => '启用 ECH';

  @override
  String get networkEchConfigList => 'ECH 配置列表（base64）';

  @override
  String get networkReset => '恢复默认网络设置';

  @override
  String get networkResetTitle => '恢复默认网络设置';

  @override
  String get networkResetConfirm => '将所有网络设置恢复为默认值？';

  @override
  String get networkResetDone => '已恢复默认网络设置';

  @override
  String get networkSaved => '网络设置已保存';

  @override
  String get networkCacheCleared => '已清理 DNS 缓存';

  @override
  String get networkErrorInvalidHost => '主机无效';

  @override
  String get networkErrorInvalidPort => '端口无效（1-65535）';

  @override
  String get networkErrorInvalidIp => 'IP 地址无效';

  @override
  String get networkErrorInvalidDomain => '域名无效';

  @override
  String get networkErrorInvalidDohUrl => 'DoH 地址无效（必须为 https）';

  @override
  String get sourceNetworkOverride => '网络覆盖';

  @override
  String get sourceNetworkScopeNote =>
      '这些设置仅作用于该源的抓取，逐方面覆盖全局网络设置；未开启的方面继承全局配置。';

  @override
  String get networkOverrideEnable => '覆盖全局';

  @override
  String get networkInheritGlobal => '继承全局';

  @override
  String get sourceNetworkSaved => '源级网络覆盖已保存';

  @override
  String get sourceNetworkClear => '清除覆盖';

  @override
  String get sourceNetworkClearConfirm => '移除该源的网络覆盖并继承全局设置？';

  @override
  String get sourceNetworkCleared => '源级网络覆盖已清除';

  @override
  String get bangumiNoMatch => '未在 Bangumi 找到匹配条目';

  @override
  String get bangumiManualBind => '手动搜索绑定';

  @override
  String get bangumiConfirmBind => '确认绑定以下条目';

  @override
  String get bangumiFromBangumi => '数据来自 Bangumi';

  @override
  String get bangumiHideCollection => '隐藏收藏';

  @override
  String get bangumiProgress => '进度（已看集/章）';

  @override
  String get bangumiSaveSync => '保存并同步';

  @override
  String get bangumiSavedLocal => '未登录：已保存到本地';

  @override
  String get websiteComments => '网站评论';

  @override
  String get bangumiComments => 'Bangumi 吐槽';

  @override
  String get bangumiCommentsEmpty => '暂无吐槽';

  @override
  String get bangumiCommentsLoadFailed => '吐槽加载失败';

  @override
  String bangumiGuessMatch(Object name) {
    return '疑似匹配：$name';
  }

  @override
  String bangumiEps(int count) {
    return '$count 话';
  }

  @override
  String bangumiAirDate(String date) {
    return '放送：$date';
  }

  @override
  String bangumiCollectionWish(int count) {
    return '$count 想看';
  }

  @override
  String bangumiCollectionDoing(int count) {
    return '$count 在看';
  }

  @override
  String bangumiCollectionCollect(int count) {
    return '$count 看过';
  }

  @override
  String get bangumiCharacters => '角色';

  @override
  String get bangumiRelated => '关联作品';

  @override
  String get bangumiCollectionStat => '收藏统计';

  @override
  String get bangumiProxyTitle => '代理 / 镜像';

  @override
  String get bangumiProxyDirect => '直连';

  @override
  String get bangumiProxyMirror => '镜像 / 反代';

  @override
  String get bangumiProxyMainSite => '主站域名';

  @override
  String get bangumiProxyApi => 'API 域名';

  @override
  String get bangumiProxyImage => '图片域名';

  @override
  String get bangumiProxyHint => '镜像 / 反代模式下填写你的自建域名（不含路径）。留空则该类别仍走官方默认域名。';

  @override
  String get bangumiProxySaved => '代理设置已保存';

  @override
  String get bangumiDetail => '详情';

  @override
  String get bangumiStaff => '制作人员';

  @override
  String get bangumiTapToExpand => '点击展开';

  @override
  String get bangumiSyncRating => '评分';

  @override
  String get bangumiSyncComment => '吐槽';

  @override
  String get bangumiSync => '同步';

  @override
  String get bangumiPublic => '公开';

  @override
  String get bangumiPrivate => '私密';

  @override
  String get bangumiSyncLoginHint => '请先在设置中登录 Bangumi';

  @override
  String get bangumiSyncSaved => '已保存';

  @override
  String get bangumiSyncWatchedEpisodes => '已看集数';

  @override
  String get bangumiSyncWatchedChapters => '已读章节';

  @override
  String get bangumiSyncProgressHint => '留空则自动同步本地进度';

  @override
  String get bangumiSyncExpandList => '选择具体集 / 章节';

  @override
  String get bangumiSyncCollapseList => '收起';

  @override
  String bangumiSyncChaptersTotal(Object count, Object unit) {
    return '共 $count $unit';
  }

  @override
  String bangumiSyncChaptersLoadedHint(Object count, Object unit) {
    return '已加载 $count $unit，可单独勾选';
  }

  @override
  String bangumiSyncNoEpisodeList(Object eps) {
    return 'Bangumi 未返回该条目的剧集列表（$eps），无法逐集勾选';
  }

  @override
  String bangumiSyncLoadEpisodesFailed(Object error) {
    return '加载剧集列表失败：$error';
  }

  @override
  String get bangumiSyncUnitEp => '集';

  @override
  String get bangumiSyncUnitVolume => '话';

  @override
  String get bangumiSyncUnitChapter => '章';

  @override
  String get bangumiSyncMyCompletion => '我的完成度';

  @override
  String get bangumiSyncUpdate => '更新';

  @override
  String get bangumiSyncAdvancedOptions => '高级选项';

  @override
  String get bangumiSyncAdvancedHint => '评分 / 吐槽 / 状态 / 公开私密';

  @override
  String get bangumiSyncChapLabel => 'Chap.';

  @override
  String get bangumiSyncVolLabel => 'Vol.';

  @override
  String get bangumiSyncIncrement => '+';

  @override
  String get bangumiSyncAnimeGridTitle => '章节';

  @override
  String get bangumiSyncAnimeGridHint => '点击格子标记已看 / 取消';

  @override
  String get bangumiSyncScheduleWeek => '周';

  @override
  String get bangumiSyncScheduleHour => '时';

  @override
  String get bangumiSyncScheduleMinute => '分';

  @override
  String get bangumiSyncScheduleTitle => '放送时间';

  @override
  String bangumiSyncPageOf(int current, int total) {
    return '$current / $total 页';
  }

  @override
  String get bangumiSyncUnknown => '??';

  @override
  String bangumiRatingValue(int count) {
    return '$count 分';
  }

  @override
  String get clear => '清除';

  @override
  String get mirrorAddCustom => '添加自定义镜像';

  @override
  String get mirrorName => '镜像名称';

  @override
  String get mirrorDomain => '域名';

  @override
  String get mirrorBaseUrl => '基址';

  @override
  String get mirrorCustom => '自定义';

  @override
  String get mirrorDelete => '删除';

  @override
  String get mirrorExtractFromPublish => '从发布页提取镜像';

  @override
  String get mirrorExtracting => '正在提取…';

  @override
  String get mirrorNoMirrorsExtracted => '未提取到可用镜像';

  @override
  String get mirrorImportSelected => '导入选中镜像';

  @override
  String get mirrorExtractFailed => '提取失败';

  @override
  String get mirrorAddInvalid => '基址必须以 http:// 或 https:// 开头';

  @override
  String get importLibraryTab => '库导入';

  @override
  String get libraryUrlHint => '输入源库订阅地址';

  @override
  String get fetchLibrary => '拉取';

  @override
  String get saveLibrary => '保存常用';

  @override
  String get libraryBookmarks => '源库';

  @override
  String get sourceNotLoggedIn => '未登录';

  @override
  String get novelThemeFollowApp => '跟随应用';

  @override
  String get novelThemeFollowDark => '始终夜间';

  @override
  String get novelThemeFollowLight => '始终日间';

  @override
  String get libraryEmpty => '暂无常用库地址';

  @override
  String get addLibraryTitle => '添加源库';

  @override
  String get libraryNameHint => '名称（可选）';

  @override
  String get subscribeLibrary => '订阅';

  @override
  String get fetchLibraryAndImport => '更新并导入';

  @override
  String get openHomepage => '打开主页';

  @override
  String get unsubscribeLibrary => '取消订阅';

  @override
  String unsubscribeLibraryConfirm(String name) {
    return '确定要取消订阅「$name」吗？';
  }

  @override
  String get viewLibrarySources => '查看源';

  @override
  String get librarySubscribeFailed => '订阅失败，请检查 URL';

  @override
  String libraryImportResult(int success, int total, int failed) {
    return '已导入 $success/$total 个源（$failed 失败）';
  }

  @override
  String get sourceTypeOther => '其他';

  @override
  String get official => '官方';

  @override
  String get loginStatusLoggedIn => '已登录';

  @override
  String get loginStatusLoggedOut => '未登录';

  @override
  String get cookieInputHint => '粘贴该源的 Cookie 字符串';

  @override
  String get incognitoMode => '无痕模式';

  @override
  String get incognitoModeHint => '开启后不记录该源的浏览历史与搜索记录';

  @override
  String get globalIncognito => '全局无痕浏览';

  @override
  String get globalIncognitoHint => '开启后所有源都不记录浏览历史与搜索记录（各源仍可单独在源管理中覆盖）';

  @override
  String get rememberPosition => '记住播放/阅读位置';

  @override
  String get rememberPositionHint => '开启后，重新打开动漫/漫画/小说会自动跳到上次观看的进度；关闭则每次从开头开始';

  @override
  String mirrorAutoAdded(Object count) {
    return '已从发布页自动添加 $count 个镜像';
  }

  @override
  String get sourceAnnouncementView => '查看详情';

  @override
  String get watchedThreshold => '已看阈值';

  @override
  String get watchedThresholdHint => '播放/阅读进度达到该百分比视为已看';

  @override
  String get watchedThresholdUnit => '%';

  @override
  String get onlineTabWebFavorite => '网络收藏';

  @override
  String get favoriteLocal => '本地收藏';

  @override
  String get favoriteLocalHint => '保存到本机';

  @override
  String get favoriteWeb => '加入网络收藏';

  @override
  String get favoriteWebHint => '收藏到源站账号（需联网）';

  @override
  String get favoriteWebRequiresLogin => '需先登录源站';

  @override
  String get ageRatingGeneral => '全年龄';

  @override
  String get ageRatingTeen => '青少年 (16+)';

  @override
  String get ageRatingMature => '成人 (18+)';

  @override
  String get ageRatingLabel => '年龄分级';

  @override
  String get ageRestrictionImportMatureBlocked =>
      '年龄限制已开启，无法导入成人（18+）源（请在设置中关闭年龄限制）';

  @override
  String ageBlockedManageHint(int count) {
    return '已隐藏 $count 个成人（18+）源（关闭年龄限制后可见）';
  }

  @override
  String ageBlockedImportHint(int count) {
    return '因年龄限制，$count 个成人（18+）源未导入';
  }

  @override
  String get ageRestriction => '年龄限制';

  @override
  String get ageRestrictionHint => '开启后隐藏成人（18+）分级的源';

  @override
  String get ageRestrictionDisclaimerTitle => '免责声明';

  @override
  String get ageRestrictionDisclaimerBody =>
      '关闭年龄限制即表示你已知晓：本应用可能会展示成人（18+）分级内容，包含明确的成人素材。你确认你已达到所在司法辖区法律规定的可观看此类内容的法定年龄，并自愿承担由此产生的全部后果。开发者不对第三方源提供的任何内容负责。请务必遵守当地法律法规。';

  @override
  String get ageRestrictionDisclaimerConfirm => '我已知晓并继续';

  @override
  String get ageRestrictionDisclaimerScrollHint => '请滚动阅读完全部免责内容后再确认';

  @override
  String ageRestrictionDisclaimerCounting(Object seconds) {
    return '还需等待 $seconds 秒';
  }

  @override
  String ageRestrictionDisclaimerWait(Object seconds) {
    return '确认（还需 $seconds 秒）';
  }

  @override
  String get comicSectionTapPage => '翻页与点击';

  @override
  String get comicSectionVisualFilter => '画面与滤镜';

  @override
  String get comicSectionProgress => '进度与显示';

  @override
  String get comicSectionFlash => '闪屏效果';

  @override
  String get comicSectionMouseWheel => '鼠标滚轮';
}
