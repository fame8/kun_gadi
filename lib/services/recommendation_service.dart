import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/route_model.dart';
import '../models/stop_model.dart';
import '../services/route_service.dart';

const String GOOGLE_API_KEY = 'API KEY HERE';

class RecommendationService {
  final RouteService _routeService = RouteService();

  // Fetch directions and calculate distance in meters
  Future<double> _calculateDistance(List<StopModel> stops) async {
    if (stops.length < 2) return 0;

    final origin = '${stops.first.lat},${stops.first.lng}';
    final destination = '${stops.last.lat},${stops.last.lng}';
    String waypoints = '';
    if (stops.length > 2) {
      waypoints = stops
          .sublist(1, stops.length - 1)
          .map((s) => '${s.lat},${s.lng}')
          .join('|');
    }

    final url =
        'https://maps.googleapis.com/maps/api/directions/json?origin=$origin&destination=$destination&waypoints=$waypoints&mode=driving&key=$GOOGLE_API_KEY';

    final res = await http.get(Uri.parse(url));
    final data = jsonDecode(res.body);

    if (data['status'] != 'OK') return double.infinity;

    // Sum distance of all legs
    double distance = 0;
    for (var leg in data['routes'][0]['legs']) {
      distance += leg['distance']['value']; // meters
    }
    return distance;
  }

  // Recommend routes given origin and destination
  Future<List<Map<String, dynamic>>> recommendRoutes(
    StopModel origin,
    StopModel destination, {
    double costWeight = 0.5,
    double distanceWeight = 0.5,
  }) async {
    // 1. Get all routes that include origin and destination
    final allRoutes = await _routeService.getAllRoutes();
    final matchingRoutes = <RouteModel>[];

    for (final route in allRoutes) {
      final stops = await _routeService.getStopsForRoute(route);
      final stopIds = stops.map((s) => s.id).toList();
      if (stopIds.contains(origin.id) && stopIds.contains(destination.id)) {
        matchingRoutes.add(route);
      }
    }

    // 2. Calculate distance and cost score for each route
    final results = <Map<String, dynamic>>[];

    for (final route in matchingRoutes) {
      final stops = await _routeService.getStopsForRoute(route);

      // Only consider stops between origin and destination
      final originIndex = stops.indexWhere((s) => s.id == origin.id);
      final destIndex = stops.indexWhere((s) => s.id == destination.id);
      final segmentStops = originIndex < destIndex
          ? stops.sublist(originIndex, destIndex + 1)
          : stops.sublist(destIndex, originIndex + 1);

      final distance = await _calculateDistance(segmentStops); // meters
      final cost = route.cost ?? 20; // fallback cost if not defined

      // Weighted score
      final score = (distance * distanceWeight) + (cost * costWeight);

      results.add({
        'route': route,
        'stops': segmentStops,
        'distance': distance,
        'cost': cost,
        'score': score,
      });
    }

    // Sort by score (lower is better)
    results.sort((a, b) => a['score'].compareTo(b['score']));

    return results;
  }
}
