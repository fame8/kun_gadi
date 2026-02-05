import 'package:cloud_firestore/cloud_firestore.dart';

class StopModel {
  final String id;
  final String name;
  final double lat;
  final double lng;

  StopModel({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
  });

  factory StopModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return StopModel(
      id: doc.id,
      name: data['name'] ?? '',
      lat: (data['lat'] as num).toDouble(),
      lng: (data['lng'] as num).toDouble(),
    );
  }
}
