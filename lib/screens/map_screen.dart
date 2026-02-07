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

  // New: sorting option
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

  Future<void> _searchAndRecommend() async {
    final parts = _searchController.text
        .split(',')
        .map((e) => e.trim())
        .toList();
    final List<StopModel> found = [];
    for (final p in parts) {
      final s = await _routeService.searchStops(p);
      if (s.isNotEmpty) found.add(s.first);
    }
    if (found.isEmpty) return;

    _activeDestinations = found;

    final matchingRoutes = _routes
        .where((r) => found.every((s) => r.stopIds.contains(s.id)))
        .toList();

    _filteredRoutes = matchingRoutes.isEmpty ? _routes : matchingRoutes;

    await _calculateBestRoute();
    await _addWalkingOption();

    _routeFares.clear();
    for (final route in _filteredRoutes) {
      if (route.id != 'walk') {
        final stops = await _routeService.getStopsForRoute(route);
        _routeFares[route.id] = _calculateFare(route, stops);
      }
    }

    _sortRoutes(); // sort according to selected option

    setState(() {
      _markers.clear();
      for (final d in found) {
        _markers.add(_createMarker(d, BitmapDescriptor.hueGreen));
      }
    });
  }

  // ---------- FIXED BEST ROUTE LOGIC ----------

  Future<void> _calculateBestRoute() async {
    if (_currentLocation == null) return;

    double bestDistance = double.infinity;
    String? bestId;
    Map<String, double> routeDistances = {};

    // Precompute nearest stop distance for each route
    for (final r in _filteredRoutes) {
      final stops = await _routeService.getStopsForRoute(r);
      double nearestStopDistance = double.infinity;
      for (final s in stops) {
        final d = Geolocator.distanceBetween(
          _currentLocation!.latitude,
          _currentLocation!.longitude,
          s.lat,
          s.lng,
        );
        if (d < nearestStopDistance) nearestStopDistance = d;
      }
      routeDistances[r.id] = nearestStopDistance;
      if (nearestStopDistance < bestDistance) {
        bestDistance = nearestStopDistance;
        bestId = r.id;
      }
    }

    final walkDist = await _getWalkingDistanceToNearestDestination();
    if (walkDist != null && walkDist <= bestDistance) {
      _bestRouteId = 'walk';
    } else {
      _bestRouteId = bestId;
    }

    _sortRoutes(routeDistances); // pass distances for sorting

    setState(() {});
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
        if (a.id == 'walk') return 1; // walk last
        if (b.id == 'walk') return -1;
        final aDist = precomputedDistances?[a.id] ?? double.infinity;
        final bDist = precomputedDistances?[b.id] ?? double.infinity;
        return aDist.compareTo(bDist);
      });
      if (_filteredRoutes.isNotEmpty) _bestRouteId = _filteredRoutes.first.id;
    }
  }

  // ---------- END OF FIX ----------

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
                // Dropdown
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

                        return ListTile(
                          title: Row(
                            children: [
                              Text(r.name),
                              if (isBest)
                                Container(
                                  margin: const EdgeInsets.only(left: 8),
                                  padding: const EdgeInsets.all(4),
                                  color: Colors.green,
                                  child: const Text(
                                    "BEST",
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Text(
                            '${r.vehicle}${fareText.isNotEmpty ? ' - $fareText' : ''}',
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
