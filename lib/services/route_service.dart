import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/route_model.dart';
import '../models/stop_model.dart';

class RouteService {
  late Map<String, StopModel> _stops;
  late List<RouteModel> _routes;

  RouteService() {
    _stops = {};
    _routes = [];
    _loadJson();
  }

  Future<void> _loadJson() async {
    final data = await rootBundle.loadString(
      'assets/kathmandu_transport_firestore.json',
    );
    final jsonData = jsonDecode(data);

    // LOAD STOPS
    final stopsJson = jsonData['stops'] as Map<String, dynamic>;
    _stops = stopsJson.map(
      (key, value) => MapEntry(
        key,
        StopModel(
          id: key,
          name: value['name'],
          lat: (value['lat'] as num).toDouble(),
          lng: (value['lng'] as num).toDouble(),
        ),
      ),
    );

    // LOAD ROUTES
    final routesJson = jsonData['routes'] as Map<String, dynamic>;
    _routes = routesJson.entries.map((e) {
      final r = e.value;
      final stopIds = List<String>.from(r['stopIds']);
      return RouteModel(
        id: e.key,
        name: e.key,
        vehicle: r['vehicleType'],
        stopIds: stopIds,
      );
    }).toList();
  }

  // RETURN ALL ROUTES
  Future<List<RouteModel>> getAllRoutes() async {
    if (_routes.isEmpty) await _loadJson();
    return _routes;
  }

  // RETURN STOPS FOR A ROUTE
  Future<List<StopModel>> getStopsForRoute(RouteModel route) async {
    if (_stops.isEmpty) await _loadJson();
    return route.stopIds
        .map((id) => _stops[id])
        .whereType<StopModel>()
        .toList();
  }

  // SEARCH STOPS BY NAME (contains)
  Future<List<StopModel>> searchStops(String query) async {
    if (_stops.isEmpty) await _loadJson();
    return _stops.values
        .where((s) => s.name.toLowerCase().contains(query.toLowerCase()))
        .toList();
  }
}
