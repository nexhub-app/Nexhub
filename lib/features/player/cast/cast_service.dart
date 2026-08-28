import 'dart:async';

import 'package:cast/cast.dart';

/// 真实 Chromecast 投屏服务（基于纯 Dart 的 cast 包，无需 Google Cast SDK）。
///
/// 流程：发现设备 -> 建立会话 -> 启动媒体接收器(CC1AD845) -> 发送 LOAD 播放视频地址。
/// 全程 try/catch 降级，避免投屏异常影响本地播放。
///
/// 扩展：投屏后持续接收 [MEDIA_STATUS] 消息解析播放位置，经 [positionStream]
/// 暴露给调用方；[sessionStateStream] 反映会话生命周期，用于断开自动暂停本地播放。
class CastService {
  CastSession? _session;
  CastDevice? _device;

 /// 上一次断开会话的 Future：dispose 期 disconnect 是 fire-and-forget，
 /// 记录下来供下一次 [connectAndPlay] 开头 await，避免快速重进时新旧会话并存。
  Future<void>? _pendingDisconnect;

 /// 接收器握手确认：收到第 2 条状态消息（接收器就绪）即 complete；
 /// 超时则由 [connectAndPlay] 判定失败并回滚。
  Completer<void>? _handshakeCompleter;

 /// ── 投屏位置同步 ──────────────────────────────────────────────
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

 /// 投屏端播放位置变化流（接收器定期上报 MEDIA_STATUS 中的 currentTime）。
  Stream<Duration> get positionStream => _positionController.stream;

 /// 媒体会话状态流（connecting / connected / closed）。
  late final Stream<CastSessionState> sessionStateStream =
      Stream<CastSessionState>.empty();

 /// 是否有错误发生（投屏断开或异常后由 [sessionStateStream] 通知）。
  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();

 /// 投屏错误事件流（投屏断开 / 异常时推送）。
  Stream<Object> get errorStream => _errorController.stream;

  StreamSubscription<Map<String, dynamic>>? _messageSub;
  StreamSubscription<CastSessionState>? _stateSub;

  bool get isCasting => _session != null;
  String? get deviceName => _device?.name;

 /// 发现局域网内的 Chromecast 设备。
  Future<List<CastDevice>> discover() => CastDiscoveryService().search();

 /// 连接设备并投屏播放指定视频地址。
 ///
 /// 修复「投屏状态乐观」：不再无条件视为成功，而是等接收器就绪
 /// （收到第 2 条状态消息）后才返回；[_handshakeTimeout] 内未就绪则自动断开
 /// 并抛异常，由调用方回滚 UI 状态并提示。
  Future<void> connectAndPlay(
    CastDevice device,
    String url, {
    String title = '',
  }) async {
  // 等待上一次断开完成，避免残留会话。
    final pending = _pendingDisconnect;
    if (pending != null) {
      _pendingDisconnect = null;
      await pending;
    }

    final CastSession session =
        await CastSessionManager().startSession(device);
    _session = session;
    _device = device;

  // 投屏握手后持续监听消息（位置同步）与会话状态（断开检测）。
    _listenSessionMessages(session, url, title);
    _listenSessionState(session);

    session.sendMessage(CastSession.kNamespaceReceiver, <String, String>{
      'type': 'LAUNCH',
      'appId': 'CC1AD845',
    });

  // 等待接收器就绪确认；超时判定连接失败，断开并抛出。
    final handshake = Completer<void>();
    _handshakeCompleter = handshake;
    try {
      await handshake.future.timeout(_handshakeTimeout);
    } on TimeoutException {
      await disconnect();
      rethrow;
    }
  }

 /// 接收器握手确认超时（秒）。超过该时长未收到就绪消息即视为连接失败。
  static const Duration _handshakeTimeout = Duration(seconds: 8);

