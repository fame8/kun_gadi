import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../models/route_model.dart';
import '../models/stop_model.dart';
import '../services/route_service.dart';

const String GOOGLE_API_KEY = 'AIzaSyBVEoTUtT7P_OA2hRE-T-YbcOJtQLuprb4';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final RouteService _routeService = RouteService();
  final TextEditingController _searchController = TextEditingController();
  GoogleMapController? _mapController;
  List<RouteModel> _routes = [];
  List<RouteModel> _filteredRoutes = [];
  final Set<Polyline> _polylines = {};
  final Set<Marker> _markers = {};
  List<StopModel> _activeDestinations = [];
  LatLng? _currentLocation;
  String? _bestRouteId;
  RouteModel? _walkRoute;
  int? _walkDurationMinutes;
  Map<String, Map<String, int>> _routeFares = {};

  // New: Track walking times to nearest stops and total journey times
  Map<String, int> _walkingTimesToNearestStop = {};
  Map<String, int> _totalJourneyTimes = {};

  // Updated sorting options
  String _sortOption = 'Distance'; // default

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadRoutes();
    await _getLocation();
  }

  Future<void> _loadRoutes() async {
    final r = await _routeService.getAllRoutes();
    setState(() {
      _routes = r;
      _filteredRoutes = r;
    });
  }

  Future<void> _getLocation() async {
    await Geolocator.requestPermission();
    final pos = await Geolocator.getCurrentPosition();
    _currentLocation = LatLng(pos.latitude, pos.longitude);
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      poly.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return poly;
  }

  Future<List<LatLng>> _getDrivingRoute(
    LatLng origin,
    LatLng destination,
  ) async {
    final url =
        'https://maps.googleapis.com/maps/api/directions/json?origin=${origin.latitude},${origin.longitude}&destination=${destination.latitude},${destination.longitude}&mode=driving&key=$GOOGLE_API_KEY';
    final res = await http.get(Uri.parse(url));
    final data = jsonDecode(res.body);
    if (data['status'] != 'OK') return [];
    return _decodePolyline(data['routes'][0]['overview_polyline']['points']);
  }

  Future<WalkingResult?> _getWalkingRoute(
    LatLng origin,
    LatLng destination,
  ) async {
    final url =
        'https://maps.googleapis.com/maps/api/directions/json?origin=${origin.latitude},${origin.longitude}&destination=${destination.latitude},${destination.longitude}&mode=walking&key=$GOOGLE_API_KEY';
    final res = await http.get(Uri.parse(url));
    final data = jsonDecode(res.body);
    if (data['status'] != 'OK') return null;
    final leg = data['routes'][0]['legs'][0];
    return WalkingResult(
      leg['distance']['value'].toDouble(),
      leg['duration']['value'],
      _decodePolyline(data['routes'][0]['overview_polyline']['points']),
    );
  }

  // New: Geocoding function to get coordinates from place name
  Future<LatLng?> _geocodePlace(String placeName) async {
    final url =
        'https://maps.googleapis.com/maps/api/geocode/json?address=${Uri.encodeComponent(placeName)}&key=$GOOGLE_API_KEY';
    try {
      final response = await http.get(Uri.parse(url));
      final data = jsonDecode(response.body);

      if (data['status'] == 'OK' && data['results'].isNotEmpty) {
        final location = data['results'][0]['geometry']['location'];
        return LatLng(location['lat'], location['lng']);
      }
    } catch (e) {
      print('Geocoding error: $e');
    }
    return null;
  }

  // New: Find nearest stops to a location
  Future<List<StopModel>> _findNearestStops(
    LatLng location, {
    double radiusMeters = 2000,
  }) async {
    final allStops = <StopModel>[];

    // Get all stops from all routes
    for (final route in _routes) {
      final stops = await _routeService.getStopsForRoute(route);
      allStops.addAll(stops);
    }

    // Remove duplicates based on stop ID
    final uniqueStops = <String, StopModel>{};
    for (final stop in allStops) {
      uniqueStops[stop.id] = stop;
    }

    // Filter stops within radius and sort by distance
    final nearbyStops = <StopWithDistance>[];
    for (final stop in uniqueStops.values) {
      final distance = Geolocator.distanceBetween(
        location.latitude,
        location.longitude,
        stop.lat,
        stop.lng,
      );

      if (distance <= radiusMeters) {
        nearbyStops.add(StopWithDistance(stop, distance));
      }
    }

    // Sort by distance and return stops
    nearbyStops.sort((a, b) => a.distance.compareTo(b.distance));
    return nearbyStops.map((swd) => swd.stop).toList();
  }

  Future<void> _searchAndRecommend() async {
    final parts = _searchController.text
        .split(',')
        .map((e) => e.trim())
        .toList();
    final List<StopModel> found = [];
    final List<StopModel> nearbyDestinations = [];

    for (final p in parts) {
      // First, try to find exact matches in the database
      final s = await _routeService.searchStops(p);

      if (s.isNotEmpty) {
        found.add(s.first);
      } else {
        // If not found in database, try geocoding and find nearest stops
        final geocodedLocation = await _geocodePlace(p);
        if (geocodedLocation != null) {
          final nearestStops = await _findNearestStops(geocodedLocation);
          if (nearestStops.isNotEmpty) {
            // Create a virtual destination at the geocoded location
            final virtualDestination = StopModel(
              id: 'virtual_${DateTime.now().millisecondsSinceEpoch}',
              name: p, // Use the search term as the name
              lat: geocodedLocation.latitude,
              lng: geocodedLocation.longitude,
            );
            nearbyDestinations.add(virtualDestination);

            // Add the nearest actual stop as well for route finding
            found.add(nearestStops.first);
          }
        }
      }
    }

    if (found.isEmpty && nearbyDestinations.isEmpty) {
      // Show a message if nothing is found
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No destinations or nearby routes found. Please try a different search term.',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    // Combine found destinations with nearby virtual destinations
    _activeDestinations = [...found, ...nearbyDestinations];

    // Find routes that serve the found stops (not virtual destinations)
    final matchingRoutes = _routes
        .where((r) => found.any((s) => r.stopIds.contains(s.id)))
        .toList();

    // If we have nearby destinations but no exact matches, find routes serving nearby stops
    if (matchingRoutes.isEmpty && nearbyDestinations.isNotEmpty) {
      final Set<String> nearbyRouteIds = {};
      for (final virtualDest in nearbyDestinations) {
        final nearbyStops = await _findNearestStops(
          LatLng(virtualDest.lat, virtualDest.lng),
          radiusMeters: 1000, // Smaller radius for route finding
        );

        for (final nearbyStop in nearbyStops.take(5)) {
          // Consider top 5 nearest stops
          for (final route in _routes) {
            if (route.stopIds.contains(nearbyStop.id)) {
              nearbyRouteIds.add(route.id);
            }
          }
        }
      }

      _filteredRoutes = _routes
          .where((r) => nearbyRouteIds.contains(r.id))
          .toList();
    } else {
      _filteredRoutes = matchingRoutes.isEmpty ? _routes : matchingRoutes;
    }

    await _calculateBestRoute();
    await _addWalkingOption();

    _routeFares.clear();
    for (final route in _filteredRoutes) {
      if (route.id != 'walk') {
        final stops = await _routeService.getStopsForRoute(route);
        _routeFares[route.id] = _calculateFare(route, stops);
      }
    }

    _sortRoutes();

    setState(() {
      _markers.clear();
      // Add markers for all destinations (both exact matches and virtual ones)
      for (final d in _activeDestinations) {
        _markers.add(_createMarker(d, BitmapDescriptor.hueGreen));
      }
    });

    // Show info message if using nearby destinations
    if (nearbyDestinations.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Showing routes near "${nearbyDestinations.map((d) => d.name).join(', ')}" - ${_filteredRoutes.length} routes found',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  // Updated method to calculate walking times to nearest stops and total journey times
  Future<void> _calculateBestRoute() async {
    if (_currentLocation == null) return;

    double bestDistance = double.infinity;
    int bestTotalTime = 999999;
    String? bestId;
    Map<String, double> routeDistances = {};

    // Clear previous calculations
    _walkingTimesToNearestStop.clear();
    _totalJourneyTimes.clear();

    // Calculate for each route
    for (final r in _filteredRoutes) {
      final stops = await _routeService.getStopsForRoute(r);

      // Find nearest stop
      StopModel? nearestStop;
      double nearestStopDistance = double.infinity;

      for (final s in stops) {
        final d = Geolocator.distanceBetween(
          _currentLocation!.latitude,
          _currentLocation!.longitude,
          s.lat,
          s.lng,
        );
        if (d < nearestStopDistance) {
          nearestStopDistance = d;
          nearestStop = s;
        }
      }

      routeDistances[r.id] = nearestStopDistance;

      // Calculate walking time to nearest stop
      if (nearestStop != null) {
        final walkToStop = await _getWalkingRoute(
          _currentLocation!,
          LatLng(nearestStop.lat, nearestStop.lng),
        );

        if (walkToStop != null) {
          final walkMinutes = (walkToStop.durationSeconds / 60).round();
          _walkingTimesToNearestStop[r.id] = walkMinutes;

          // Estimate bus travel time (rough estimate: distance / average bus speed)
          // Assuming average bus speed of 20 km/h in urban areas
          double busDistanceToDestination = 0;
          if (_activeDestinations.isNotEmpty) {
            // Find the destination stop in route stops or nearest stop to virtual destination
            StopModel? destStop;
            for (final activeDestination in _activeDestinations) {
              destStop = stops.firstWhere(
                (stop) => stop.id == activeDestination.id,
                orElse: () => _findNearestStopInRoute(stops, activeDestination),
              );
              if (destStop != null) break;
            }

            if (destStop != null) {
              // Calculate approximate bus travel distance
              busDistanceToDestination = Geolocator.distanceBetween(
                nearestStop.lat,
                nearestStop.lng,
                destStop.lat,
                destStop.lng,
              );
            }
          }

          // Estimate bus time (distance in meters / speed in m/s)
          // 20 km/h = ~5.56 m/s
          final busTimeMinutes = (busDistanceToDestination / (20 * 1000 / 60))
              .round();
          final totalTime =
              walkMinutes + busTimeMinutes + 5; // +5 for waiting time

          _totalJourneyTimes[r.id] = totalTime;

          if (totalTime < bestTotalTime) {
            bestTotalTime = totalTime;
            bestId = r.id;
          }
        }
      }

      // For distance-based comparison (backup)
      if (nearestStopDistance < bestDistance) {
        bestDistance = nearestStopDistance;
        if (bestId == null) bestId = r.id;
      }
    }

    // Compare with walking
    final walkDist = await _getWalkingDistanceToNearestDestination();
    if (walkDist != null && _walkDurationMinutes != null) {
      _totalJourneyTimes['walk'] = _walkDurationMinutes!;

      if (_walkDurationMinutes! <= bestTotalTime) {
        _bestRouteId = 'walk';
      } else {
        _bestRouteId = bestId;
      }
    } else {
      _bestRouteId = bestId;
    }

    _sortRoutes(routeDistances);
    setState(() {});
  }

  // Helper method to find nearest stop in a route to a virtual destination
  StopModel _findNearestStopInRoute(
    List<StopModel> routeStops,
    StopModel destination,
  ) {
    StopModel nearestStop = routeStops.first;
    double nearestDistance = double.infinity;

    for (final stop in routeStops) {
      final distance = Geolocator.distanceBetween(
        destination.lat,
        destination.lng,
        stop.lat,
        stop.lng,
      );

      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestStop = stop;
      }
    }

    return nearestStop;
  }

  void _sortRoutes([Map<String, double>? precomputedDistances]) {
    if (_sortOption == 'Cost') {
      _filteredRoutes.sort((a, b) {
        if (a.id == 'walk') return 1;
        if (b.id == 'walk') return -1;
        final aCost =
            _routeFares[a.id]?.values.reduce((x, y) => x < y ? x : y) ?? 9999;
        final bCost =
            _routeFares[b.id]?.values.reduce((x, y) => x < y ? x : y) ?? 9999;
        return aCost.compareTo(bCost);
      });
      if (_filteredRoutes.isNotEmpty) _bestRouteId = _filteredRoutes.first.id;
    } else if (_sortOption == 'Distance') {
      _filteredRoutes.sort((a, b) {
        if (_currentLocation == null) return 0;
        if (a.id == 'walk') return 1;
        if (b.id == 'walk') return -1;
        final aDist = precomputedDistances?[a.id] ?? double.infinity;
        final bDist = precomputedDistances?[b.id] ?? double.infinity;
        return aDist.compareTo(bDist);
      });
      if (_filteredRoutes.isNotEmpty) _bestRouteId = _filteredRoutes.first.id;
    } else if (_sortOption == 'Time') {
      // New: Sort by total travel time
      _filteredRoutes.sort((a, b) {
        final aTime = _totalJourneyTimes[a.id] ?? 999999;
        final bTime = _totalJourneyTimes[b.id] ?? 999999;
        return aTime.compareTo(bTime);
      });
      if (_filteredRoutes.isNotEmpty) {
        // Set best route based on shortest time
        final shortestTime =
            _totalJourneyTimes[_filteredRoutes.first.id] ?? 999999;
        _bestRouteId = _filteredRoutes.first.id;
      }
    }
  }

  Future<double?> _getWalkingDistanceToNearestDestination() async {
    if (_currentLocation == null || _activeDestinations.isEmpty) return null;
    final walk = await _getWalkingRoute(
      _currentLocation!,
      LatLng(_activeDestinations.first.lat, _activeDestinations.first.lng),
    );
    if (walk != null)
      _walkDurationMinutes = (walk.durationSeconds / 60).round();
    return walk?.distanceMeters;
  }

  Future<void> _addWalkingOption() async {
    _walkRoute = RouteModel(
      id: 'walk',
      name: 'Walk',
      vehicle: _walkDurationMinutes != null
          ? '🚶 Walk - $_walkDurationMinutes min'
          : '🚶 Walk',
      stopIds: [],
    );
    if (!_filteredRoutes.any((r) => r.id == 'walk')) {
      _filteredRoutes.insert(0, _walkRoute!);
    }
  }

  Map<String, int> _calculateFare(RouteModel route, List<StopModel> stops) {
    Map<String, int> fares = {};
    for (final dest in _activeDestinations) {
      int index = stops.indexWhere((s) => s.id == dest.id);
      if (index == -1) continue;
      double distance = 0;
      for (int i = 1; i < index; i++) {
        distance += Geolocator.distanceBetween(
          stops[i].lat,
          stops[i].lng,
          stops[i + 1].lat,
          stops[i + 1].lng,
        );
      }
      int cost = 20;
      if (distance > 0) {
        cost += ((distance / 5000).ceil()) * 5;
      }
      fares[dest.name] = cost;
    }
    return fares;
  }

  Future<void> _showRoute(RouteModel route) async {
    if (_currentLocation == null) return;

    List<StopModel> stops = [];
    if (route.id != 'walk') stops = await _routeService.getStopsForRoute(route);

    StopModel? nearestStop;
    double nearestDistance = double.infinity;
    for (final s in stops) {
      final d = Geolocator.distanceBetween(
        _currentLocation!.latitude,
        _currentLocation!.longitude,
        s.lat,
        s.lng,
      );
      if (d < nearestDistance) {
        nearestDistance = d;
        nearestStop = s;
      }
    }

    if (route.id != 'walk' && nearestStop != null) {
      final walk = await _getWalkingRoute(
        _currentLocation!,
        LatLng(nearestStop.lat, nearestStop.lng),
      );
      if (walk != null) {
        setState(() {
          _polylines.clear();
          _polylines.add(
            Polyline(
              polylineId: const PolylineId('walkToStop'),
              points: walk.points,
              color: Colors.green,
              width: 5,
            ),
          );
        });
      }
    }

    if (route.id == 'walk') {
      if (_activeDestinations.isEmpty) return;
      final walk = await _getWalkingRoute(
        _currentLocation!,
        LatLng(_activeDestinations.first.lat, _activeDestinations.first.lng),
      );
      if (walk == null) return;
      setState(() {
        _polylines.clear();
        _polylines.add(
          Polyline(
            polylineId: const PolylineId('walk'),
            points: walk.points,
            color: Colors.green,
            width: 5,
          ),
        );
        _markers.clear();
        _markers.add(
          _createMarker(_activeDestinations.first, BitmapDescriptor.hueGreen),
        );
      });
      return;
    }

    final destIds = _activeDestinations.map((e) => e.id).toSet();
    setState(() {
      _markers.clear();
      for (final s in stops) {
        _markers.add(
          _createMarker(
            s,
            destIds.contains(s.id)
                ? BitmapDescriptor.hueViolet
                : BitmapDescriptor.hueRed,
          ),
        );
      }
      for (final d in _activeDestinations) {
        _markers.add(_createMarker(d, BitmapDescriptor.hueGreen));
      }
    });

    final List<LatLng> full = [];
    for (int i = 0; i < stops.length - 1; i++) {
      full.addAll(
        await _getDrivingRoute(
          LatLng(stops[i].lat, stops[i].lng),
          LatLng(stops[i + 1].lat, stops[i + 1].lng),
        ),
      );
    }

    setState(() {
      _polylines.add(
        Polyline(
          polylineId: PolylineId(route.id),
          points: full,
          color: Colors.blue,
          width: 5,
        ),
      );
    });
  }

  Marker _createMarker(StopModel s, double hue) => Marker(
    markerId: MarkerId('${s.id}-$hue'),
    position: LatLng(s.lat, s.lng),
    infoWindow: InfoWindow(title: s.name),
    icon: BitmapDescriptor.defaultMarkerWithHue(hue),
  );

  Future<void> _goHome() async {
    if (_currentLocation == null || _mapController == null) return;
    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _currentLocation!, zoom: 14),
      ),
    );
  }

  void _zoomIn() => _mapController?.animateCamera(CameraUpdate.zoomIn());
  void _zoomOut() => _mapController?.animateCamera(CameraUpdate.zoomOut());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search destinations (comma separated)',
            suffixIcon: IconButton(
              icon: const Icon(Icons.search),
              onPressed: _searchAndRecommend,
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: LatLng(27.7172, 85.3240),
              zoom: 13,
            ),
            myLocationEnabled: true,
            markers: _markers,
            polylines: _polylines,
            onMapCreated: (c) => _mapController = c,
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 220,
            child: Column(
              children: [
                // Updated Dropdown with Time option
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      const Text('Sort by: '),
                      DropdownButton<String>(
                        value: _sortOption,
                        items: const [
                          DropdownMenuItem(
                            value: 'Distance',
                            child: Text('Distance'),
                          ),
                          DropdownMenuItem(value: 'Cost', child: Text('Cost')),
                          DropdownMenuItem(value: 'Time', child: Text('Time')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _sortOption = value;
                              _sortRoutes();
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Container(
                    color: Colors.white,
                    child: ListView.builder(
                      itemCount: _filteredRoutes.length,
                      itemBuilder: (_, i) {
                        final r = _filteredRoutes[i];
                        final isBest = r.id == _bestRouteId;
                        final fares = _routeFares[r.id] ?? {};
                        final fareText = fares.entries
                            .map((e) => '${e.key}: Rs.${e.value}')
                            .join(', ');

                        // Get timing information
                        final walkToStopTime = _walkingTimesToNearestStop[r.id];
                        final totalTime = _totalJourneyTimes[r.id];

                        String timingInfo = '';
                        if (r.id == 'walk') {
                          timingInfo = totalTime != null
                              ? ' - ${totalTime}min total'
                              : '';
                        } else {
                          if (walkToStopTime != null && totalTime != null) {
                            timingInfo =
                                ' - ${walkToStopTime}min walk + ${totalTime - walkToStopTime - 5}min bus = ${totalTime}min total';
                          }
                        }

                        return ListTile(
                          title: Row(
                            children: [
                              Expanded(child: Text(r.name)),
                              if (isBest)
                                Container(
                                  margin: const EdgeInsets.only(left: 8),
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.green,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    "BEST",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Text(
                            '${r.vehicle}${fareText.isNotEmpty ? ' - $fareText' : ''}$timingInfo',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                          onTap: () => _showRoute(r),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 20,
            right: 12,
            child: Column(
              children: [
                FloatingActionButton(
                  mini: true,
                  heroTag: "home",
                  onPressed: _goHome,
                  child: const Icon(Icons.my_location),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  mini: true,
                  heroTag: "zoomIn",
                  onPressed: _zoomIn,
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  mini: true,
                  heroTag: "zoomOut",
                  onPressed: _zoomOut,
                  child: const Icon(Icons.remove),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class WalkingResult {
  final double distanceMeters;
  final int durationSeconds;
  final List<LatLng> points;

  WalkingResult(this.distanceMeters, this.durationSeconds, this.points);
}

// Helper class for storing stops with their distances
class StopWithDistance {
  final StopModel stop;
  final double distance;

  StopWithDistance(this.stop, this.distance);
}
