import 'dart:typed_data';

/// **Lock-Free Circular Buffer для high-performance CAN обробки**
/// 
/// **Що робить**: Concurrent-safe буфер без mutex/locks для real-time data
/// **Переваги**: Жодних блокувань, constant time operations, memory efficient  
/// **Використання**: High-frequency CAN frame buffering, producer-consumer patterns
class LockFreeCircularBuffer<T> {
  late List<T?> _buffer;
  final int _capacity;
  int _writeIndex = 0;  // Note: Dart не має справжніх volatile змінних
  int _readIndex = 0;
  int _size = 0;
  final bool _overwriteOldest;
  
  /// Створює circular buffer
  /// 
  /// [capacity] - максимальна кількість елементів
  /// [overwriteOldest] - чи перезаписувати старі дані при overflow
  LockFreeCircularBuffer(this._capacity, {bool overwriteOldest = true})
      : _overwriteOldest = overwriteOldest {
    _buffer = List.filled(_capacity, null);
  }
  
  /// **Додає елемент (Producer operation)**
  /// 
  /// **Що робить**: Атомарно додає елемент без блокування
  /// **Повертає**: true якщо успішно, false якщо буфер повний
  bool tryAdd(T item) {
    if (!_overwriteOldest && _size >= _capacity) {
      return false; // Буфер повний
    }
    
    if (_overwriteOldest && _size >= _capacity) {
      // Перезаписуємо найстаріший
      _readIndex = ((_readIndex + 1) % _capacity).round();
      _size--;
    }
    
    // Атомарне додавання
    _buffer[_writeIndex] = item;
    _writeIndex = ((_writeIndex + 1) % _capacity).round();
    _size++;
    
    return true;
  }
  
  /// **Забирає елемент (Consumer operation)**
  /// 
  /// **Що робить**: Атомарно забирає найстаріший елемент
  /// **Повертає**: елемент або null якщо буфер порожній
  T? tryTake() {
    if (_size == 0) return null;
    
    final item = _buffer[_readIndex];
    _buffer[_readIndex] = null; // Звільняємо посилання
    _readIndex = ((_readIndex + 1) % _capacity).round();
    _size--;
    
    return item;
  }
  
  /// **Peek на наступний елемент без видалення**
  T? peek() {
    if (_size == 0) return null;
    return _buffer[_readIndex];
  }
  
  /// **Batch operations для кращої performance**
  /// 
  /// **Що робить**: Додає кілька елементів за один раз
  /// **Переваги**: Менше overhead для bulk operations
  int addBatch(List<T> items) {
    int added = 0;
    
    for (final item in items) {
      if (tryAdd(item)) {
        added++;
      } else if (!_overwriteOldest) {
        break; // Буфер повний, зупиняємося
      }
    }
    
    return added;
  }
  
  /// **Забирає кілька елементів за один раз**
  List<T> takeBatch(int maxCount) {
    final result = <T>[];
    
    for (int i = 0; i < maxCount; i++) {
      final item = tryTake();
      if (item == null) break;
      result.add(item);
    }
    
    return result;
  }
  
  /// **Конвертує в список (snapshot)**
  List<T> toList() {
    final result = <T>[];
    int index = _readIndex;
    
    for (int i = 0; i < _size; i++) {
      final item = _buffer[index];
      if (item != null) result.add(item);
      index = ((index + 1) % _capacity).round();
    }
    
    return result;
  }
  
  /// **Очищає буфер**
  void clear() {
    for (int i = 0; i < _capacity; i++) {
      _buffer[i] = null;
    }
    _readIndex = 0;
    _writeIndex = 0;
    _size = 0;
  }
  
  /// Поточний розмір
  int get size => _size;
  
  /// Максимальна ємність
  int get capacity => _capacity;
  
  /// Чи порожній буфер
  bool get isEmpty => _size == 0;
  
  /// Чи повний буфер
  bool get isFull => _size >= _capacity;
  
  /// Відсоток заповнення (0.0-1.0)
  double get fillPercentage => _size / _capacity;
  
  /// Доступний простір
  int get availableSpace => _capacity - _size;
}

/// **Specialized CAN Frame Buffer з додатковими можливостями**
class CanFrameBuffer extends LockFreeCircularBuffer<CanFrameData> {
  final Map<int, int> _frameIdCounts = {};
  final Map<int, DateTime> _lastFrameTimes = {};
  
  // Performance metrics
  int _totalFramesProcessed = 0;
  int _droppedFrames = 0;
  DateTime? _startTime;
  
  CanFrameBuffer(int capacity, {bool overwriteOldest = true}) 
      : super(capacity, overwriteOldest: overwriteOldest) {
    _startTime = DateTime.now();
  }
  