  void _sendLoad(CastSession session, String url, String title) {
    try {
      session.sendMessage(CastSession.kNamespaceMedia, <String, dynamic>{
        'type': 'LOAD',
        'autoPlay': true,
        'currentTime': 0,
        'media': <String, dynamic>{
          'contentId': url,
          'contentType': _contentTypeForUrl(url),
          'streamType': 'BUFFERED',
          'metadata': <String, dynamic>{
            'type': 0,
            'metadataType': 0,
            'title': title,
          },
        },
      });
    } on Object {
   // 发送失败静默忽略。
    }
  }

 /// 持续监听投屏消息：握手确认 + 位置同步 + 错误上报。
 ///
 /// 消息流包含 RECEIVER_STATUS（握手）、MEDIA_STATUS（位置同步）等。
 /// 握手确认后（第 2 条 RECEIVER_STATUS）发送 LOAD 加载视频。
  int _messageCount = 0;

  void _listenSessionMessages(CastSession session, String url, String title) {
    _messageSub?.cancel();
    _messageSub = session.messageStream.listen((Map<String, dynamic> msg) {
      _messageCount++;
      final String? type = msg['type'] as String?;
      if (type == null) return;

   // 握手：接收器就绪后完成 handshake 并发送 LOAD。
      if (type == 'RECEIVER_STATUS' && _messageCount == 2) {
        _handshakeCompleter?.complete();
        Future<void>.delayed(const Duration(seconds: 2)).then((_) {
          _sendLoad(session, url, title);
        });
      }

   // 位置同步：MEDIA_STATUS 消息包含 currentTime。
      if (type == 'MEDIA_STATUS') {
        _handleMediaStatus(msg);
      }
    }, onError: (Object error) {
      _errorController.add(error);
    }, cancelOnError: false);
  }

 /// 解析 MEDIA_STATUS 消息，提取 currentTime 注入位置流。
  void _handleMediaStatus(Map<String, dynamic> msg) {
    try {
      final List<dynamic>? status = msg['status'] as List<dynamic>?;
      if (status == null || status.isEmpty) return;
      final Map<String, dynamic>? first = status[0] as Map<String, dynamic>?;
      if (first == null) return;
      final num? currentTime = first['currentTime'] as num?;
      if (currentTime != null) {
        _positionController.add(
          Duration(milliseconds: (currentTime * 1000).round()),
        );
      }
    } on Object {
   // 解析失败静默忽略（非关键路径）。
    }
  }

 /// 持续监听投屏会话状态：连接断开时注入 error 流。
  void _listenSessionState(CastSession session) {
    _stateSub?.cancel();
    _stateSub = session.stateStream.listen((CastSessionState state) {
      if (state == CastSessionState.closed) {
        _errorController.add('cast_disconnected');
      }
    });
  }

  String _contentTypeForUrl(String url) {
    final String lower = url.toLowerCase();
    if (lower.contains('.m3u8')) return 'application/vnd.apple.mpegurl';
    if (lower.contains('.mpd')) return 'application/dash+xml';
    if (lower.contains('.webm')) return 'video/webm';
    if (lower.contains('.mp3') ||
        lower.contains('.m4a') ||
        lower.contains('.aac')) {
      return 'audio/mp4';
    }
    return 'video/mp4';
  }

 /// 断开投屏。
 ///
 /// 用 dynamic 调用 endSession 以兼容不同版本（方法名可能不同），
 /// 失败时静默忽略，不影响本地播放。断开 Future 记入 [_pendingDisconnect]，
 /// 供下一次 [connectAndPlay] await。同时取消 的持续订阅。
  Future<void> disconnect() async {
    _messageSub?.cancel();
    _messageSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _messageCount = 0;
    final CastSession? session = _session;
    _session = null;
    _device = null;
    _handshakeCompleter = null;
    if (session == null) return;
    final Future<void> pending = () async {
      try {
        await (session as dynamic).endSession();
      } on Object {
    // 某些版本无 endSession，忽略。
      }
    }();
    _pendingDisconnect = pending;
    await pending;
  }
}
