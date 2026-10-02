import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const DebloatApp());

/// ---------------------------------------------------------------------------
/// App shell + Material 3 theme
/// ---------------------------------------------------------------------------
class DebloatApp extends StatelessWidget {
  const DebloatApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4F6BED);
    return MaterialApp(
      title: 'Debloat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const DebloatHomePage(),
    );
  }
}

/// ---------------------------------------------------------------------------
/// Native bridge
/// ---------------------------------------------------------------------------
class AdbService {
  static const MethodChannel _channel = MethodChannel('com.example.debloat/adb');
  static const EventChannel _events = EventChannel(
    'com.example.debloat/adb_events',
  );

  /// Stream of native events, e.g. {'event': 'connected'} from the floating window.
  Stream<dynamic> get events => _events.receiveBroadcastStream();

  Future<bool> pair(int port, String code) async =>
      await _channel.invokeMethod<bool>('pair', {'port': port, 'code': code}) ??
      false;

  Future<bool> connect(int port) async =>
      await _channel.invokeMethod<bool>('connect', {'port': port}) ?? false;

  /// Pair must have happened first; discovers the connection port via mDNS.
  Future<bool> connectAuto() async =>
      await _channel.invokeMethod<bool>('connectAuto') ?? false;

  /// Whether the user has paired/connected on this device before.
  Future<bool> isPaired() async =>
      await _channel.invokeMethod<bool>('isPaired') ?? false;

  // ---- floating overlay + settings deep links ----------------------------

  Future<bool> hasOverlayPermission() async =>
      await _channel.invokeMethod<bool>('hasOverlayPermission') ?? false;

  Future<void> requestOverlayPermission() async =>
      _channel.invokeMethod<void>('requestOverlayPermission');

  Future<void> openDeveloperOptions() async =>
      _channel.invokeMethod<void>('openDeveloperOptions');

  Future<void> showFloatingWindow() async =>
      _channel.invokeMethod<void>('showFloatingWindow');

  Future<void> hideFloatingWindow() async =>
      _channel.invokeMethod<void>('hideFloatingWindow');

  Future<bool> isConnected() async =>
      await _channel.invokeMethod<bool>('isConnected') ?? false;

  Future<void> disconnect() async => _channel.invokeMethod<void>('disconnect');

