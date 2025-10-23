import 'package:get_it/get_it.dart';

import '../domain/simulator/can_frame_simulator.dart';
import '../domain/detection/can_error_checker.dart';
import '../data/database_helper.dart';
import '../presentation/bloc/can_frame_bloc.dart';

/// Service Locator instance
final GetIt getIt = GetIt.instance;

/// Manual dependency registration
void setupServiceLocator() {
  // Core services
  getIt.registerLazySingleton<DatabaseHelper>(() => DatabaseHelper.instance);
  
  // Domain services
  getIt.registerFactory<CanFrameSimulator>(() => CanFrameSimulator());
  getIt.registerFactory<CanErrorChecker>(() => CanErrorChecker());
  
  // BLoCs
  getIt.registerFactory<CanFrameBloc>(() => CanFrameBloc(
    simulator: getIt<CanFrameSimulator>(),
    errorChecker: getIt<CanErrorChecker>(),
  ));
}

/// Initialize all dependencies
Future<void> initializeDependencies() async {
  // Setup service locator
  setupServiceLocator();
  
  // Initialize database
  final dbHelper = getIt<DatabaseHelper>();
  await dbHelper.database; // This will create the database if it doesn't exist
}

/// Clean up resources
Future<void> disposeDependencies() async {
  // Close database
  final dbHelper = getIt<DatabaseHelper>();
  await dbHelper.close();
  
  // Reset GetIt
  await getIt.reset();
}