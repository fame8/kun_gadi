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

  factory RouteModel.fromJson(Map<String, dynamic> json) {
    return RouteModel(
      id: json['id'],
      name: json['name'],
      vehicle: json['vehicle'],
      stopIds: List<String>.from(json['stopIds']),
      cost: json['cost']?.toDouble(),
    );
  }
}
