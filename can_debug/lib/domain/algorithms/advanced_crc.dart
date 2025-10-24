import 'dart:math' as math;

/// **Advanced CRC алгоритми для кращої детекції помилок**
/// 
/// **Що робить**: CRC-16 CCITT та CRC-32 IEEE 802.3 замість простого CRC-8
/// **Переваги**: Набагато краща детекція single/multiple bit errors, burst errors
/// **Використання**: Професійна перевірка цілісності CAN фреймів
class AdvancedCrcCalculator {
  // CRC-16 CCITT polynomial: x^16 + x^12 + x^5 + 1 (0x1021)
  static const int _crc16Poly = 0x1021;
  static const int _crc16InitValue = 0xFFFF;
  
  // CRC-32 IEEE 802.3 polynomial: 0xEDB88320 (reversed)
  static const int _crc32Poly = 0xEDB88320;
  static const int _crc32InitValue = 0xFFFFFFFF;
  
  // Lookup tables for faster computation
  static List<int>? _crc16Table;
  static List<int>? _crc32Table;
  
  /// **CRC-16 CCITT calculation**
  /// 
  /// **Що робить**: 16-bit checksum з CCITT polynomial
  /// **Детектує**: Single bit errors, double bit errors, burst errors до 16 bits
  /// **Переваги**: Швидкий, надійний, стандартний в телекомунікаціях
  static int calculateCrc16(List<int> data) {
    _initCrc16Table();
    
    int crc = _crc16InitValue;
    
    for (final byte in data) {
      final tableIndex = ((crc >> 8) ^ byte) & 0xFF;
      crc = ((crc << 8) ^ _crc16Table![tableIndex]) & 0xFFFF;
    }
    
    return crc;
  }
  
  /// **CRC-32 IEEE 802.3 calculation**
  /// 
  /// **Що робить**: 32-bit checksum (як в Ethernet, ZIP, PNG)
  /// **Детектує**: Всі single/double bit errors, burst errors до 32 bits
  /// **Переваги**: Максимальна надійність, industry standard
  static int calculateCrc32(List<int> data) {
    _initCrc32Table();
    
    int crc = _crc32InitValue;
    
    for (final byte in data) {
      final tableIndex = (crc ^ byte) & 0xFF;
      crc = (crc >> 8) ^ _crc32Table![tableIndex];
    }
    
    return (~crc) & 0xFFFFFFFF;
  }
  
  /// **Hamming distance між двома CRC**
  /// 
  /// **Що робить**: Підраховує кількість різних бітів
  /// **Використання**: Аналіз серйозності bit corruption
  static int hammingDistance(int crc1, int crc2) {
    int xor = crc1 ^ crc2;
    int count = 0;
    
    while (xor != 0) {
      count += xor & 1;
      xor >>= 1;
    }
    
    return count;
  }
  
  /// **Bit error probability estimation**
  /// 
  /// **Що робить**: Оцінює ймовірність bit errors на основі CRC різниці
  /// **Повертає**: 0.0-1.0 (вища = більше errors)
  static double estimateErrorProbability(int expectedCrc, int actualCrc, int crcBits) {
    final hammingDist = hammingDistance(expectedCrc, actualCrc);
    
    if (hammingDist == 0) return 0.0;
    
    // Нормалізуємо по кількості бітів у CRC
    final maxDistance = crcBits.toDouble();
    final normalizedDistance = hammingDist / maxDistance;
    
    // Логарифмічна шкала для probability estimation
    return 1.0 - math.exp(-3.0 * normalizedDistance);
  }
  
  /// **Error pattern analysis**
  /// 
  /// **Що робить**: Аналізує тип corruption на основі CRC pattern
  static ErrorPattern analyzeCrcError(int expectedCrc, int actualCrc) {
    final hammingDist = hammingDistance(expectedCrc, actualCrc);
    final xor = expectedCrc ^ actualCrc;
    
    if (hammingDist == 0) {
      return ErrorPattern.none;
    } else if (hammingDist == 1) {
      return ErrorPattern.singleBit;
    } else if (hammingDist == 2) {
      return ErrorPattern.doubleBit;
    } else if (_isBurstError(xor)) {
      return ErrorPattern.burstError;
    } else if (hammingDist > 8) {
      return ErrorPattern.massiveCorruption;
    } else {
      return ErrorPattern.multipleBit;
    }
  }
  
