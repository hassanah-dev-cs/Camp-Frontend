import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../../../app/theme/app_colors.dart';
import '../../controllers/navigation_controller.dart';
import '../../domain/routing_service.dart';

/// Fullscreen interactive map view rendering OpenStreetMap raster tiles,
/// polylines (active orange route + greyed passed segment), next-maneuver turn
/// marker, user GPS indicator (blue dot, accuracy circle, heading cone, rider
/// arrow), and waypoint markers.
class NavMapView extends StatelessWidget {
  const NavMapView({
    required this.controller,
    required this.mapController,
    this.tileProvider,
    this.onTapMap,
    this.onPositionChanged,
    super.key,
  });

  final NavigationController controller;
  final MapController mapController;
  final TileProvider? tileProvider;
  final VoidCallback? onTapMap;
  final PositionCallback? onPositionChanged;

  static const String _osmStandardUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _openTopoUrl =
      'https://tile.opentopomap.org/{z}/{x}/{y}.png';

  @override
  Widget build(BuildContext context) {
    final userLoc = controller.userLatLng;
    final isNavigating = controller.state == NavigationState.navigating;
    final isRidingState = isNavigating && controller.hasStartedMoving;
    final route = controller.route;
    final nextManeuver = controller.nextManeuverStep;

    // Determine screen-space rotation angle (in degrees) for the user marker.
    // Because Marker(rotate: true) counter-rotates the marker against the map's
    // rotation, 0.0 degrees in marker space always points straight UP on screen.
    // - In RIDING heading-up follow mode (!isNorthUpMode): the map itself rotates
    //   so the road ahead points UP; the rider arrow and cone stay fixed at 0.0°
    //   (pointing straight UP on screen).
    // - In RIDING North-up mode (isNorthUpMode) or READY / idle states: the map
    //   is North-up (0.0°), so the marker rotates by the compass heading.
    final double markerScreenHeadingDeg = (isRidingState && !controller.isNorthUpMode)
        ? 0.0
        : (isRidingState
            ? controller.smoothedHeadingDegrees
            : (controller.currentHeading ?? controller.smoothedHeadingDegrees));

    // Use cameraCenter which positions camera using GPS, destination, or Lahore fallback
    final initialCenter = controller.cameraCenter;

    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: 15.0,
        initialRotation: controller.mapRotationDegrees,
        minZoom: 3.0,
        maxZoom: 19.0,
        onTap: (_, _) => onTapMap?.call(),
        onPositionChanged: (pos, hasGesture) {
          if (hasGesture) {
            controller.markUserPanned();
          }
          onPositionChanged?.call(pos, hasGesture);
        },
        onMapEvent: (event) {
          // Manual two-finger rotation gestures emit MapEventRotate / MapEventRotateStart
          // without necessarily triggering onPositionChanged when center is unchanged.
          if ((event is MapEventRotate || event is MapEventRotateStart) &&
              event.source != MapEventSource.mapController &&
              event.source != MapEventSource.nonRotatedSizeChange) {
            controller.markUserPanned();
          }
        },
      ),
      children: [
        // 1. Tile Layer
        TileLayer(
          urlTemplate: controller.isTopoLayer ? _openTopoUrl : _osmStandardUrl,
          tileProvider: tileProvider,
          userAgentPackageName: 'com.camp.moto',
          maxZoom: 19,
          errorTileCallback: (tile, error, stackTrace) {},
        ),

        // 2. Polylines Layer (Route: alternate, greyed passed segment, active orange route)
        if (route != null) ...[
          // Alternate route polyline (subtle gray)
          if (route.alternatePolyline != null &&
              route.alternatePolyline!.isNotEmpty)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: route.alternatePolyline!,
                  strokeWidth: 6.0,
                  color: const Color(0xFF94A3B8).withValues(alpha: 0.7),
                  strokeCap: StrokeCap.round,
                  strokeJoin: StrokeJoin.round,
                ),
              ],
            ),

          // Greyed-out passed route segment behind the rider
          if (controller.passedRoutePolyline.length >= 2)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: controller.passedRoutePolyline,
                  strokeWidth: 6.0,
                  color: const Color(0xFF94A3B8).withValues(alpha: 0.75),
                  strokeCap: StrokeCap.round,
                  strokeJoin: StrokeJoin.round,
                ),
              ],
            ),

          // Primary active route polyline ahead of the rider (tactical orange with smooth border)
          if (controller.activeRoutePolyline.isNotEmpty)
            PolylineLayer(
              polylines: [
                // Outer border / glow line
                Polyline(
                  points: controller.activeRoutePolyline,
                  strokeWidth: 9.0,
                  color: AppColors.tacticalOrangeDark.withValues(alpha: 0.5),
                  strokeCap: StrokeCap.round,
                  strokeJoin: StrokeJoin.round,
                ),
                // Inner main line
                Polyline(
                  points: controller.activeRoutePolyline,
                  strokeWidth: 6.0,
                  color: AppColors.tacticalOrange,
                  strokeCap: StrokeCap.round,
                  strokeJoin: StrokeJoin.round,
                ),
              ],
            ),
        ],

        // 3. Waypoint Markers (Stops & Destination)
        if (controller.destination != null)
          MarkerLayer(
            markers: [
              // Intermediate stops
              ...controller.stops.asMap().entries.map((entry) {
                return Marker(
                  point: entry.value.location,
                  width: 32,
                  height: 32,
                  rotate: true,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.tacticalOrange,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${entry.key + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                );
              }),

              // Destination pin
              Marker(
                point: controller.destination!.location,
                width: 44,
                height: 44,
                rotate: true,
                alignment: Alignment.topCenter,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.tacticalOrange,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.tacticalOrange.withValues(alpha: 0.4),
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.place_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ],
          ),

        // 4. Next-Turn Maneuver Marker on Route (Active Navigation)
        if (isNavigating && nextManeuver != null)
          MarkerLayer(
            markers: [
              Marker(
                point: nextManeuver.location,
                width: 160,
                height: 64,
                rotate: true,
                child: _buildNextTurnMarker(nextManeuver),
              ),
            ],
          ),

        // 5. User GPS Location Marker (Dot, Accuracy Circle & Heading Cone)
        // Rendered strictly when a real GPS fix exists; never drawn at the camera fallback center.
        if (userLoc != null)
          MarkerLayer(
            markers: [
              Marker(
                point: userLoc,
                width: 120,
                height: 120,
                rotate: true,
                child: _buildUserLocationMarker(
                  screenHeadingDeg: markerScreenHeadingDeg,
                  isNavigating: isNavigating,
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// Builds a white turn-arrow badge at the next maneuver coordinate on the route.
  /// Displays the road/junction name strictly from `step.streetName` when present
  /// and never invents fallback labels.
  Widget _buildNextTurnMarker(RouteStep step) {
    final streetLabel = step.streetName.trim();
    return Column(
      key: const ValueKey('nav_next_turn_marker'),
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: const Color(0xFF141416),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              step.icon,
              color: Colors.white,
              size: 17,
            ),
          ),
        ),
        if (streetLabel.isNotEmpty) ...[
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF141416).withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.25),
              ),
            ),
            child: Text(
              streetLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildUserLocationMarker({
    required double screenHeadingDeg,
    required bool isNavigating,
  }) {
    final angleRad = (screenHeadingDeg * math.pi) / 180.0;
    return Stack(
      alignment: Alignment.center,
      children: [
        // Heading Cone (Projected directional beam)
        Transform.rotate(
          angle: angleRad,
          child: CustomPaint(
            size: const Size(120, 120),
            painter: _HeadingConePainter(),
          ),
        ),

        // Accuracy Halo
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xFF2563EB).withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
        ),

        // Inner Blue Dot with White Border
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: const Color(0xFF1E60FF),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1E60FF).withValues(alpha: 0.45),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
          child: isNavigating
              ? Transform.rotate(
                  key: const ValueKey('nav_rider_arrow_rotation'),
                  angle: angleRad,
                  child: const Icon(
                    Icons.navigation_rounded,
                    key: ValueKey('nav_rider_arrow'),
                    size: 12,
                    color: Colors.white,
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

/// Custom painter for directional heading beam cone.
class _HeadingConePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final conePaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF2563EB).withValues(alpha: 0.4),
          const Color(0xFF2563EB).withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: 55));

    final path = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: 55),
        -math.pi / 2 - (math.pi / 6),
        math.pi / 3,
        false,
      )
      ..close();

    canvas.drawPath(path, conePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
