class TransportRoute {
  final String id;
  final String vehicle;
  final String name;
  final List<String> stops;

  TransportRoute({
    required this.id,
    required this.vehicle,
    required this.name,
    required this.stops,
  });

  factory TransportRoute.fromMap(Map<String, dynamic> data, String id) {
    return TransportRoute(
      id: id,
      vehicle: data['vehicle'] as String,
      name: data['name'] as String,
      stops: List<String>.from(data['stops']),
    );
  }
}