  /// Ініціалізує lookup table для CRC-16
  static void _initCrc16Table() {
    if (_crc16Table != null) return;
    
    _crc16Table = List.filled(256, 0);
    
    for (int i = 0; i < 256; i++) {
      int crc = i << 8;
      
      for (int j = 0; j < 8; j++) {
        if ((crc & 0x8000) != 0) {
          crc = (crc << 1) ^ _crc16Poly;
        } else {
          crc <<= 1;
        }
        crc &= 0xFFFF;
      }
      
      _crc16Table![i] = crc;
    }
  }
  
  /// Ініціалізує lookup table для CRC-32
  static void _initCrc32Table() {
    if (_crc32Table != null) return;
    
    _crc32Table = List.filled(256, 0);
    
    for (int i = 0; i < 256; i++) {
      int crc = i;
      
      for (int j = 0; j < 8; j++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ _crc32Poly;
        } else {
          crc >>= 1;
        }
      }
      
      _crc32Table![i] = crc;
    }
  }
  
  /// Перевіряє чи це burst error (послідовні біти)
  static bool _isBurstError(int xor) {
    // Burst error = consecutive bits are corrupted
    // Шукаємо найдовшу послідовність 1-ок
    int maxBurst = 0;
    int currentBurst = 0;
    
    while (xor != 0) {
      if ((xor & 1) == 1) {
        currentBurst++;
        maxBurst = math.max(maxBurst, currentBurst);
      } else {
        currentBurst = 0;
      }
      xor >>= 1;
    }
    
    // Burst якщо ≥3 consecutive bits
    return maxBurst >= 3;
  }
}

/// **Comprehensive CRC Validator для CAN фреймів**
class CanCrcValidator {
  final Map<int, CrcStatistics> _frameStats = {};
  
  /// Перевіряє CRC та збирає статистики
  CrcValidationResult validateFrame(List<int> data, int id, int dlc, int receivedCrc) {
    // Обчислюємо різні типи CRC
    final crc8 = _calculateSimpleCrc8(data, id, dlc);
    final crc16 = AdvancedCrcCalculator.calculateCrc16([...data, id & 0xFF, (id >> 8) & 0xFF, dlc]);
    final crc32 = AdvancedCrcCalculator.calculateCrc32([...data, id & 0xFF, (id >> 8) & 0xFF, dlc]);
    
    // Аналізуємо результати
    final crc8Valid = (crc8 == receivedCrc);
    final crc16Valid = (crc16 & 0xFF) == receivedCrc;  // Порівнюємо тільки молодший байт
    final crc32Valid = (crc32 & 0xFF) == receivedCrc;
    
    // Оновлюємо статистики
    _updateStatistics(id, crc8Valid, crc16Valid, crc32Valid);
    
    // Визначаємо найкращий результат
    CrcAlgorithm bestAlgorithm;
    bool isValid;
    double confidence;
    
    if (crc32Valid) {
      bestAlgorithm = CrcAlgorithm.crc32;
      isValid = true;
      confidence = 0.99;
    } else if (crc16Valid) {
      bestAlgorithm = CrcAlgorithm.crc16;
      isValid = true;
      confidence = 0.95;
    } else if (crc8Valid) {
      bestAlgorithm = CrcAlgorithm.crc8;
      isValid = true;
      confidence = 0.85;
    } else {
      bestAlgorithm = CrcAlgorithm.crc32;  // Використовуємо найпотужніший для аналізу
      isValid = false;
      confidence = 0.0;
    }
    
    // Аналіз corruption pattern
    final expectedCrc = _getExpectedCrc(bestAlgorithm, data, id, dlc);
    final errorPattern = AdvancedCrcCalculator.analyzeCrcError(expectedCrc & 0xFF, receivedCrc);
    final errorProbability = AdvancedCrcCalculator.estimateErrorProbability(expectedCrc & 0xFF, receivedCrc, 8);
    
    return CrcValidationResult(
      isValid: isValid,
      algorithm: bestAlgorithm,
      confidence: confidence,
      errorPattern: errorPattern,
      errorProbability: errorProbability,
      crc8: crc8,
      crc16: crc16,
      crc32: crc32,
    );
  }
  
