import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../models/route_model.dart';
import '../models/stop_model.dart';
import '../services/route_service.dart';

const String GOOGLE_API_KEY = 'AIzaSyBVEoTUtT7P_OA2hRE-T-YbcOJtQLuprb4';

class WalkingResult {
  final double distanceMeters;
  final int durationSeconds;
  final List<LatLng> points;

  WalkingResult(this.distanceMeters, this.durationSeconds, this.points);
}

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

  StopModel? _activeDestination;
  LatLng? _currentLocation;

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

  // ================= POLYLINE DECODER =================

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

  // ================= WALKING =================

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

  // ================= DRIVING =================

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

  // ================= SEARCH =================

  Future<void> _searchAndRecommend() async {
    if (_currentLocation == null) return;

    final stops = await _routeService.searchStops(_searchController.text);
    if (stops.isEmpty) return;

    _activeDestination = stops.first;

    final candidates = _routes
        .where((r) => r.stopIds.contains(stops.first.id))
        .toList();

    final recommended = await _recommendRoutesWithWalking(candidates, stops);

    setState(() {
      _filteredRoutes = recommended;
      _markers.clear();
      _markers.add(_createMarker(_activeDestination!, true));
    });
  }

  // ================= ROUTE RANKING =================

  Future<List<RouteModel>> _recommendRoutesWithWalking(
    List<RouteModel> routes,
    List<StopModel> destinations,
  ) async {
    if (_currentLocation == null) return routes;

    final scored = <MapEntry<RouteModel, double>>[];

    double nearestStopWalk = double.infinity;

    for (final r in routes) {
      final stops = await _routeService.getStopsForRoute(r);
      if (stops.isEmpty) continue;

      stops.sort((a, b) {
        final d1 = Geolocator.distanceBetween(
          _currentLocation!.latitude,
          _currentLocation!.longitude,
          a.lat,
          a.lng,
        );

        final d2 = Geolocator.distanceBetween(
          _currentLocation!.latitude,
          _currentLocation!.longitude,
          b.lat,
          b.lng,
        );

        return d1.compareTo(d2);
      });

      final nearest = stops.first;

      final walkToStop = Geolocator.distanceBetween(
        _currentLocation!.latitude,
        _currentLocation!.longitude,
        nearest.lat,
        nearest.lng,
      );

      if (walkToStop < nearestStopWalk) nearestStopWalk = walkToStop;

      final destDist = Geolocator.distanceBetween(
        nearest.lat,
        nearest.lng,
        destinations.first.lat,
        destinations.first.lng,
      );

      scored.add(MapEntry(r, walkToStop + destDist));
    }

    final walk = await _getWalkingRoute(
      _currentLocation!,
      LatLng(destinations.first.lat, destinations.first.lng),
    );

    if (walk != null) {
      final walkRoute = RouteModel(
        id: 'walk',
        name: 'Walk',
        vehicle: '🚶 ${(walk.durationSeconds / 60).round()} min',
        stopIds: [],
      );

      scored.add(MapEntry(walkRoute, walk.distanceMeters));

      if (walk.distanceMeters <= nearestStopWalk) {
        scored.sort((a, b) {
          if (a.key.id == 'walk') return -1;
          if (b.key.id == 'walk') return 1;
          return a.value.compareTo(b.value);
        });

        return scored.map((e) => e.key).toList();
      }
    }

    scored.sort((a, b) => a.value.compareTo(b.value));
    return scored.map((e) => e.key).toList();
  }

  // ================= SHOW STOPS =================

  void _showAllStops(List<StopModel> stops) {
    setState(() {
      _markers.clear();

      if (_activeDestination != null) {
        _markers.add(_createMarker(_activeDestination!, true));
      }

      for (final s in stops) {
        _markers.add(_createMarker(s, false));
      }
    });
  }

  // ================= SHOW ROUTE =================

  Future<void> _showRoute(RouteModel route) async {
    if (_currentLocation == null || _activeDestination == null) return;

    if (route.id == 'walk') {
      final walk = await _getWalkingRoute(
        _currentLocation!,
        LatLng(_activeDestination!.lat, _activeDestination!.lng),
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
      });

      return;
    }

    final stops = await _routeService.getStopsForRoute(route);
    if (stops.length < 2) return;

    _showAllStops(stops);

    final List<LatLng> full = [];

    for (int i = 0; i < stops.length - 1; i++) {
      final part = await _getDrivingRoute(
        LatLng(stops[i].lat, stops[i].lng),
        LatLng(stops[i + 1].lat, stops[i + 1].lng),
      );
      full.addAll(part);
    }

    setState(() {
      _polylines.clear();
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

  Marker _createMarker(StopModel s, bool dest) => Marker(
    markerId: MarkerId(s.id),
    position: LatLng(s.lat, s.lng),
    icon: BitmapDescriptor.defaultMarkerWithHue(
      dest ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueRed,
    ),
  );

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search destination',
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
            height: 180,
            child: Container(
              color: Colors.white,
              child: ListView.builder(
                itemCount: _filteredRoutes.length,
                itemBuilder: (_, i) {
                  final r = _filteredRoutes[i];
                  return ListTile(
                    title: Row(
                      children: [
                        Text(r.name),
                        if (i == 0)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.all(4),
                            color: Colors.green,
                            child: const Text(
                              'BEST',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                    subtitle: Text(r.vehicle),
                    onTap: () => _showRoute(r),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
