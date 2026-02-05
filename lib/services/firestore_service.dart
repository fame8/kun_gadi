import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/stop_model.dart';
import '../models/route_model.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<List<StopModel>> getStopsForRoute(RouteModel route) async {
    final List<StopModel> stops = [];

    for (String stopId in route.stopIds) {
      final doc = await _db.collection('stops').doc(stopId).get();
      if (doc.exists) {
        stops.add(StopModel.fromFirestore(doc));
      }
    }

    return stops;
  }
}