  Future<List<AppInfo>> getSystemApps() async {
    final raw =
        await _channel.invokeMethod<List<dynamic>>('getSystemApps') ??
        const <dynamic>[];
    return raw
        .map((e) => AppInfo.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Returns adbd's reply, e.g. "Success" or "Failure [reason]".
  Future<String> uninstall(String packageName) async =>
      await _channel.invokeMethod<String>('uninstallApp', {
        'packageName': packageName,
      }) ??
      '';
}

class AppInfo {
  const AppInfo({
    required this.packageName,
    required this.appName,
    required this.enabled,
  });

  final String packageName;
  final String appName;
  final bool enabled;

  factory AppInfo.fromMap(Map<String, dynamic> map) => AppInfo(
    packageName: map['packageName'] as String,
    appName: (map['appName'] as String?) ?? map['packageName'] as String,
    enabled: (map['enabled'] as bool?) ?? true,
  );
}

/// ---------------------------------------------------------------------------
/// Connection state
/// ---------------------------------------------------------------------------
enum ConnStatus { disconnected, pairing, connecting, connected, error }

extension on ConnStatus {
  String get label => switch (this) {
    ConnStatus.disconnected => 'Disconnected',
    ConnStatus.pairing => 'Pairing…',
    ConnStatus.connecting => 'Connecting…',
    ConnStatus.connected => 'Connected',
    ConnStatus.error => 'Error',
  };

  IconData get icon => switch (this) {
    ConnStatus.disconnected => Icons.link_off_rounded,
    ConnStatus.pairing => Icons.sync_rounded,
    ConnStatus.connecting => Icons.sync_rounded,
    ConnStatus.connected => Icons.check_circle_rounded,
    ConnStatus.error => Icons.error_rounded,
  };

  bool get busy => this == ConnStatus.pairing || this == ConnStatus.connecting;
}

/// ---------------------------------------------------------------------------
/// Home page
/// ---------------------------------------------------------------------------
class DebloatHomePage extends StatefulWidget {
  const DebloatHomePage({super.key});

  @override
  State<DebloatHomePage> createState() => _DebloatHomePageState();
}

class _DebloatHomePageState extends State<DebloatHomePage> {
  final AdbService _adb = AdbService();

  final TextEditingController _pairPortCtrl = TextEditingController();
  final TextEditingController _pairCodeCtrl = TextEditingController();
  final TextEditingController _connPortCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();

  ConnStatus _status = ConnStatus.disconnected;
  bool _loadingApps = false;

  List<AppInfo> _allApps = <AppInfo>[];
  List<AppInfo> _filtered = <AppInfo>[];
  final Set<String> _busy = <String>{}; // package names currently uninstalling

  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  StreamSubscription<dynamic>? _eventSub;

  // Returning-user state: once paired we show a compact Connect / Pair again UI.
  bool _hasPaired = false;
  bool _showPairingControls = false;

  bool get _connected => _status == ConnStatus.connected;

  /// Whether the full pairing controls (pairing fields + Float) should be visible.
  bool get _showPairing => _showPairingControls || !_hasPaired;

  @override
  void initState() {
    super.initState();
    // The floating window connects outside the app; react when it reports success.
    _eventSub = _adb.events.listen(_onNativeEvent, onError: (_) {});
    _loadPairedState();
  }

  Future<void> _loadPairedState() async {
    try {
      final paired = await _adb.isPaired();
      if (mounted) setState(() => _hasPaired = paired);
    } catch (_) {
      // Default to first-run (full pairing) UI if the flag can't be read.
    }
  }

  void _markPairedUi() {
    _hasPaired = true;
    _showPairingControls = false;
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _pairPortCtrl.dispose();
    _pairCodeCtrl.dispose();
    _connPortCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onNativeEvent(dynamic event) {
    if (event is Map && event['event'] == 'connected') {
      if (_status == ConnStatus.connected) return;
      setState(() {
        _status = ConnStatus.connected;
        _markPairedUi();
      });
      _loadApps();
    }
  }

  // ---- actions ------------------------------------------------------------

  Future<void> _handleConnect() async {
    final pairPort = int.tryParse(_pairPortCtrl.text.trim());
    final pairCode = _pairCodeCtrl.text.trim();
    final connPort = int.tryParse(_connPortCtrl.text.trim());

    FocusScope.of(context).unfocus();
    try {
      // Pairing is only needed once per device; skip it if the fields are blank.
      if (pairPort != null && pairCode.isNotEmpty) {
        setState(() => _status = ConnStatus.pairing);
        final paired = await _adb.pair(pairPort, pairCode);
        if (!paired) {
          setState(() => _status = ConnStatus.error);
          _snack('Pairing failed. Double-check the pairing port and code.');
          return;
        }
      }

      setState(() => _status = ConnStatus.connecting);
      // With a connection port, connect directly; otherwise auto-discover via mDNS.
      final connected = connPort != null
          ? await _adb.connect(connPort)
          : await _adb.connectAuto();
      if (!connected) {
        setState(() => _status = ConnStatus.error);
        _snack(
          connPort != null
              ? 'Connection failed. Check the connection port.'
              : 'Auto-connect failed. Enter the connection port, or pair first.',
        );
        return;
      }

      setState(() {
        _status = ConnStatus.connected;
        _markPairedUi();
      });
      await _loadApps();
    } on PlatformException catch (e) {
      setState(() => _status = ConnStatus.error);
      _snack(e.message ?? 'ADB error');
    }
  }

  void _pairAgain() => setState(() => _showPairingControls = true);

  void _backToConnect() => setState(() => _showPairingControls = false);

  /// Opens the floating pairing window over Settings, then jumps to Developer options.
  Future<void> _handleFloat() async {
    try {
      final granted = await _adb.hasOverlayPermission();
      if (!granted) {
        await _adb.requestOverlayPermission();
        _snack('Enable "Display over other apps", then tap Float again.');
        return;
      }
      await _adb.showFloatingWindow();
      await _adb.openDeveloperOptions();
    } on PlatformException catch (e) {
      _snack(e.message ?? 'Could not open the floating window');
    }
  }

  Future<void> _disconnect() async {
    try {
      await _adb.disconnect();
    } catch (_) {
      // Best effort.
    }
    setState(() {
      _status = ConnStatus.disconnected;
      _allApps = <AppInfo>[];
      _filtered = <AppInfo>[];
      _busy.clear();
      _searchCtrl.clear();
      _listKey = GlobalKey<AnimatedListState>();
    });
  }

  Future<void> _loadApps() async {
    setState(() => _loadingApps = true);
    try {
      final apps = await _adb.getSystemApps();
      setState(() {
        _allApps = apps;
        _applyFilter();
        _loadingApps = false;
      });
    } on PlatformException catch (e) {
      setState(() => _loadingApps = false);
      _snack(e.message ?? 'Failed to load apps');
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    _filtered = q.isEmpty
        ? List<AppInfo>.of(_allApps)
        : _allApps
              .where(
                (a) =>
                    a.appName.toLowerCase().contains(q) ||
                    a.packageName.toLowerCase().contains(q),
              )
              .toList();
    // Reset the AnimatedList so its internal count matches the new filter.
    _listKey = GlobalKey<AnimatedListState>();
  }

  Future<void> _uninstall(AppInfo app) async {
    setState(() => _busy.add(app.packageName));
    try {
      final result = await _adb.uninstall(app.packageName);
      if (result.contains('Success')) {
        final index = _filtered.indexOf(app);
        if (index >= 0) {
          final removed = _filtered.removeAt(index);
          _listKey.currentState?.removeItem(
            index,
            (context, animation) => _buildRemovedTile(removed, animation),
            duration: const Duration(milliseconds: 420),
          );
        }
        _allApps.remove(app);
        _snack('Uninstalled ${app.appName}');
      } else {
        _snack('Could not uninstall ${app.appName}: $result');
      }
    } on PlatformException catch (e) {
      _snack(e.message ?? 'Uninstall failed');
    } finally {
      if (mounted) setState(() => _busy.remove(app.packageName));
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debloat'),
        actions: [
          if (_connected) ...[
            IconButton(
              tooltip: 'Reload apps',
              onPressed: _loadingApps ? null : _loadApps,
              icon: const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: 'Disconnect',
              onPressed: _disconnect,
              icon: const Icon(Icons.logout_rounded),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          _ConnectionPanel(
            pairPortCtrl: _pairPortCtrl,
            pairCodeCtrl: _pairCodeCtrl,
            connPortCtrl: _connPortCtrl,
            status: _status,
            connected: _connected,
            hasPaired: _hasPaired,
            showPairing: _showPairing,
            onConnect: _status.busy ? null : _handleConnect,
            onDisconnect: _disconnect,
            onFloat: _status.busy ? null : _handleFloat,
            onPairAgain: _pairAgain,
            onBackToConnect: _backToConnect,
          ),
          if (_connected) _searchBar(),
          Expanded(child: _appsArea()),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(_applyFilter),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'Filter apps',
                border: const OutlineInputBorder(),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() {
                          _searchCtrl.clear();
                          _applyFilter();
                        }),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${_filtered.length}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ],
      ),
    );
  }

  Widget _appsArea() {
    if (!_connected) {
      return const _EmptyHint(
        icon: Icons.wifi_tethering_rounded,
        title: 'Not connected',
        message:
            'Enable Wireless debugging in Developer options, then pair and '
            'connect above to list system apps.',
      );
    }
    if (_loadingApps) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_filtered.isEmpty) {
      return const _EmptyHint(
        icon: Icons.inbox_rounded,
        title: 'No apps',
        message: 'Nothing matches the current filter.',
      );
    }
    return AnimatedList(
      key: _listKey,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      initialItemCount: _filtered.length,
      itemBuilder: (context, index, animation) {
        final app = _filtered[index];
        return _buildAddedTile(app, animation);
      },
    );
  }

  // Insertion / steady-state animation (grow + fade in).
  Widget _buildAddedTile(AppInfo app, Animation<double> animation) {
    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: FadeTransition(
        opacity: animation,
        child: _AppTile(
          app: app,
          busy: _busy.contains(app.packageName),
          onUninstall: () => _uninstall(app),
        ),
      ),
    );
  }

  // Removal animation (shrink + fade out).
  Widget _buildRemovedTile(AppInfo app, Animation<double> animation) {
    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
      child: FadeTransition(
        opacity: animation,
        child: _AppTile(app: app, busy: false, onUninstall: null),
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// Connection panel
/// ---------------------------------------------------------------------------
class _ConnectionPanel extends StatelessWidget {
  const _ConnectionPanel({
    required this.pairPortCtrl,
    required this.pairCodeCtrl,
    required this.connPortCtrl,
    required this.status,
    required this.connected,
    required this.hasPaired,
    required this.showPairing,
    required this.onConnect,
    required this.onDisconnect,
    required this.onFloat,
    required this.onPairAgain,
    required this.onBackToConnect,
  });

  final TextEditingController pairPortCtrl;
  final TextEditingController pairCodeCtrl;
  final TextEditingController connPortCtrl;
  final ConnStatus status;
  final bool connected;
  final bool hasPaired;
  final bool showPairing;
  final VoidCallback? onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback? onFloat;
  final VoidCallback onPairAgain;
  final VoidCallback onBackToConnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _StatusBanner(status: status)),
                if (hasPaired) ...[
                  const SizedBox(width: 8),
                  const _PairedChip(),
                ],
              ],
            ),
            // Pairing fields appear on first run, or when "Pair again" is tapped.
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: showPairing
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _PortField(
                                controller: pairPortCtrl,
                                label: 'Pairing port',
                                enabled: !connected,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: pairCodeCtrl,
                                enabled: !connected,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Pairing code',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
            const SizedBox(height: 12),
            _PortField(
              controller: connPortCtrl,
              label: 'Connection port (optional)',
              enabled: !connected,
            ),
            const SizedBox(height: 6),
            Text(
              'Leave the connection port blank to auto-detect it after pairing.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: connected ? onDisconnect : onConnect,
              icon: status.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      connected
                          ? Icons.logout_rounded
                          : showPairing
                          ? Icons.bolt_rounded
                          : Icons.link_rounded,
                    ),
              label: Text(
                connected
                    ? 'Disconnect'
                    : status.busy
                    ? status.label
                    : showPairing
                    ? 'Pair & Connect'
                    : 'Connect',
              ),
            ),
            if (!connected) ...[
              const SizedBox(height: 8),
              if (showPairing) ...[
                OutlinedButton.icon(
                  onPressed: status.busy ? null : onFloat,
                  icon: const Icon(Icons.picture_in_picture_alt_rounded),
                  label: const Text('Float over Settings to pair'),
                ),
                // Offer a way back to the compact Connect view if already paired.
                if (hasPaired)
                  TextButton(
                    onPressed: status.busy ? null : onBackToConnect,
                    child: const Text('Back to Connect'),
                  ),
              ] else
                OutlinedButton.icon(
                  onPressed: status.busy ? null : onPairAgain,
                  icon: const Icon(Icons.qr_code_2_rounded),
                  label: const Text('Pair again'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PairedChip extends StatelessWidget {
  const _PairedChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_rounded, size: 16, color: scheme.onPrimaryContainer),
          const SizedBox(width: 4),
          Text(
            'Paired',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PortField extends StatelessWidget {
  const _PortField({
    required this.controller,
    required this.label,
    required this.enabled,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status});

  final ConnStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (status) {
      ConnStatus.connected => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      ConnStatus.error => (scheme.errorContainer, scheme.onErrorContainer),
      ConnStatus.pairing || ConnStatus.connecting => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      ConnStatus.disconnected => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _SpinningIcon(icon: status.icon, color: fg, spinning: status.busy),
          const SizedBox(width: 12),
          Text(
            status.label,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Continuously rotates while [spinning]; otherwise sits still.
class _SpinningIcon extends StatefulWidget {
  const _SpinningIcon({
    required this.icon,
    required this.color,
    required this.spinning,
  });

  final IconData icon;
  final Color color;
  final bool spinning;

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _SpinningIcon old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.spinning && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(widget.icon, color: widget.color),
    );
  }
}

/// ---------------------------------------------------------------------------
/// App list tile
/// ---------------------------------------------------------------------------
class _AppTile extends StatelessWidget {
  const _AppTile({
    required this.app,
    required this.busy,
    required this.onUninstall,
  });

  final AppInfo app;
  final bool busy;
  final VoidCallback? onUninstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = app.appName.isEmpty
        ? '?'
        : app.appName.characters.first.toUpperCase();

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          foregroundColor: scheme.onSecondaryContainer,
          child: Text(initial),
        ),
        title: Text(app.appName, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          app.packageName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton.icon(
                onPressed: onUninstall,
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Uninstall'),
              ),
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// Empty / hint state
/// ---------------------------------------------------------------------------
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Scroll + min-height keeps the hint centered when there is room and
    // overflow-free when the body is short (small screens / large panels).
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 56, color: scheme.outline),
                    const SizedBox(height: 16),
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
