import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../garage/services/tracking_diagnostics.dart';
import '../../settings/controllers/settings_controller.dart';

/// Identifies which subsystem owns a subscription to [LocationService.getPositionStream].
enum LocationStreamOwner {
  /// Ride distance and fuel tracker (`FuelTrackerService`).
  tracker('tracker'),

  /// Map route preview and turn-by-turn guidance (`NavigationController`).
  navigation('navigation'),

  /// Neighborhood/place labeler and GPS status pill (`CurrentPlaceController` / `GpsLivePill`).
  place('place');

  const LocationStreamOwner(this.label);

  /// Short diagnostic label written to `[STREAM]` and fix events.
  final String label;
}

/// Normalized snapshot of GPS position, heading, speed and accuracy.
class PositionData {
  const PositionData({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.heading,
    this.speed,
    this.accuracy,
    this.altitude,
  });

  final double latitude;
  final double longitude;

  /// Heading/bearing in degrees (0..360, where 0 is true north).
  final double? heading;

  /// Speed over ground in meters per second (m/s).
  final double? speed;

  /// Estimated horizontal accuracy in meters.
  final double? accuracy;

  /// Altitude in meters above mean sea level.
  final double? altitude;

  final DateTime timestamp;

  LatLng toLatLng() => LatLng(latitude, longitude);

  @override
  String toString() =>
      'PositionData(lat: $latitude, lon: $longitude, heading: $heading, speed: $speed m/s, accuracy: $accuracy m)';
}

/// Abstract interface for device location access and GPS telemetry streaming.
abstract class LocationService {
  Future<bool> isLocationServiceEnabled();
  Future<bool> checkPermission();
  Future<bool> requestPermission();
  Future<PositionData?> getCurrentPosition();
  Future<PositionData?> getLastKnownPosition();
  Stream<PositionData> getPositionStream({
    bool highAccuracy = false,
    bool enableForegroundNotification = false,
    bool? forceLocationManager,
    LocationStreamOwner owner = LocationStreamOwner.place,
  });
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
}

/// Callback invoked whenever a location stream or native upstream stream
/// transitions (`created`, `restarted`, `stopped`, `first_fix`, `watchdog`,
/// `error`, or `done`).
typedef StreamLifecycleLogger = void Function({
  required String action,
  required String owner,
  required String mode,
  required String settingsSummary,
});

/// Internal representation of an active subscriber lease on [PositionStreamCoordinator].
class _StreamLease {
  _StreamLease({
    required this.id,
    required this.owner,
    required this.highAccuracy,
    required this.enableForegroundNotification,
    required this.forceLocationManager,
    required this.requestedSettings,
    required this.controller,
  });

  final int id;
  final LocationStreamOwner owner;
  final bool highAccuracy;
  final bool enableForegroundNotification;
  final bool forceLocationManager;
  final LocationSettings requestedSettings;
  final StreamController<PositionData> controller;
}

