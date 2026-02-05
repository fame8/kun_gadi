import 'dart:math';
import '../models/stop.dart';
import '../models/transport_route.dart';

double _distance(double lat1, double lng1, double lat2, double lng2) {
  const double r = 6371;
  final double dLat = (lat2 - lat1) * pi / 180;
  final double dLng = (lng2 - lng1) * pi / 180;

  final double a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) *
          cos(lat2 * pi / 180) *
          sin(dLng / 2) *
          sin(dLng / 2);

  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

Stop nearestStop(double lat, double lng, List<Stop> stops) {
  stops.sort(
    (a, b) => _distance(
      lat,
      lng,
      a.lat,
      a.lng,
    ).compareTo(_distance(lat, lng, b.lat, b.lng)),
  );
  return stops.first;
}

Map<String, List<TransportRoute>> findRoutesForDestinations({
  required Stop userStop,
  required List<Stop> destinationStops,
  required List<TransportRoute> allRoutes,
}) {
  final Map<String, List<TransportRoute>> results = {};

  for (final Stop dest in destinationStops) {
    results[dest.name] = allRoutes.where((route) {
      final int startIndex = route.stops.indexOf(userStop.id);
      final int endIndex = route.stops.indexOf(dest.id);
      return startIndex != -1 && endIndex != -1 && startIndex < endIndex;
    }).toList();
  }

  return results;
}
