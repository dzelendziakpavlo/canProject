# 🚗 Enhanced CAN Frame Emulator with Advanced Error Detection

Розширена версія CAN емулятора з поглибленою детекцією та аналізом помилок CAN протоколу.

## 🎯 **Нові функції Error Detection System**

### **📊 Типи помилок, які ми відловлюємо:**

#### **1. CRC Errors (Checksum Errors)**
```dart
// Автоматична симуляція CRC помилок (10% фреймів)
final isCorrupted = _random.nextDouble() < 0.1;
```
- ✅ **Виявлення**: Невідповідність контрольної суми
- ✅ **Відображення**: Червоний рядок з індикатором ERROR
- ✅ **Статистика**: Підрахунок CRC помилок

#### **2. Bit Stuffing Errors** 
```dart
// Порушення правил біт-стаффінгу (2% rate)
if (_random.nextDouble() < stuffingErrorRate) {
  errors.add(CanErrorInfo(
    type: CanErrorType.stuffingError,
    description: 'More than 5 consecutive identical bits',
    severity: 2,
  ));
}
```
- ✅ **Детекція**: >5 послідовних однакових бітів
- ✅ **Severity**: Medium (2/5)
- ✅ **Details**: Позиція помилки, послідовність бітів

#### **3. Format Errors**
```dart
// Порушення формату зарезервованих бітів (1.5% rate)
errors.add(CanErrorInfo(
  type: CanErrorType.formatError,
  description: 'Frame format violation in reserved bits',
  severity: 3,
));
```
- ✅ **Типи**: r0, r1, IDE, RTR bit violations
- ✅ **Severity**: High (3/5)

#### **4. ACK Errors**
```dart
// Відсутність підтвердження (1% rate)
errors.add(CanErrorInfo(
  type: CanErrorType.ackError,
  description: 'No acknowledgment received',
  severity: 4,
));
```
- ✅ **Причини**: Відсутність вузлів на шині
- ✅ **Severity**: Critical (4/5)
- ✅ **Context**: Bus load information

#### **5. Overload Errors**
```dart
// Перевантаження шини (0.5% rate)
errors.add(CanErrorInfo(
  type: CanErrorType.overloadError,
  description: 'Bus overload condition detected',
  severity: 4,
));
```
- ✅ **Causes**: Internal conditions, timing violations
- ✅ **Severity**: Critical (4/5)

#### **6. Form Errors**
```dart
// Помилки фіксованих полів (0.8% rate)  
errors.add(CanErrorInfo(
  type: CanErrorType.formError,
  description: 'Form error in fixed format field',
  severity: 2,
));
```
- ✅ **Fields**: SOF, EOF, ACK delimiter, CRC delimiter
- ✅ **Severity**: Medium (2/5)

## 🔥 **Enhanced UI Features**

### **📈 Real-time Error Statistics**
```dart
// Підрахунок кожного типу помилки
final Map<CanErrorType, int> _errorStats = {
  for (var type in CanErrorType.values) type: 0
};
```

**Нова статистика:**
- ✅ **CRC Errors**: Кількість + відсоток
- ✅ **Stuffing Errors**: Проблеми синхронізації
- ✅ **ACK Errors**: Проблеми з підключенням
- ✅ **Format Errors**: Протокольні порушення
- ✅ **Overload Errors**: Перевантаження шини

### **🎨 Advanced Visual Indicators**

#### **Color-coded Severity Levels:**
```dart
Color _getSeverityColor(int severity) {
  switch (severity) {
    case 1: return Colors.green;      // Low
    case 2: return Colors.orange;     // Medium  
    case 3: return Colors.red;        // High
    case 4-5: return Colors.red.shade800; // Critical/Fatal
  }
}
```

#### **Interactive Error Details:**
- 🔴 **Clickable Error Rows**: Tap червоний рядок для деталей
- 📋 **Error Breakdown**: Тип, опис, severity, timestamp
- 🔍 **Frame Analysis**: ID, DLC, Data, детальна інформація

### **📊 Detailed Statistics Dialog**

**Кнопка "📊 Error Statistics" в AppBar:**
```dart
IconButton(
  icon: const Icon(Icons.bar_chart),
  onPressed: _showDetailedErrorStats,
  tooltip: 'Error Statistics',
),
```