/// Coordinates multiple Dart position stream consumers over a single native
/// `Geolocator.getPositionStream` upstream subscription.
///
/// WHY: `geolocator_android` caches one singleton `_positionStream` broadcast
/// stream per Flutter engine and only tears down the native `EventChannel`
/// (`onCancel`) when every Dart listener cancels. Without this coordinator,
/// an early `light`-mode listener (`CurrentPlaceController` at boot) locks the
/// native stream into `medium` accuracy / `10 m` distance filter / `5000 ms`
/// default interval and silently ignores later `tracking`-mode requests from
/// `FuelTrackerService` or active `NavigationController`.
class PositionStreamCoordinator {
  /// Creates a coordinator backed by custom [openUpstream], optional
  /// [seedLightPosition], and [logStreamEvent] callbacks.
  PositionStreamCoordinator({
    required this.openUpstream,
    this.seedLightPosition,
    this.logStreamEvent,
    this.watchdogTimeout = defaultWatchdogTimeout,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Default watchdog timeout (15 seconds) before logging a no-fix warning
  /// and triggering recovery in `tracking` mode.
  static const Duration defaultWatchdogTimeout = Duration(seconds: 15);

  final Stream<PositionData> Function(LocationSettings settings) openUpstream;
  final Future<PositionData?> Function()? seedLightPosition;
  final StreamLifecycleLogger? logStreamEvent;
  final Duration watchdogTimeout;
  final DateTime Function() _now;

  int _nextLeaseId = 1;
  final Map<int, _StreamLease> _leases = <int, _StreamLease>{};
  final Map<LocationStreamOwner, int> _ownerCountsBeforeBatch =
      <LocationStreamOwner, int>{};
  final Map<LocationStreamOwner, _StreamLease> _lastRemovedLeaseByOwner =
      <LocationStreamOwner, _StreamLease>{};
  final Map<LocationStreamOwner, _StreamLease> _lastAddedLeaseByOwner =
      <LocationStreamOwner, _StreamLease>{};
  final Set<LocationStreamOwner> _touchedOwnersInBatch =
      <LocationStreamOwner>{};

  StreamSubscription<PositionData>? _upstreamSub;
  LocationSettings? _activeSettings;
  bool? _activeHighAccuracy;
  bool _hasReceivedUpstreamFixInSession = false;
  DateTime? _upstreamStartedAt;
  Timer? _watchdogTimer;
  int _trackingWatchdogAttempt = 0;
  bool _forceDisableFgNotifInSession = false;
  bool _forceUpstreamRestart = false;
  bool _hasNoLocationUpdates = false;
  final Set<VoidCallback> _statusListeners = <VoidCallback>{};
  int _upstreamSessionToken = 0;

  Future<void>? _reconcileFuture;
  bool _needsAnotherReconcile = false;

  /// True when an active `tracking`-mode stream has produced zero location
  /// fixes after the initial 15 s watchdog window and the subsequent 15 s
  /// retry without foreground notification.
  bool get hasNoLocationUpdates => _hasNoLocationUpdates;

  /// Registers a callback invoked whenever [hasNoLocationUpdates] changes.
  void addStatusListener(VoidCallback listener) {
    _statusListeners.add(listener);
  }

  /// Removes a previously registered [listener].
  void removeStatusListener(VoidCallback listener) {
    _statusListeners.remove(listener);
  }

  void _setHasNoLocationUpdates(bool value) {
    if (_hasNoLocationUpdates == value) return;
    _hasNoLocationUpdates = value;
    for (final listener in List<VoidCallback>.of(_statusListeners)) {
      listener();
    }
  }

  /// Active upstream mode label (`"tracking"`, `"light"`, or `"idle"`).
  String get activeModeLabel {
    if (_activeHighAccuracy == true) return 'tracking';
    if (_activeHighAccuracy == false) return 'light';
    return 'idle';
  }

  /// Active upstream settings currently held on the plugin, or `null` when stopped.
  LocationSettings? get activeSettings => _activeSettings;

  /// Number of currently active consumer leases across all owners.
  int get activeLeaseCount => _leases.length;

  /// Tag recorded on `[ACCEPTED]`/`[REJECTED]` fix lines identifying both the
  /// consuming owner and the active upstream stream mode (e.g. `"tracker:tracking"`).
  String streamSourceTagFor(LocationStreamOwner owner) {
    final mode = _activeHighAccuracy == null
        ? (_leases.values
                .where((l) => l.owner == owner)
                .any((l) => l.highAccuracy)
            ? 'tracking'
            : 'light')
        : activeModeLabel;
    return '${owner.label}:$mode';
  }

  /// Registers a managed consumer stream for [owner].
  ///
  /// The returned stream registers its lease on listen, upgrades the shared
  /// upstream native stream whenever any consumer needs `tracking` mode or
  /// a foreground notification, and downgrades or stops upstream once cancelled.
  Stream<PositionData> subscribe({
    required LocationStreamOwner owner,
    required bool highAccuracy,
    required bool enableForegroundNotification,
    bool? forceLocationManager,
  }) {
    final requestedSettings = GeolocatorLocationService.buildLocationSettings(
      highAccuracy: highAccuracy,
      enableForegroundNotification: enableForegroundNotification,
      forceLocationManager: forceLocationManager,
    );
    final bool useGpsOnly = forceLocationManager ??
        SettingsController.instance.gpsOnlyLocationProvider;
    final int leaseId = _nextLeaseId++;

    late final StreamController<PositionData> controller;
    controller = StreamController<PositionData>.broadcast(
      onListen: () {
        _snapshotOwnerBeforeBatch(owner);
        final lease = _StreamLease(
          id: leaseId,
          owner: owner,
          highAccuracy: highAccuracy,
          enableForegroundNotification: enableForegroundNotification,
          forceLocationManager: useGpsOnly,
          requestedSettings: requestedSettings,
          controller: controller,
        );
        _leases[leaseId] = lease;
        _lastAddedLeaseByOwner[owner] = lease;
        _scheduleReconcile();
      },
      onCancel: () {
        _snapshotOwnerBeforeBatch(owner);
        final removed = _leases.remove(leaseId);
        if (removed != null) {
          _lastRemovedLeaseByOwner[owner] = removed;
        }
        _scheduleReconcile();
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      },
    );
    return controller.stream;
  }

  void _snapshotOwnerBeforeBatch(LocationStreamOwner owner) {
    if (_touchedOwnersInBatch.add(owner)) {
      _ownerCountsBeforeBatch[owner] =
          _leases.values.where((l) => l.owner == owner).length;
    }
  }

  void _scheduleReconcile() {
    _needsAnotherReconcile = true;
    if (_reconcileFuture != null) return;
    _reconcileFuture = Future.microtask(() async {
      try {
        while (_needsAnotherReconcile) {
          _needsAnotherReconcile = false;
          _flushOwnerStreamLogs();
          await _reconcileUpstreamStep();
        }
      } finally {
        _reconcileFuture = null;
        if (_needsAnotherReconcile) {
          _scheduleReconcile();
        }
      }
    });
  }

  void _flushOwnerStreamLogs() {
    if (_touchedOwnersInBatch.isEmpty) return;
    final touched = List<LocationStreamOwner>.of(_touchedOwnersInBatch);
    _touchedOwnersInBatch.clear();

    for (final owner in touched) {
      final beforeCount = _ownerCountsBeforeBatch.remove(owner) ?? 0;
      final addedLease = _lastAddedLeaseByOwner.remove(owner);
      final removedLease = _lastRemovedLeaseByOwner.remove(owner);
      final currentOwnerLeases =
          _leases.values.where((l) => l.owner == owner).toList();

      if (beforeCount == 0 && currentOwnerLeases.isNotEmpty) {
        final lease = addedLease ?? currentOwnerLeases.last;
        _emitLog(
          action: 'created',
          owner: owner.label,
          mode: lease.highAccuracy ? 'tracking' : 'light',
          settings: lease.requestedSettings,
        );
      } else if (beforeCount > 0 && currentOwnerLeases.isEmpty) {
        if (removedLease != null) {
          _emitLog(
            action: 'stopped',
            owner: owner.label,
            mode: removedLease.highAccuracy ? 'tracking' : 'light',
            settings: removedLease.requestedSettings,
          );
        }
      } else if (addedLease != null &&
          (removedLease != null || beforeCount > 0)) {
        _emitLog(
          action: 'restarted',
          owner: owner.label,
          mode: addedLease.highAccuracy ? 'tracking' : 'light',
          settings: addedLease.requestedSettings,
        );
      }
    }
  }

  Future<void> _reconcileUpstreamStep() async {
    if (_leases.isEmpty) {
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      _upstreamStartedAt = null;
      _trackingWatchdogAttempt = 0;
      _forceDisableFgNotifInSession = false;
      _forceUpstreamRestart = false;
      _setHasNoLocationUpdates(false);
      if (_upstreamSub != null) {
        final prevSettings = _activeSettings;
        final prevMode = _activeHighAccuracy == true ? 'tracking' : 'light';
        unawaited(_upstreamSub!.cancel());
        _upstreamSub = null;
        _activeSettings = null;
        _activeHighAccuracy = null;
        _upstreamSessionToken++;
        if (prevSettings != null) {
          _emitLog(
            action: 'stopped',
            owner: 'native',
            mode: prevMode,
            settings: prevSettings,
          );
        }
      }
      return;
    }

    // Tracking priority: any highAccuracy consumer promotes the shared stream to 1 s
    // bestForNavigation; foreground notification stays enabled whenever any active
    // consumer requests it (unless the 15 s watchdog disabled fgNotif for recovery).
    final bool effectiveHighAccuracy =
        _leases.values.any((l) => l.highAccuracy);
    if (!effectiveHighAccuracy) {
      _trackingWatchdogAttempt = 0;
      _forceDisableFgNotifInSession = false;
      _setHasNoLocationUpdates(false);
    }
    final bool effectiveFgNotif = !_forceDisableFgNotifInSession &&
        _leases.values.any((l) => l.enableForegroundNotification);
    final bool effectiveForceLocMgr = effectiveHighAccuracy
        ? _leases.values
            .where((l) => l.highAccuracy)
            .any((l) => l.forceLocationManager)
        : _leases.values.any((l) => l.forceLocationManager);

    final effectiveSettings = GeolocatorLocationService.buildLocationSettings(
      highAccuracy: effectiveHighAccuracy,
      enableForegroundNotification: effectiveFgNotif,
      forceLocationManager: effectiveForceLocMgr,
    );

    final bool forceRestart = _forceUpstreamRestart;
    _forceUpstreamRestart = false;

    if (!forceRestart &&
        _upstreamSub != null &&
        _sameLocationSettings(_activeSettings, effectiveSettings)) {
      return;
    }

    final bool wasActive = _upstreamSub != null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    if (_upstreamSub != null) {
      unawaited(_upstreamSub!.cancel());
      _upstreamSub = null;
    }
    if (_leases.isEmpty) {
      _activeSettings = null;
      _activeHighAccuracy = null;
      _upstreamStartedAt = null;
      _trackingWatchdogAttempt = 0;
      _forceDisableFgNotifInSession = false;
      _setHasNoLocationUpdates(false);
      return;
    }

    final int sessionToken = ++_upstreamSessionToken;
    final String mode = effectiveHighAccuracy ? 'tracking' : 'light';
    _activeSettings = effectiveSettings;
    _activeHighAccuracy = effectiveHighAccuracy;
    _hasReceivedUpstreamFixInSession = false;
    _upstreamStartedAt = _now();

    _emitLog(
      action: wasActive ? 'restarted' : 'created',
      owner: 'native',
      mode: mode,
      settings: effectiveSettings,
    );

    final upstreamStream = openUpstream(effectiveSettings);
    _upstreamSub = upstreamStream.listen(
      (pos) {
        if (sessionToken != _upstreamSessionToken) return;
        if (!_hasReceivedUpstreamFixInSession) {
          _hasReceivedUpstreamFixInSession = true;
          _watchdogTimer?.cancel();
          _watchdogTimer = null;
          _trackingWatchdogAttempt = 0;
          _forceDisableFgNotifInSession = false;
          _setHasNoLocationUpdates(false);
          final int rawDelayMs = _upstreamStartedAt != null
              ? _now().difference(_upstreamStartedAt!).inMilliseconds
              : 0;
          final int delayMs = rawDelayMs < 0 ? 0 : rawDelayMs;
          _emitLog(
            action: 'first_fix',
            owner: 'native',
            mode: mode,
            settings: effectiveSettings,
            detail: 'delay=${delayMs}ms',
          );
        } else if (_hasNoLocationUpdates) {
          _setHasNoLocationUpdates(false);
        }
        _dispatchPosition(pos);
      },
      onError: (Object err, StackTrace st) {
        if (sessionToken != _upstreamSessionToken) return;
        _emitLog(
          action: 'error',
          owner: 'native',
          mode: mode,
          settings: effectiveSettings,
          detail: 'error=$err',
        );
        for (final lease in List<_StreamLease>.of(_leases.values)) {
          if (!lease.controller.isClosed) {
            lease.controller.addError(err, st);
          }
        }
      },
      onDone: () {
        if (sessionToken != _upstreamSessionToken) return;
        _emitLog(
          action: 'done',
          owner: 'native',
          mode: mode,
          settings: effectiveSettings,
          detail: 'message=stream closed',
        );
      },
    );

    _watchdogTimer = Timer(
      watchdogTimeout,
      () => _handleWatchdogTimeout(
        sessionToken: sessionToken,
        effectiveHighAccuracy: effectiveHighAccuracy,
        effectiveSettings: effectiveSettings,
      ),
    );

    // Light mode uses a 10 m distanceFilter, so Android may not emit an initial fix
    // while stationary. Seed once in the background if nothing arrives first.
    if (!effectiveHighAccuracy && seedLightPosition != null) {
      unawaited(_seedLightStreamIfStillEmpty(sessionToken));
    }
  }

  void _handleWatchdogTimeout({
    required int sessionToken,
    required bool effectiveHighAccuracy,
    required LocationSettings effectiveSettings,
  }) {
    if (sessionToken != _upstreamSessionToken) return;
    if (_hasReceivedUpstreamFixInSession) return;
    if (_leases.isEmpty) return;

    final String mode = effectiveHighAccuracy ? 'tracking' : 'light';
    final int timeoutSec = watchdogTimeout.inSeconds;

    if (effectiveHighAccuracy) {
      if (_trackingWatchdogAttempt == 0) {
        _trackingWatchdogAttempt = 1;
        _forceDisableFgNotifInSession = true;
        _forceUpstreamRestart = true;
        _emitLog(
          action: 'watchdog',
          owner: 'native',
          mode: mode,
          settings: effectiveSettings,
          detail:
              'no fix within ${timeoutSec}s (restarting with fgNotif=false)',
        );
        _scheduleReconcile();
      } else {
        _trackingWatchdogAttempt = 2;
        _emitLog(
          action: 'watchdog',
          owner: 'native',
          mode: mode,
          settings: effectiveSettings,
          detail:
              'no fix within ${timeoutSec}s (no location updates after retry)',
        );
        _setHasNoLocationUpdates(true);
      }
    } else {
      _emitLog(
        action: 'watchdog',
        owner: 'native',
        mode: mode,
        settings: effectiveSettings,
        detail: 'no fix within ${timeoutSec}s',
      );
    }
  }

  Future<void> _seedLightStreamIfStillEmpty(int sessionToken) async {
    try {
      final seeded = await seedLightPosition!();
      if (seeded == null) return;
      if (sessionToken != _upstreamSessionToken) return;
      if (_hasReceivedUpstreamFixInSession) return;
      if (_leases.isEmpty) return;
      _dispatchPosition(seeded);
    } catch (_) {}
  }

  void _dispatchPosition(PositionData pos) {
    for (final lease in List<_StreamLease>.of(_leases.values)) {
      if (!lease.controller.isClosed) {
        lease.controller.add(pos);
      }
    }
  }

  void _emitLog({
    required String action,
    required String owner,
    required String mode,
    required LocationSettings settings,
    String? detail,
  }) {
    final baseSummary =
        GeolocatorLocationService.describeLocationSettings(settings);
    final summary =
        (detail != null && detail.isNotEmpty) ? '$detail | $baseSummary' : baseSummary;
    logStreamEvent?.call(
      action: action,
      owner: owner,
      mode: mode,
      settingsSummary: summary,
    );
  }

  static bool _sameLocationSettings(LocationSettings? a, LocationSettings? b) {
    if (a == null || b == null) return false;
    if (a.runtimeType != b.runtimeType) return false;
    if (a.accuracy != b.accuracy || a.distanceFilter != b.distanceFilter) {
      return false;
    }
    if (a is AndroidSettings && b is AndroidSettings) {
      return a.forceLocationManager == b.forceLocationManager &&
          a.intervalDuration == b.intervalDuration &&
          a.useMSLAltitude == b.useMSLAltitude &&
          (a.foregroundNotificationConfig != null) ==
              (b.foregroundNotificationConfig != null);
    }
    return true;
  }

  /// Cancels any active upstream subscription and clears state (for tests).
  Future<void> reset() async {
    _needsAnotherReconcile = false;
    _upstreamSessionToken++;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    unawaited(_upstreamSub?.cancel());
    _upstreamSub = null;
    _activeSettings = null;
    _activeHighAccuracy = null;
    _hasReceivedUpstreamFixInSession = false;
    _upstreamStartedAt = null;
    _trackingWatchdogAttempt = 0;
    _forceDisableFgNotifInSession = false;
    _forceUpstreamRestart = false;
    _setHasNoLocationUpdates(false);
    _leases.clear();
    _ownerCountsBeforeBatch.clear();
    _lastRemovedLeaseByOwner.clear();
    _lastAddedLeaseByOwner.clear();
    _touchedOwnersInBatch.clear();
  }
}

/// Production implementation backed by the [Geolocator] plugin.
class GeolocatorLocationService implements LocationService {
  const GeolocatorLocationService({
    PositionStreamCoordinator? coordinator,
  }) : _coordinatorOverride = coordinator;

  final PositionStreamCoordinator? _coordinatorOverride;

  static final PositionStreamCoordinator _sharedCoordinator =
      PositionStreamCoordinator(
    openUpstream: (settings) =>
        Geolocator.getPositionStream(locationSettings: settings)
            .map(_mapPosition),
    seedLightPosition: _seedPositionForLightStream,
    logStreamEvent: ({
      required String action,
      required String owner,
      required String mode,
      required String settingsSummary,
    }) {
      TrackingDiagnostics.instance.recordStreamEvent(
        action: action,
        owner: owner,
        mode: mode,
        settingsSummary: settingsSummary,
      );
    },
  );

  /// Active [PositionStreamCoordinator] managing stream leases and watchdog state.
  PositionStreamCoordinator get coordinator =>
      _coordinatorOverride ?? _sharedCoordinator;

  PositionStreamCoordinator get _coordinator =>
      _coordinatorOverride ?? _sharedCoordinator;

  /// Active upstream mode label (`"tracking"`, `"light"`, or `"idle"`) for diagnostics.
  String activeStreamSourceFor(LocationStreamOwner owner) =>
      _coordinator.streamSourceTagFor(owner);

  static Future<PositionData?> _seedPositionForLightStream() async {
    const service = GeolocatorLocationService();
    if (_isTesting) return null;
    if (!await service.isLocationServiceEnabled()) return null;
    if (!await service.checkPermission()) return null;
    return await service.getCurrentPosition() ??
        await service.getLastKnownPosition();
  }

  /// Formats the real fields of [settings] for diagnostics `[STREAM]` events.
  static String describeLocationSettings(LocationSettings settings) {
    if (settings is AndroidSettings) {
      final intervalLabel = settings.intervalDuration != null
          ? '${settings.intervalDuration!.inMilliseconds}ms'
          : 'null(default 5000ms)';
      return 'AndroidSettings(acc=${settings.accuracy.name}, '
          'dist=${settings.distanceFilter}m, '
          'interval=$intervalLabel, '
          'forceLocMgr=${settings.forceLocationManager}, '
          'fgNotif=${settings.foregroundNotificationConfig != null})';
    }
    return 'LocationSettings(acc=${settings.accuracy.name}, '
        'dist=${settings.distanceFilter}m, interval=none)';
  }

  static bool get _isTesting =>
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  /// Tracking mode: navigation-grade GPS accuracy level used by the ride tracker and active navigation streams.
  static const LocationAccuracy trackingAccuracy =
      LocationAccuracy.bestForNavigation;

  /// Tracking mode: distance filter in meters (`0` = deliver every fix without distance throttling).
  static const int trackingDistanceFilterMeters = 0;

  /// Tracking mode: target 1-second GPS update interval used on Android for ride tracking and active navigation.
  static const Duration trackingInterval = Duration(seconds: 1);

  /// Light mode: power-efficient accuracy level used by idle map, route preview, and place label streams.
  static const LocationAccuracy lightAccuracy = LocationAccuracy.medium;

  /// Light mode: distance filter in meters used by idle map, route preview, and place label streams (10m).
  static const int lightDistanceFilterMeters = 10;

  /// Light mode: update interval used on Android (`null` = platform default interval).
  static const Duration? lightInterval = null;

  /// Legacy alias for [trackingAccuracy].
  static const LocationAccuracy locationAccuracy = trackingAccuracy;

  /// Legacy alias for [trackingDistanceFilterMeters].
  static const int distanceFilterMeters = trackingDistanceFilterMeters;

  /// Legacy alias for [trackingInterval].
  static const Duration updateInterval = trackingInterval;

  /// Builds the platform [LocationSettings] for a position stream subscription.
  ///
  /// When [highAccuracy] is true, uses tracking mode:
  /// - Accuracy: [trackingAccuracy] ([LocationAccuracy.bestForNavigation])
  /// - Distance filter: [trackingDistanceFilterMeters] (`0` meters)
  /// - Interval: [trackingInterval] (1 second on Android)
  ///
  /// When [highAccuracy] is false, uses light mode:
  /// - Accuracy: [lightAccuracy] ([LocationAccuracy.medium])
  /// - Distance filter: [lightDistanceFilterMeters] (`10` meters)
  /// - Interval: [lightInterval] (platform default on Android)
  ///
  /// When `forceLocationManager` (or [SettingsController.gpsOnlyLocationProvider])
  /// is enabled, builds [AndroidSettings] with `forceLocationManager: true`.
  static LocationSettings buildLocationSettings({
    bool highAccuracy = false,
    bool enableForegroundNotification = false,
    bool? forceLocationManager,
  }) {
    final bool useGpsOnly = forceLocationManager ??
        SettingsController.instance.gpsOnlyLocationProvider;
    final bool useAndroidSettings = useGpsOnly ||
        (enableForegroundNotification &&
            !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.android) ||
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

    final accuracy = highAccuracy ? trackingAccuracy : lightAccuracy;
    final distanceFilter =
        highAccuracy ? trackingDistanceFilterMeters : lightDistanceFilterMeters;
    final interval = highAccuracy ? trackingInterval : lightInterval;

    if (useAndroidSettings) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        intervalDuration: interval,
        forceLocationManager: useGpsOnly,
        foregroundNotificationConfig: enableForegroundNotification
            ? const ForegroundNotificationConfig(
                notificationTitle: 'CAMP Ride Tracking',
                notificationText: 'CAMP is tracking this ride',
                enableWakeLock: true,
              )
            : null,
      );
    }

    return LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
    );
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    if (_isTesting) return false;
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> checkPermission() async {
    if (_isTesting) return false;
    try {
      final permission = await Geolocator.checkPermission();
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (_isTesting) return false;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PositionData?> getCurrentPosition() async {
    if (_isTesting) return null;
    try {
      final useAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
      final useGpsOnly = SettingsController.instance.gpsOnlyLocationProvider;
      final settings = useAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              forceLocationManager: useGpsOnly,
              timeLimit: const Duration(seconds: 8),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 8),
            );
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: settings,
      );
      return _mapPosition(pos);
    } catch (_) {
      // Fallback to last known position if immediate fix fails or times out
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return _mapPosition(last);
      } catch (_) {}
      return null;
    }
  }

  @override
  Future<PositionData?> getLastKnownPosition() async {
    if (_isTesting) return null;
    try {
      final pos = await Geolocator.getLastKnownPosition();
      return pos != null ? _mapPosition(pos) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<PositionData> getPositionStream({
    bool highAccuracy = false,
    bool enableForegroundNotification = false,
    bool? forceLocationManager,
    LocationStreamOwner owner = LocationStreamOwner.place,
  }) {
    return _coordinator.subscribe(
      owner: owner,
      highAccuracy: highAccuracy,
      enableForegroundNotification: enableForegroundNotification,
      forceLocationManager: forceLocationManager,
    );
  }

  @override
  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  static PositionData _mapPosition(Position p) {
    return PositionData(
      latitude: p.latitude,
      longitude: p.longitude,
      heading: p.heading >= 0 ? p.heading : null,
      speed: p.speed >= 0 ? p.speed : null,
      accuracy: p.accuracy >= 0 ? p.accuracy : null,
      altitude: p.altitude,
      timestamp: p.timestamp,
    );
  }
}
