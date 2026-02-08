class RouteModel {
  final String id;
  final String name;
  final String vehicle;
  final List<String> stopIds;
  final double? cost; // add this field

  RouteModel({
    required this.id,
    required this.name,
    required this.vehicle,
    required this.stopIds,
    this.cost,
  });

  factory RouteModel.fromFirestore(String id, Map<String, dynamic> data) {
    return RouteModel(
      id: id,
      name: data['name'] ?? 'Unnamed Route',
      vehicle: data['vehicle'] ?? '',
      stopIds: List<String>.from(data['stopIds'] ?? []),
    );
  }
}