**Features в діалозі:**
- ✅ **Overall Status**: CRITICAL/NORMAL based on error rate
- ✅ **Error Breakdown**: По типах з відсотками
- ✅ **Recommendations**: Автоматичні поради
- ✅ **Critical Alerts**: Попередження при >15% помилок

## 💡 **Smart Recommendations System**

```dart
List<String> getRecommendations(Map<CanErrorType, int> errorStats, int totalFrames) {
  if (crcErrors / totalFrames > 0.05) {
    recommendations.add('High CRC error rate: Check cable integrity');
  }
  if (stuffingErrors / totalFrames > 0.03) {
    recommendations.add('Bit stuffing violations: Verify bus timing');
  }
  // ... більше intelligent recommendations
}
```

**Автоматичні поради:**
- 🔧 **High CRC Rate**: Перевірте кабелі та термінацію
- ⏱️ **Stuffing Errors**: Проблеми синхронізації годинників
- 📡 **ACK Errors**: Перевірте підключення вузлів
- 🚦 **Overload**: Зменште навантаження на шину

## 🎮 **Enhanced User Experience**

### **Real-time Error Tracking:**
```dart
// Автоматичне відстеження помилок
void _setupFrameListener() {
  _subscription = _simulator.frameStream.listen((frame) {
    final errors = _errorChecker.analyzeFrame(frame);
    
    // Update statistics for each error type
    for (final error in errors) {
      _errorStats[error.type] = (_errorStats[error.type] ?? 0) + 1;
    }
  });
}
```

### **Interactive Error Investigation:**
1. **Red Row**: Помилковий фрейм (червоний фон)
2. **Click Row**: Показати деталі помилки
3. **Error Dialog**: Повна інформація про помилку
4. **Statistics**: Глобальна статистика помилок

## 📋 **Error Detection Matrix**

| Error Type | Rate | Severity | Description |
|------------|------|----------|-------------|
| ✅ **CRC Error** | 10% | High (3) | Checksum mismatch |
| ✅ **Bit Stuffing** | 2% | Medium (2) | >5 consecutive bits |
| ✅ **Format Error** | 1.5% | High (3) | Reserved bit violation |
| ✅ **ACK Error** | 1% | Critical (4) | No acknowledgment |
| ✅ **Overload** | 0.5% | Critical (4) | Bus overload |
| ✅ **Form Error** | 0.8% | Medium (2) | Fixed field violation |

## 🚀 **Usage Examples**

### **Monitoring Real-time Errors:**
```dart
// The app automatically:
// 1. Generates frames with various error types
// 2. Updates statistics in real-time  
// 3. Shows visual indicators
// 4. Provides detailed analysis
```

### **Investigating Specific Errors:**
```dart
// User interaction:
// 1. See red frame row
// 2. Tap on red row  
// 3. View detailed error information
// 4. Get recommendations for fixes
```

### **Overall System Health:**
```dart
// Statistics panel shows:
// - Total frames: 1,234
// - Error frames: 145 (11.7%)
// - Status: NORMAL/CRITICAL
// - Detailed breakdown by error type
```

## 🎯 **What We've Achieved**

### **✅ Implemented:**
- 🔴 **6 типів CAN помилок** з реалістичними rates
- 📊 **Real-time статистика** по кожному типу
- 🎨 **Color-coded severity** indicators  
- 📱 **Interactive error details** dialogs
- 💡 **Smart recommendations** system
- ⚠️ **Critical error rate** detection
- 🔍 **Frame-level error analysis**

### **🚀 Next Steps Ready:**
- Advanced protocol errors
- Physical layer simulation
- Network topology analysis
- Historical error trends
- Export/import capabilities

**Наша система тепер може симулювати та аналізувати складні CAN протокольні помилки в реальному часі!** 🎉

---

**Протестуйте функції:**
1. **Запустіть** `flutter run`
2. **Відкрийте** CAN Monitor
3. **Дивіться** червоні рядки (помилки)
4. **Натисніть** на червоний рядок для деталей
5. **Відкрийте** 📊 Statistics для повного аналізу