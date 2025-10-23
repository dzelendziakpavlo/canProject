import 'package:equatable/equatable.dart';
import '../../domain/models/can_frame.dart';

/// CAN Frame Events для BLoC архітектури
abstract class CanFrameEvent extends Equatable {
  const CanFrameEvent();

  @override
  List<Object> get props => [];
}

/// Подія початку моніторингу CAN frames
class StartMonitoring extends CanFrameEvent {
  const StartMonitoring();
}

/// Подія зупинки моніторингу CAN frames
class StopMonitoring extends CanFrameEvent {
  const StopMonitoring();
}

/// Подія скидання всієї статистики та історії
class ResetMonitoring extends CanFrameEvent {
  const ResetMonitoring();
}

/// Подія отримання нового CAN frame
class FrameReceived extends CanFrameEvent {
  final CanFrame frame;

  const FrameReceived(this.frame);

  @override
  List<Object> get props => [frame];
}

/// Подія зміни конфігурації симулятора
class UpdateSimulatorConfig extends CanFrameEvent {
  final double? errorRate;
  final int? frameRate;
  final bool? enableAdvancedErrors;

  const UpdateSimulatorConfig({
    this.errorRate,
    this.frameRate,
    this.enableAdvancedErrors,
  });

  @override
  List<Object> get props => [
    errorRate ?? 0.0,
    frameRate ?? 0,
    enableAdvancedErrors ?? false,
  ];
}

/// Подія генерації custom frame
class GenerateCustomFrame extends CanFrameEvent {
  final int? id;
  final int? dlc;
  final List<int>? data;
  final bool? isCorrupted;

  const GenerateCustomFrame({
    this.id,
    this.dlc,
    this.data,
    this.isCorrupted,
  });

  @override
  List<Object> get props => [
    id ?? 0,
    dlc ?? 0,
    data ?? [],
    isCorrupted ?? false,
  ];
}

/// Подія вибору frame для детального перегляду
class SelectFrame extends CanFrameEvent {
  final CanFrame? frame;

  const SelectFrame(this.frame);

  @override
  List<Object> get props => [frame ?? ''];
}

/// Подія експорту статистики
class ExportStatistics extends CanFrameEvent {
  final String format; // 'json', 'csv', 'xml'

  const ExportStatistics(this.format);

  @override
  List<Object> get props => [format];
}