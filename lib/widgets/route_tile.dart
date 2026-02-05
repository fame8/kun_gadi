import 'package:flutter/material.dart';
import '../models/route_model.dart';

class RouteTile extends StatelessWidget {
  final RouteModel route;
  final VoidCallback onTap; // ADD THIS

  const RouteTile({super.key, required this.route, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(route.name),
      subtitle: Text(route.vehicle),
      onTap: onTap, // THIS triggers polyline/directions
    );
  }
}
