import 'package:flutter/material.dart';

import 'app.dart';
import 'services/app_config_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await AppConfig.load();
  runApp(CfmsApp(config: config));
}
