import 'dart:async';

import 'package:camp/features/garage/controllers/active_bike_controller.dart';
import 'package:camp/features/garage/services/fuel_tracker_service.dart';
import 'package:camp/features/maintenance/domain/post_ride_report.dart';
import 'package:camp/features/navigation/controllers/navigation_controller.dart';
import 'package:camp/features/navigation/domain/geocoding_service.dart';
import 'package:camp/features/navigation/domain/location_service.dart';
import 'package:camp/features/navigation/domain/route_progress.dart';
import 'package:camp/features/navigation/domain/routing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_location_service.dart';
import 'helpers/fake_routing_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OSRM JSON Parsing & Route Construction', () {
    test('Parses complete OSRM payload including polyline, steps, metrics, and alternate', () {
      final sampleOsrmJson = {
        'code': 'Ok',
        'routes': [
          {
            'distance': 4333.3,
            'duration': 201.5,
            'geometry': {
              'coordinates': [
                [-120.687716, 48.513488],
                [-120.654240, 48.523575],
                [-120.642503, 48.514646],
              ],
              'type': 'LineString',
            },
            'legs': [
              {
                'steps': [
                  {
                    'name': 'North Cascades Highway',
                    'distance': 2900.3,
                    'duration': 134.6,
                    'maneuver': {
                      'type': 'depart',
                      'modifier': 'left',
                      'location': [-120.687716, 48.513488],
                    },
                  },
                  {
                    'name': 'Highway 20',
                    'distance': 1433.0,
                    'duration': 66.9,
                    'maneuver': {
                      'type': 'turn',
                      'modifier': 'right',
                      'location': [-120.654240, 48.523575],
                    },
                  },
                  {
                    'name': 'Timber Ridge Moto Outpost',
                    'distance': 0.0,
                    'duration': 0.0,
                    'maneuver': {
                      'type': 'arrive',
                      'location': [-120.642503, 48.514646],
                    },
                  },
                ],
              },
            ],
          },
          {
            'distance': 5100.0,
            'duration': 240.0,
            'geometry': {
              'coordinates': [
                [-120.687716, 48.513488],
                [-120.642503, 48.514646],
              ],
              'type': 'LineString',
            },
          },
        ],
      };

      final result = OsrmRoutingService.parseOsrmResponse(sampleOsrmJson);

      expect(result.polyline.length, 3);
      expect(result.polyline.first.latitude, 48.513488);
      expect(result.polyline.first.longitude, -120.687716);
      expect(result.distanceMeters, 4333.3);
      expect(result.durationSeconds, 201.5);
      expect(result.formattedDuration, '3 min');

      // Steps verification
      expect(result.steps.length, 3);
      expect(result.steps[0].maneuverType, 'depart');
      expect(result.steps[0].instruction, 'Head out on North Cascades Highway');
      expect(result.steps[1].maneuverType, 'turn');
      expect(result.steps[1].instruction, 'Turn right onto Highway 20');
      expect(result.steps[2].maneuverType, 'arrive');
      expect(result.steps[2].instruction, 'Arrive at destination');

      // Alternate polyline
      expect(result.alternatePolyline, isNotNull);
      expect(result.alternatePolyline!.length, 2);
      expect(result.alternateDurationSeconds, 240.0);
    });
  });

  group('Instruction Text Synthesis', () {
    test('Synthesizes depart, arrive, turns, and continues accurately', () {
      expect(
        RouteStep.synthesizeInstruction(
          type: 'depart',
          streetName: 'Cascade Loop',
          distanceMeters: 500,
        ),
        'Head out on Cascade Loop',
      );

      expect(
        RouteStep.synthesizeInstruction(
          type: 'turn',
          modifier: 'right',
          streetName: 'Bear Creek Pass Rd',
          distanceMeters: 3800,
        ),
        'Turn right onto Bear Creek Pass Rd',
      );

      expect(
        RouteStep.synthesizeInstruction(
          type: 'turn',
          modifier: 'left',
          streetName: 'Highway 20',
          distanceMeters: 1200,
        ),
        'Turn left onto Highway 20',
      );

      expect(
        RouteStep.synthesizeInstruction(
          type: 'turn',
          modifier: 'slight right',
          streetName: 'Forest Spur',
          distanceMeters: 400,
        ),
        'Slight right onto Forest Spur',
      );

      expect(
        RouteStep.synthesizeInstruction(
          type: 'turn',
          modifier: 'uturn',
          streetName: 'Main St',
          distanceMeters: 100,
        ),
        'Make a U-turn onto Main St',
      );

      expect(
        RouteStep.synthesizeInstruction(
          type: 'arrive',
          streetName: '',
          distanceMeters: 0,
        ),
        'Arrive at destination',
      );
    });
  });

  group('Off-Route Distance & Step Progression', () {
    test('Calculates distance from point to polyline accurately', () {
      final polyline = [
        const LatLng(48.500, -120.600),
        const LatLng(48.500, -120.700),
      ];

      // Point directly on segment
      const onLine = LatLng(48.500, -120.650);
      expect(
        RouteProgress.snapToRoute(
          polyline: polyline,
          point: onLine,
          searchEntirePolyline: true,
        ).crossTrackMeters,
        lessThan(5.0),
      );

      // Point roughly 110m north
      const offLine = LatLng(48.501, -120.650);
      final dist = RouteProgress.snapToRoute(
        polyline: polyline,
        point: offLine,
        searchEntirePolyline: true,
      ).crossTrackMeters;
      expect(dist, greaterThan(80.0));
      expect(dist, lessThan(140.0));
    });

    test('Step advance when within ~30m of maneuver point', () async {
      final fakeLocation = FakeLocationService(
        initialPosition: PositionData(
          latitude: 48.500,
          longitude: -120.600,
          timestamp: DateTime.now(),
        ),
      );
      final fakeRouting = FakeRoutingService();
      final controller = NavigationController(
        locationService: fakeLocation,
        routingService: fakeRouting,
      );

      await controller.openRoutePreview(
        const PlaceSearchResult(
          name: 'Summit Outpost',
          displayName: 'Summit Outpost, WA',
          location: LatLng(48.520, -120.650),
        ),
      );

      controller.startNavigation();
      expect(controller.currentStepIndex, 0);

      // Move vehicle to within 20m of step 1 maneuver location
      final step1Loc = controller.route!.steps[1].location;
      fakeLocation.emitPosition(
        PositionData(
          latitude: step1Loc.latitude,
          longitude: step1Loc.longitude,
          timestamp: DateTime.now(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentStepIndex, 1);
      controller.dispose();
    });

    test('Transitions to arrived state when within ~30m of destination', () async {
      final fakeLocation = FakeLocationService();
      final fakeRouting = FakeRoutingService();
      final controller = NavigationController(
        locationService: fakeLocation,
        routingService: fakeRouting,
      );

      await controller.openRoutePreview(
        const PlaceSearchResult(
          name: 'Summit Outpost',
          displayName: 'Summit Outpost, WA',
          location: LatLng(48.520, -120.650),
        ),
      );

      controller.startNavigation();
      expect(controller.state, NavigationState.navigating);

      // Move within 10 meters of destination (last polyline coordinate)
      final destLoc = controller.route!.polyline.last;
      fakeLocation.emitPosition(
        PositionData(
          latitude: destLoc.latitude,
          longitude: destLoc.longitude,
          timestamp: DateTime.now(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, NavigationState.arrived);
      controller.dispose();
    });
  });

  group('Speed Conversion across Unit Systems', () {
    test('Converts reported speed in m/s to KM/H and shows -- or 0 when stationary', () async {
      final fakeLocation = FakeLocationService();
      final controller = NavigationController(locationService: fakeLocation);
      controller.startPositionStream();

      final t0 = DateTime(2026, 6, 1, 12, 0, 0);

      // 10 m/s in Metric -> 36 km/h
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.0,
          longitude: -120.0,
          accuracy: 8.0,
          speed: 10.0,
          timestamp: t0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentSpeed, 36);
      expect(controller.formattedSpeed, '36');
      expect(controller.speedUnitLabel, 'KM / H');

      // Stationary good fixes spanning >= 5 s with negative/null speed return 0
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.0,
          longitude: -120.0,
          accuracy: 8.0,
          speed: -1.0,
          timestamp: t0.add(const Duration(seconds: 5)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentSpeed, 0);

      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.0,
          longitude: -120.0,
          accuracy: 8.0,
          speed: null,
          timestamp: t0.add(const Duration(seconds: 10)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentSpeed, 0);

      controller.dispose();
    });

    test('hasStartedMoving: requires 3s continuous >= 1.4 m/s, does not flip on single fix, resets on null/new nav, survives 0', () async {
      final fakeLocation = FakeLocationService();
      final fakeRouting = FakeRoutingService();
      final controller = NavigationController(
        locationService: fakeLocation,
        routingService: fakeRouting,
      );
      controller.startPositionStream();

      // Open preview and start guidance
      await controller.openRoutePreview(
        const PlaceSearchResult(
          name: 'Timber Ridge',
          displayName: 'Timber Ridge',
          location: LatLng(48.514646, -120.642503),
        ),
      );
      await controller.startNavigation();
      expect(controller.hasStartedMoving, isFalse);

      final t0 = DateTime(2026, 6, 1, 12, 0, 0);

      // Fix 1: Single fast fix at t0 (10.0 m/s = 36 km/h >= 1.4 m/s)
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.513488,
          longitude: -120.687716,
          accuracy: 8.0,
          speed: 10.0,
          timestamp: t0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      // Does not flip on a single fast fix
      expect(controller.currentSpeed, 36);
      expect(controller.hasStartedMoving, isFalse);

      // Fix 2: Moving fix 2 seconds later (elapsed = 2.0s < 3.0s)
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.513600,
          longitude: -120.687500,
          accuracy: 8.0,
          speed: 10.0,
          timestamp: t0.add(const Duration(seconds: 2)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasStartedMoving, isFalse);

      // Fix 3: Null speed / expired speed fix resets the 3-second timer
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.513700,
          longitude: -120.687300,
          accuracy: 60.0, // bad accuracy resets speed
          speed: null,
          timestamp: t0.add(const Duration(seconds: 12)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentSpeed, isNull);
      expect(controller.hasStartedMoving, isFalse);

      // Fix 4: Fresh fast fix at t1 after reset
      final t1 = t0.add(const Duration(seconds: 15));
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.513800,
          longitude: -120.687100,
          accuracy: 8.0,
          speed: 10.0,
          timestamp: t1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasStartedMoving, isFalse);

      // Fix 5: Moving fix at t1 + 3s (elapsed >= 3.0s continuously) -> flips to true
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.514000,
          longitude: -120.686800,
          accuracy: 8.0,
          speed: 10.0,
          timestamp: t1.add(const Duration(seconds: 3)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasStartedMoving, isTrue);

      // Fix 6: Speed drops to 0 (stopped at red light) -> does NOT revert
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.514000,
          longitude: -120.686800,
          accuracy: 8.0,
          speed: 0.0,
          timestamp: t1.add(const Duration(seconds: 8)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasStartedMoving, isTrue);

      // Starting a new navigation resets hasStartedMoving to false
      await controller.startNavigation();
      expect(controller.hasStartedMoving, isFalse);

      // Stopping navigation resets hasStartedMoving to false
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.514000,
          longitude: -120.686800,
          accuracy: 8.0,
          speed: 2.0,
          timestamp: t1.add(const Duration(seconds: 10)),
        ),
      );
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.514000,
          longitude: -120.686800,
          accuracy: 8.0,
          speed: 2.0,
          timestamp: t1.add(const Duration(seconds: 13)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasStartedMoving, isTrue);
      controller.stopNavigation();
      expect(controller.hasStartedMoving, isFalse);

      controller.dispose();
      fakeLocation.dispose();
    });
  });

  group('Fuel Estimate Calculation', () {
    test('Calculates fuel estimate when bike has fuelAverageKmPerLiter, hides when null', () async {
      final fakeRouting = FakeRoutingService();
      final controller = NavigationController(routingService: fakeRouting);

      // Test route distance is 5.4 km
      await controller.openRoutePreview(
        const PlaceSearchResult(
          name: 'Outpost',
          displayName: 'Outpost',
          location: LatLng(48.5, -120.6),
        ),
      );

      final bike = ActiveBikeController.instance.activeBike;
      if (bike?.fuelAverageKmPerLiter != null) {
        expect(controller.fuelEstimateDisplay, contains('L'));
      } else {
        expect(controller.fuelEstimateDisplay, isNull);
      }

      controller.dispose();
    });
  });

  group('Google Maps Link Builder', () {
    test('Constructs standard Google Maps URL in two-wheeler mode', () {
      const dest = LatLng(48.520000, -120.650000);
      final url = NavigationController.buildGoogleMapsUrl(dest);

      expect(
        url,
        'https://www.google.com/maps/dir/?api=1&destination=48.520000,-120.650000&travelmode=two-wheeler',
      );
    });
  });

  group('NavigationController Lifecycle & Stability', () {
    test('Disposing controller while permission request is pending completes without throwing', () async {
      final permCompleter = Completer<bool>();
      final locationService = _PendingPermissionLocationService(permCompleter);
      final controller = NavigationController(locationService: locationService);

      final initFuture = controller.initialize();
      controller.dispose();
      expect(controller.isDisposed, isTrue);

      permCompleter.complete(true);
      await expectLater(initFuture, completes);
    });

    test('Disposing controller while getCurrentPosition is pending completes without throwing', () async {
      final posCompleter = Completer<PositionData?>();
      final locationService = _PendingPositionLocationService(posCompleter);
      final controller = NavigationController(locationService: locationService);

      final initFuture = controller.initialize();
      controller.dispose();
      expect(controller.isDisposed, isTrue);

      posCompleter.complete(
        PositionData(
          latitude: 48.515,
          longitude: -120.690,
          timestamp: DateTime.now(),
        ),
      );
      await expectLater(initFuture, completes);
    });

    test('Disposing controller while route request is pending completes without throwing', () async {
      final routeCompleter = Completer<RouteResult>();
      final routingService = _PendingRouteRoutingService(routeCompleter);
      final controller = NavigationController(routingService: routingService);

      final previewFuture = controller.openRoutePreview(
        const PlaceSearchResult(
          name: 'Summit Outpost',
          displayName: 'Summit Outpost, WA',
          location: LatLng(48.520, -120.650),
        ),
      );
      controller.dispose();
      expect(controller.isDisposed, isTrue);

      routeCompleter.complete(
        const RouteResult(
          polyline: [LatLng(48.515, -120.690), LatLng(48.520, -120.650)],
          distanceMeters: 1200.0,
          durationSeconds: 150.0,
          steps: [],
        ),
      );
      await expectLater(previewFuture, completes);
    });
  });

  group('Fallback Centre & Location Off Safety Tests', () {
    test('Fallback centre does not affect distance or ETA calculations when location is off', () async {
      final fakeLocation = FakeLocationService(
        nullInitialPosition: true,
        serviceEnabled: false,
      );
      final fakeRouting = FakeRoutingService();
      final controller = NavigationController(
        locationService: fakeLocation,
        routingService: fakeRouting,
      );

      // Verify initial state: userLatLng is null and camera center points to Lahore fallback
      expect(controller.userLatLng, isNull);
      expect(controller.cameraCenter, NavigationController.defaultFallbackCenter);
      expect(controller.cameraCenter.latitude, 31.5204);
      expect(controller.cameraCenter.longitude, 74.3587);

      const destination = PlaceSearchResult(
        name: 'Margalla Ridge',
        displayName: 'Margalla Ridge Trailhead, Islamabad',
        location: LatLng(33.74, 73.05),
      );

      // Attempt to preview route when GPS location is unavailable
      await controller.openRoutePreview(destination);

      // Verify that Lahore fallback centre is NEVER used in route, distance, or ETA
      expect(controller.route, isNull);
      expect(controller.remainingDistanceMeters, 0.0);
      expect(controller.remainingDurationSeconds, 0.0);
      expect(controller.eta, isNull);
      expect(
        controller.routeError,
        'Location unavailable. Turn on GPS to calculate route.',
      );

      // Verify cameraCenter now points to destination rather than user position
      expect(controller.cameraCenter, destination.location);
      expect(controller.userLatLng, isNull);

      // Attempting to calculate route again with location off must still result in 0 distance and null ETA
      await controller.calculateRoute();
      expect(controller.route, isNull);
      expect(controller.remainingDistanceMeters, 0.0);
      expect(controller.remainingDurationSeconds, 0.0);
      expect(controller.eta, isNull);

      // Swapping endpoints when GPS is off must not set destination to Lahore fallback center
      controller.swapStartAndDestination();
      expect(controller.destination?.name, 'Margalla Ridge');
      expect(controller.destination?.location, destination.location);

      // When GPS fix is later acquired, real route and distance can be calculated
      controller.startPositionStream();
      fakeLocation.emitPosition(
        PositionData(
          latitude: 33.70,
          longitude: 73.00,
          timestamp: DateTime.now(),
        ),
      );
      // Allow stream and calculateRoute async future to settle
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(controller.userLatLng, isNotNull);
      expect(controller.userLatLng!.latitude, 33.70);
      expect(controller.route, isNotNull);
      expect(controller.remainingDistanceMeters, greaterThan(0.0));
      expect(controller.eta, isNotNull);

      controller.dispose();
      fakeLocation.dispose();
    });
  });

  group('ETA & Time Formatting in Local Time', () {
    test('formattedEta converts UTC fix timestamp to local time and keeps stored eta in UTC', () async {
      final fakeLocation = FakeLocationService();
      final fakeRouting = FakeRoutingService();
      final controller = NavigationController(
        locationService: fakeLocation,
        routingService: fakeRouting,
      );

      const destination = PlaceSearchResult(
        name: 'Target Destination',
        displayName: 'Target Point',
        location: LatLng(48.514646, -120.642503),
      );
      await controller.openRoutePreview(destination);
      await controller.startNavigation();

      // Emit a position with an explicit UTC timestamp (11:15 UTC)
      final utcTimestamp = DateTime.utc(2026, 11, 9, 11, 15, 0);
      fakeLocation.emitPosition(
        PositionData(
          latitude: 48.513488,
          longitude: -120.687716,
          timestamp: utcTimestamp,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(controller.eta, isNotNull);
      // Stored ETA must remain in UTC as inherited from the GPS fix timestamp
      expect(controller.eta!.isUtc, isTrue);

      final localEta = controller.eta!.toLocal();
      final expectedHour = localEta.hour.toString().padLeft(2, '0');
      final expectedMinute = localEta.minute.toString().padLeft(2, '0');
      expect(controller.formattedEta, '$expectedHour:$expectedMinute');

      // If the running environment has a non-zero UTC offset, assert that
      // formattedEta does not match raw UTC values (which would happen if .toLocal() was missing).
      if (localEta.timeZoneOffset != Duration.zero) {
        final utcHour = controller.eta!.toUtc().hour.toString().padLeft(2, '0');
        final utcMinute = controller.eta!.toUtc().minute.toString().padLeft(2, '0');
        expect(controller.formattedEta, isNot('$utcHour:$utcMinute'));
      }

      controller.dispose();
      fakeLocation.dispose();
    });

    test('PostRideReport formats date using toLocal() while preserving UTC storage', () {
      // 23:30 UTC on Nov 9: in UTC+5 (Pakistan) this is Nov 10, 04:30
      final utcDate = DateTime.utc(2026, 11, 9, 23, 30);
      final report = PostRideReport(
        id: 'test-1',
        bikeId: 'bike-123',
        date: utcDate,
        distanceKm: 12.0,
        terrainTags: const ['highway'],
        routeTitle: 'Morning Ride',
      );

      expect(report.date.isUtc, isTrue);
      final localDate = utcDate.toLocal();
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final expectedMonth = months[localDate.month - 1];
      final expectedDateStr = '$expectedMonth ${localDate.day}, ${localDate.year}';
      expect(report.formattedDate, expectedDateStr);
    });
  });

  group('BATCH S4-4b: Heading-Up Map, Rotation Smoothing, Auto-Zoom & Shared Heading Getter', () {
    late FakeLocationService fakeLocation;
    late FakeRoutingService fakeRouting;
    late NavigationController controller;
    late DateTime t0;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      t0 = DateTime.utc(2026, 6, 10, 8, 0, 0);
      fakeLocation = FakeLocationService(
        initialPosition: PositionData(
          latitude: 31.5200,
          longitude: 74.3587,
          accuracy: 5.0,
          speed: 0.0,
          timestamp: t0,
        ),
      );
      fakeRouting = FakeRoutingService();
      FuelTrackerService.instance.setDependenciesForTesting(
        locationService: fakeLocation,
      );
      controller = NavigationController(
        locationService: fakeLocation,
        routingService: fakeRouting,
      );
    });

    tearDown(() async {
      await FuelTrackerService.instance.stopRide();
      controller.dispose();
      fakeLocation.dispose();
      FuelTrackerService.instance.resetForTesting();
    });

    test('reliableHeadingDegrees is shared by reroute and map, ignores phone heading, and uses fix dist/time even when speedometer is "--"', () async {
      await controller.initialize();
      const destination = PlaceSearchResult(
        name: 'Dest',
        displayName: 'Dest',
        location: LatLng(31.5500, 74.4000),
      );
      await controller.openRoutePreview(destination);
      await controller.startNavigation();

      // Emit 3 off-route good fixes (accuracy <= 30 m) ~38 m apart Eastbound over 5 s each (spanning 10 s >= 8 s),
      // with bogus phone pos.heading (270° West).
      for (int i = 0; i < 3; i++) {
        fakeLocation.emitPosition(
          PositionData(
            latitude: 31.6500, // Off-route to trigger reroute on 3rd fix
            longitude: 74.3500 + (i * 0.0004), // ~38 m East per step (bearing ~90°)
            accuracy: 8.0,
            speed: null,
            heading: 270.0, // Bogus phone compass heading — must be ignored
            timestamp: t0.add(Duration(seconds: 2 + (i * 5))),
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }

      // Shared getter computes ~90° from the good fixes' dist/time, ignoring bogus pos.heading
      final sharedHeading = controller.reliableHeadingDegrees;
      expect(sharedHeading, isNotNull);
      expect(sharedHeading!, closeTo(90.0, 1.0));

      // Reroute triggered on the 3rd off-route fix and used the exact same shared heading
      expect(fakeRouting.requests.length, greaterThanOrEqualTo(2));
      expect(
        fakeRouting.requests.last.startBearingDegrees,
        closeTo(sharedHeading, 1e-6),
      );

      // Emit a weak GPS fix > 20 s later (accuracy 65 m -> gpsWeak = true, formattedSpeed = '--').
      // reliableHeadingDegrees still returns ~90° from the last two good fixes.
      fakeLocation.emitPosition(
        PositionData(
          latitude: 31.6500,
          longitude: 74.3510,
          accuracy: 65.0,
          speed: null,
          heading: 0.0,
          timestamp: t0.add(const Duration(seconds: 35)),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.gpsWeak, isTrue);
      expect(controller.formattedSpeed, '--');
      expect(controller.reliableHeadingDegrees, closeTo(90.0, 1.0));
    });

    test('READY state stays north-up (0°), RIDING rotates heading-up, and null heading keeps last rotation without snapping to north', () async {
      await controller.initialize();
      const destination = PlaceSearchResult(
        name: 'Dest',
        displayName: 'Dest',
        location: LatLng(31.5500, 74.4000),
      );
      await controller.openRoutePreview(destination);

      // Route Preview state is north-up (0.0°)
      expect(controller.state, NavigationState.previewing);
      expect(controller.mapRotationDegrees, 0.0);

      await controller.startNavigation();
      expect(controller.state, NavigationState.navigating);
      expect(controller.hasStartedMoving, isFalse);

      // Emit fix in READY state (before 3s sustained movement): stays north-up (0.0°)
      fakeLocation.emitPosition(
        PositionData(
          latitude: 31.5204,
          longitude: 74.3587,
          accuracy: 5.0,
          speed: 8.0,
          timestamp: t0.add(const Duration(seconds: 1)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasStartedMoving, isFalse);
      expect(controller.mapRotationDegrees, 0.0);

      // Move East ~38 m over 4 s -> enters RIDING state (hasStartedMoving = true)
      // with reliableHeadingDegrees ~90° East
      fakeLocation.emitPosition(
        PositionData(
          latitude: 31.5204,
          longitude: 74.3591,
          accuracy: 5.0,
          speed: 8.0,
          timestamp: t0.add(const Duration(seconds: 5)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasStartedMoving, isTrue);
      expect(controller.reliableHeadingDegrees, closeTo(90.0, 1.0));
      // Heading 90° East puts East at the top of the screen -> mapRotationDegrees = -90°
      expect(controller.mapRotationDegrees, closeTo(-90.0, 1.0));
      final lastRotation = controller.mapRotationDegrees;

      // Rider stops at a traffic light (1 m movement over 10 s -> < 2.0 m/s -> reliableHeadingDegrees is null)
      fakeLocation.emitPosition(
        PositionData(
          latitude: 31.5204,
          longitude: 74.35911,
          accuracy: 5.0,
          speed: 0.0,
          timestamp: t0.add(const Duration(seconds: 15)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.reliableHeadingDegrees, isNull);
      // Map MUST keep its last rotation (-90°) and NOT snap to 0° North
      expect(controller.mapRotationDegrees, equals(lastRotation));
    });

    test('Shortest-angle turning across 0°, 90°/s turn-rate limit, and 5° jitter deadband', () {
      // 1. Shortest-angle delta across 350° -> 10° is +20° (not -340°)
      expect(RouteProgress.shortestAngleDeltaDegrees(350.0, 10.0), closeTo(20.0, 1e-6));
      expect(RouteProgress.shortestAngleDeltaDegrees(10.0, 350.0), closeTo(-20.0, 1e-6));

      // 2. Changes under 5° deadband are ignored
      final deadbandResult = RouteProgress.stepSmoothedHeadingDegrees(
        currentHeadingDegrees: 100.0,
        targetHeadingDegrees: 103.8, // +3.8° < 5.0°
        dtSeconds: 1.0,
      );
      expect(deadbandResult, 100.0);

      // 3. Turn rate limited to 90°/s across shortest path:
      // From 350° to 120° is +130° clockwise; over 1.0 s at 90°/s max rate, steps to (350 + 90) % 360 = 80°
      final rateLimited = RouteProgress.stepSmoothedHeadingDegrees(
        currentHeadingDegrees: 350.0,
        targetHeadingDegrees: 120.0,
        dtSeconds: 1.0,
      );
      expect(rateLimited, closeTo(80.0, 1e-6));

      // Next 1.0 s step completes the remaining +40° to 120°
      final completed = RouteProgress.stepSmoothedHeadingDegrees(
        currentHeadingDegrees: rateLimited,
        targetHeadingDegrees: 120.0,
        dtSeconds: 1.0,
      );
      expect(completed, closeTo(120.0, 1e-6));
    });

    test('Rider dot offset places rider at 70% down screen in RIDING follow mode; panning pauses and Recenter restores', () async {
      await controller.initialize();
      const destination = PlaceSearchResult(
        name: 'Dest',
        displayName: 'Dest',
        location: LatLng(31.5500, 74.4000),
      );
      await controller.openRoutePreview(destination);
      await controller.startNavigation();

      // Enter RIDING heading North (0°)
      fakeLocation.emitPosition(
        PositionData(
          latitude: 31.5200,
          longitude: 74.3587,
          accuracy: 5.0,
          speed: 8.0,
          timestamp: t0.add(const Duration(seconds: 1)),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      fakeLocation.emitPosition(
        PositionData(
          latitude: 31.5204, // ~44 m North
          longitude: 74.3587,
          accuracy: 5.0,
          speed: 8.0,
          timestamp: t0.add(const Duration(seconds: 5)),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.hasStartedMoving, isTrue);
      expect(controller.isScreenCentered, isTrue);

      final riderPos = controller.userLatLng!;
      final offsetCenter = controller.cameraCenterForViewportHeight(800.0);
      // Because heading is North (0°), the camera center is offset North (higher latitude)
      // of the rider so the rider dot sits lower on the screen (70% from top).
      expect(offsetCenter.latitude, greaterThan(riderPos.latitude));

      // Manual pan pauses follow mode
      controller.markUserPanned();
      expect(controller.isScreenCentered, isFalse);

      // Toggling North-up then tapping Recenter restores heading-up follow mode
      controller.toggleCompassMode();
      expect(controller.isNorthUpMode, isTrue);
      controller.recenterMap();
      expect(controller.isScreenCentered, isTrue);
      expect(controller.isNorthUpMode, isFalse);
    });

    test('Speed-based auto-zoom adjusts smoothly with speed and does not change while rider is interacting', () async {
      await controller.initialize();
      const destination = PlaceSearchResult(
        name: 'Dest',
        displayName: 'Dest',
        location: LatLng(31.5500, 74.4000),
      );
      await controller.openRoutePreview(destination);
      await controller.startNavigation();

      // Slow riding (3 m/s = 10.8 km/h <= 20 km/h) -> zoom trends toward slowRiderZoom (17.5)
      fakeLocation.emitPosition(
        PositionData(
          latitude: 31.5200,
          longitude: 74.3587,
          accuracy: 5.0,
          speed: 3.0,
          timestamp: t0.add(const Duration(seconds: 1)),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      fakeLocation.emitPosition(
        PositionData(
          latitude: 31.5203,
          longitude: 74.3587,
          accuracy: 5.0,
          speed: 3.0,
          timestamp: t0.add(const Duration(seconds: 5)),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final slowZoom = controller.targetZoom;
      expect(slowZoom, greaterThan(17.0));

      // Fast riding (25 m/s = 90 km/h >= 80 km/h) -> zoom decreases toward fastRiderZoom (15.5)
      for (int i = 1; i <= 5; i++) {
        fakeLocation.emitPosition(
          PositionData(
            latitude: 31.5203 + (i * 0.0005),
            longitude: 74.3587,
            accuracy: 5.0,
            speed: 25.0,
            timestamp: t0.add(Duration(seconds: 5 + (i * 2))),
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }
      final fastZoom = controller.targetZoom;
      expect(fastZoom, lessThan(slowZoom));

      // When user pans (!isScreenCentered), targetZoom is frozen and never modified
      controller.markUserPanned();
      final frozenZoom = controller.targetZoom;
      fakeLocation.emitPosition(
        PositionData(
          latitude: 31.5250,
          longitude: 74.3587,
          accuracy: 5.0,
          speed: 3.0,
          timestamp: t0.add(const Duration(seconds: 20)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.targetZoom, equals(frozenZoom));
    });
  });

  group('BATCH GPS-RATE-3 Step 4: Route Preview Seeding', () {
    test('Seeds preview from getLastKnownPosition when light stream emits nothing and getCurrentPosition returns null', () async {
      final lastKnown = PositionData(
        latitude: 33.6844,
        longitude: 73.0479,
        accuracy: 8.0,
        timestamp: DateTime.utc(2026, 11, 14, 12, 0, 0),
      );
      final locationService = _LastKnownOnlyLocationService(lastKnown: lastKnown);
      final controller = NavigationController(
        locationService: locationService,
        routingService: FakeRoutingService(),
      );

      await controller.openRoutePreview(
        const PlaceSearchResult(
          name: 'Margalla Hills',
          displayName: 'Margalla Hills, Islamabad',
          location: LatLng(33.74, 73.05),
        ),
      );

      expect(controller.routeError, isNull);
      expect(controller.route, isNotNull);
      expect(controller.userLatLng?.latitude, closeTo(33.6844, 0.0001));

      controller.dispose();
      locationService.dispose();
    });

    test('Retry via calculateRoute seeds position once GPS becomes available while stationary', () async {
      final locationService = FakeLocationService(
        nullInitialPosition: true,
        serviceEnabled: true,
      );
      final controller = NavigationController(
        locationService: locationService,
        routingService: FakeRoutingService(),
      );

      await controller.openRoutePreview(
        const PlaceSearchResult(
          name: 'Daman-e-Koh',
          displayName: 'Daman-e-Koh, Islamabad',
          location: LatLng(33.74, 73.06),
        ),
      );
      expect(
        controller.routeError,
        'Location unavailable. Turn on GPS to calculate route.',
      );

      // Location becomes available via one-off fix (no stream emission needed)
      locationService.emitPosition(
        PositionData(
          latitude: 33.7000,
          longitude: 73.0400,
          accuracy: 6.0,
          timestamp: DateTime.utc(2026, 11, 14, 12, 1, 0),
        ),
      );

      // Call calculateRoute directly (as Retry button does)
      await controller.calculateRoute();
      expect(controller.routeError, isNull);
      expect(controller.route, isNotNull);

      controller.dispose();
      locationService.dispose();
    });

    test('Keeps Location unavailable error when permission is denied even if a cached fix exists', () async {
      final locationService = FakeLocationService(hasPermission: false);
      final controller = NavigationController(
        locationService: locationService,
        routingService: FakeRoutingService(),
      );

      await controller.openRoutePreview(
        const PlaceSearchResult(
          name: 'Faisal Mosque',
          displayName: 'Faisal Mosque, Islamabad',
          location: LatLng(33.73, 73.03),
        ),
      );

      expect(
        controller.routeError,
        'Location unavailable. Turn on GPS to calculate route.',
      );
      expect(controller.route, isNull);

      controller.dispose();
      locationService.dispose();
    });

    test('PositionStreamCoordinator seeds light stream once when initial upstream emits nothing', () async {
      final seedPos = PositionData(
        latitude: 33.6910,
        longitude: 73.0510,
        accuracy: 7.0,
        timestamp: DateTime.utc(2026, 11, 14, 12, 5, 0),
      );
      final coordinator = PositionStreamCoordinator(
        openUpstream: (_) => const Stream<PositionData>.empty(),
        seedLightPosition: () async => seedPos,
      );

      final received = <PositionData>[];
      final sub = coordinator
          .subscribe(
            owner: LocationStreamOwner.navigation,
            highAccuracy: false,
            enableForegroundNotification: false,
          )
          .listen(received.add);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received.length, 1);
      expect(received.first.latitude, closeTo(33.6910, 0.0001));

      await sub.cancel();
      await coordinator.reset();
    });
  });
}

class _LastKnownOnlyLocationService extends FakeLocationService {
  _LastKnownOnlyLocationService({required this.lastKnown})
      : super(nullInitialPosition: true);

  final PositionData lastKnown;

  @override
  Future<PositionData?> getCurrentPosition() async => null;

  @override
  Future<PositionData?> getLastKnownPosition() async => lastKnown;
}

class _PendingPermissionLocationService extends FakeLocationService {
  _PendingPermissionLocationService(this.permissionCompleter);
  final Completer<bool> permissionCompleter;

  @override
  Future<bool> checkPermission() async => false;

  @override
  Future<bool> requestPermission() => permissionCompleter.future;
}

class _PendingPositionLocationService extends FakeLocationService {
  _PendingPositionLocationService(this.positionCompleter);
  final Completer<PositionData?> positionCompleter;

  @override
  Future<bool> checkPermission() async => true;

  @override
  Future<PositionData?> getCurrentPosition() => positionCompleter.future;
}

class _PendingRouteRoutingService extends FakeRoutingService {
  _PendingRouteRoutingService(this.routeCompleter);
  final Completer<RouteResult> routeCompleter;

  @override
  Future<RouteResult> getRoute({
    required List<LatLng> waypoints,
    String mode = 'motorcycle',
    bool requestAlternatives = false,
    double? startBearingDegrees,
    double startBearingToleranceDegrees = 45.0,
    double? startRadiusMeters,
  }) =>
      routeCompleter.future;
}
