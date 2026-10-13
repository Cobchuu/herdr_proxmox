import 'package:jaspr/client.dart';
import 'package:herdr_jaspr_dashboard/app.dart';
import 'package:herdr_jaspr_dashboard/services.dart';

void main() {
  Jaspr.initializeApp();
  initializeServices();
  runApp(const DashboardApp());
}