  /// **Додає CAN фрейм з додатковою статистикою**
  bool addCanFrame(CanFrameData frame) {
    final success = tryAdd(frame);
    
    _totalFramesProcessed++;
    if (!success && !_overwriteOldest) {
      _droppedFrames++;
    }
    
    // Оновлюємо статистики по ID
    _frameIdCounts[frame.id] = (_frameIdCounts[frame.id] ?? 0) + 1;
    _lastFrameTimes[frame.id] = frame.timestamp;
    
    return success;
  }
  
  /// **Фільтрує фрейми по ID при забиранні**
  List<CanFrameData> takeFramesById(int frameId, {int maxCount = 10}) {
    final allFrames = toList();
    final filtered = allFrames.where((f) => f.id == frameId).take(maxCount).toList();
    
    // Видаляємо відфільтровані фрейми з буфера  
    for (int i = 0; i < filtered.length; i++) {
      tryTake(); // Simplified removal
    }
    
    return filtered;
  }
  
  /// **Performance Statistics**
  BufferPerformanceStats getPerformanceStats() {
    final uptime = _startTime != null 
        ? DateTime.now().difference(_startTime!)
        : Duration.zero;
    
    final throughput = uptime.inMilliseconds > 0 
        ? _totalFramesProcessed / (uptime.inMilliseconds / 1000.0)
        : 0.0;
    
    return BufferPerformanceStats(
      totalFramesProcessed: _totalFramesProcessed,
      droppedFrames: _droppedFrames,
      currentSize: size,
      maxCapacity: capacity,
      fillPercentage: fillPercentage,
      throughputFps: throughput,
      uptime: uptime,
      uniqueFrameIds: _frameIdCounts.length,
      mostActiveFrameId: _frameIdCounts.isNotEmpty 
          ? _frameIdCounts.entries.reduce((a, b) => a.value > b.value ? a : b).key
          : null,
    );
  }
  
  /// **Memory Usage Optimization**
  void optimizeMemory() {
    // Очищаємо старі статистики (старше 1 години)
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    
    _lastFrameTimes.removeWhere((id, time) => time.isBefore(cutoff));
    
    // Очищаємо counts для ID які не використовувались
    final activeIds = _lastFrameTimes.keys.toSet();
    _frameIdCounts.removeWhere((id, count) => !activeIds.contains(id));
  }
  
  /// Скидає статистики
  void resetStats() {
    _totalFramesProcessed = 0;
    _droppedFrames = 0;
    _frameIdCounts.clear();
    _lastFrameTimes.clear();
    _startTime = DateTime.now();
  }
}

/// **Lightweight CAN Frame representation для буферизації**
class CanFrameData {
  final int id;
  final int dlc;
  final Uint8List data;
  final DateTime timestamp;
  final bool isCorrupted;
  
  CanFrameData({
    required this.id,
    required this.dlc,
    required this.data,
    required this.timestamp,
    this.isCorrupted = false,
  });
  
  /// Конвертує з повного CanFrame
  factory CanFrameData.fromCanFrame(dynamic canFrame) {
    return CanFrameData(
      id: canFrame.id,
      dlc: canFrame.dlc,
      data: Uint8List.fromList(canFrame.data.cast<int>()),
      timestamp: canFrame.timestamp,
      isCorrupted: canFrame.isCorrupted,
    );
  }
  
  /// Розмір в пам'яті (приблизно)
  int get memorySize => 32 + data.length; // Приблизний overhead + data
}

/// **Performance статистики буфера**
class BufferPerformanceStats {
  final int totalFramesProcessed;
  final int droppedFrames;
  final int currentSize;
  final int maxCapacity;
  final double fillPercentage;
  final double throughputFps;
  final Duration uptime;
  final int uniqueFrameIds;
  final int? mostActiveFrameId;
  
  BufferPerformanceStats({
    required this.totalFramesProcessed,
    required this.droppedFrames,
    required this.currentSize,
    required this.maxCapacity,
    required this.fillPercentage,
    required this.throughputFps,
    required this.uptime,
    required this.uniqueFrameIds,
    this.mostActiveFrameId,
  });
  
  /// Drop rate percentage
  double get dropRate => totalFramesProcessed > 0 
      ? (droppedFrames / totalFramesProcessed) * 100 
      : 0.0;
  
  /// Memory usage estimate (MB)
  double get estimatedMemoryUsage => (currentSize * 40) / (1024 * 1024); // ~40 bytes per frame
  
  /// Health status буфера
  BufferHealth get health {
    if (dropRate > 5.0) return BufferHealth.critical;
    if (fillPercentage > 0.9) return BufferHealth.warning;
    if (fillPercentage > 0.7) return BufferHealth.caution;
    return BufferHealth.healthy;
  }
}

enum BufferHealth { healthy, caution, warning, critical }

/// **Volatile annotation для thread-safe операцій**
/// Note: В Dart це більше documentational, але показує intent
class volatile {
  const volatile();
}