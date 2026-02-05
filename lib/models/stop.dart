class Stop {
  final String id;
  final String name;
  final double lat;
  final double lng;

  Stop({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
  });

  factory Stop.fromMap(Map<String, dynamic> data, String id) {
    return Stop(
      id: id,
      name: data['name'] as String,
      lat: (data['lat'] as num).toDouble(),
      lng: (data['lng'] as num).toDouble(),
    );
  }
}