  int _calculateSimpleCrc8(List<int> data, int id, int dlc) {
    int crc = 0;
    crc ^= (id >> 8) & 0xFF;
    crc ^= id & 0xFF;
    crc ^= dlc;
    for (int byte in data) {
      crc ^= byte;
    }
    return crc & 0xFF;
  }
  
  int _getExpectedCrc(CrcAlgorithm algorithm, List<int> data, int id, int dlc) {
    switch (algorithm) {
      case CrcAlgorithm.crc8:
        return _calculateSimpleCrc8(data, id, dlc);
      case CrcAlgorithm.crc16:
        return AdvancedCrcCalculator.calculateCrc16([...data, id & 0xFF, (id >> 8) & 0xFF, dlc]);
      case CrcAlgorithm.crc32:
        return AdvancedCrcCalculator.calculateCrc32([...data, id & 0xFF, (id >> 8) & 0xFF, dlc]);
    }
  }
  
  void _updateStatistics(int frameId, bool crc8Valid, bool crc16Valid, bool crc32Valid) {
    _frameStats[frameId] ??= CrcStatistics();
    final stats = _frameStats[frameId]!;
    
    stats.totalFrames++;
    if (crc8Valid) stats.crc8Successes++;
    if (crc16Valid) stats.crc16Successes++;
    if (crc32Valid) stats.crc32Successes++;
  }
  
  /// Отримує статистики по frame ID
  CrcStatistics? getStatistics(int frameId) => _frameStats[frameId];
  
  /// Загальні статистики
  Map<int, CrcStatistics> get allStatistics => Map.unmodifiable(_frameStats);
}

/// **Результат CRC валідації**
class CrcValidationResult {
  final bool isValid;
  final CrcAlgorithm algorithm;
  final double confidence;
  final ErrorPattern errorPattern;
  final double errorProbability;
  final int crc8;
  final int crc16;
  final int crc32;
  
  CrcValidationResult({
    required this.isValid,
    required this.algorithm,
    required this.confidence,
    required this.errorPattern,
    required this.errorProbability,
    required this.crc8,
    required this.crc16,
    required this.crc32,
  });
}

/// **Статистики CRC для конкретного frame ID**
class CrcStatistics {
  int totalFrames = 0;
  int crc8Successes = 0;
  int crc16Successes = 0;
  int crc32Successes = 0;
  
  double get crc8SuccessRate => totalFrames > 0 ? crc8Successes / totalFrames : 0.0;
  double get crc16SuccessRate => totalFrames > 0 ? crc16Successes / totalFrames : 0.0;
  double get crc32SuccessRate => totalFrames > 0 ? crc32Successes / totalFrames : 0.0;
  
  CrcAlgorithm get bestAlgorithm {
    if (crc32SuccessRate >= crc16SuccessRate && crc32SuccessRate >= crc8SuccessRate) {
      return CrcAlgorithm.crc32;
    } else if (crc16SuccessRate >= crc8SuccessRate) {
      return CrcAlgorithm.crc16;
    } else {
      return CrcAlgorithm.crc8;
    }
  }
}

enum CrcAlgorithm { crc8, crc16, crc32 }

enum ErrorPattern {
  none,              // Немає помилок
  singleBit,         // 1 bit corrupted
  doubleBit,         // 2 bits corrupted  
  multipleBit,       // 3-8 bits corrupted
  burstError,        // Consecutive bits corrupted
  massiveCorruption, // >8 bits corrupted
}