# CAN Frame Emulator

A Flutter application that simulates CAN (Controller Area Network) bus communication with real-time frame generation and monitoring capabilities.

## 🎯 Features

### CAN Frame Model (`CanFrame`)
- **ID**: CAN frame identifier (11-bit or 29-bit)
- **DLC**: Data Length Code (0-8 bytes)
- **Data**: Payload bytes (up to 8 bytes)
- **CRC**: Cyclic Redundancy Check for error detection
- **Timestamp**: Frame creation timestamp
- **isCorrupted**: Flag for intentional error injection

### CAN Frame Simulator (`CanFrameSimulator`)
- Generates random CAN frames every 100-200ms
- 10% corruption rate for error testing
- Stream-based real-time frame delivery
- Configurable frame parameters
- Custom frame generation support
- Burst mode for high-traffic scenarios

### Monitor Screen (`MonitorScreen`)
- Real-time frame visualization
- Color-coded status indicators (green=OK, red=ERROR)
- Live statistics (total frames, error count, error rate)
- Scrollable frame history (latest 100 frames)
- Start/stop/reset controls

## 📁 Project Structure

```
lib/
├── domain/
│   ├── models/
│   │   └── can_frame.dart           # CAN frame data model
│   ├── simulator/
│   │   └── can_frame_simulator.dart # Frame generator
│   └── detection/
│       └── can_error_checker.dart   # Error detection (placeholder)
├── presentation/
│   └── screens/
│       └── monitor_screen.dart      # Main monitoring UI
└── main.dart                        # App entry point
```

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (3.9.0 or higher)
- Dart SDK
- Android Studio / VS Code with Flutter extension

### Installation

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd can_debug
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run the app:
   ```bash
   flutter run
   ```

## 💻 Usage

### Basic Usage

The app automatically starts with the CAN Monitor screen showing:
- Live stream of CAN frames
- Real-time statistics
- Control buttons (play/pause/reset)

### Understanding the Display

Each frame row shows:
- **ID**: CAN identifier in hexadecimal (0x123)
- **DLC**: Data length (0-8 bytes)
- **Data**: Hex representation of payload bytes
- **CRC**: Checksum in hexadecimal
- **Time**: Timestamp (seconds.milliseconds)
- **Status**: OK (green dot) or ERROR (red dot)

### Statistics Panel
- **Total Frames**: Number of frames generated
- **Error Frames**: Number of corrupted frames
- **Error Rate**: Percentage of corrupted frames
- **Status**: Current simulator state

## 🧪 Code Examples

### Creating a Custom CAN Frame

```dart
import 'package:can_debug/domain/models/can_frame.dart';

// Create a normal frame
final frame = CanFrame.create(
  id: 0x123,
  dlc: 4,
  data: [0x01, 0x02, 0x03, 0x04],
  isCorrupted: false,
);

// Create a corrupted frame
final corruptedFrame = CanFrame.create(
  id: 0x456,
  dlc: 2,
  data: [0xAA, 0xBB],
  isCorrupted: true, // This will corrupt the CRC
);
```

### Using the Simulator

```dart
import 'package:can_debug/domain/simulator/can_frame_simulator.dart';

final simulator = CanFrameSimulator();

// Listen to frame stream
simulator.frameStream.listen((frame) {
  print('Received: ${frame.toString()}');
});

// Start simulation
simulator.start();

// Generate custom frame
simulator.generateCustomFrame(
  id: 0x7FF,
  dlc: 8,
  data: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77],
);

// Stop and cleanup
simulator.stop();
simulator.dispose();
```

## 🔧 Configuration

### Simulator Settings
You can modify these constants in `can_frame_simulator.dart`:

```dart
static const int minDelay = 100;           // Min delay between frames (ms)
static const int maxDelay = 200;           // Max delay between frames (ms)
static const double corruptionRate = 0.1;  // 10% corruption rate
static const int maxCanId = 0x7FF;         // Standard 11-bit CAN ID
```

### Display Settings
Modify these in `monitor_screen.dart`:

```dart
final int _maxFramesToShow = 100; // Number of frames to display
```

## 🧪 Testing

Run the test suite:

```bash
flutter test
```

Test files:
- `test/can_emulator_test.dart` - Unit tests for models and simulator
- `example/can_emulator_example.dart` - Usage examples

## 📊 Performance

### Frame Generation Rate
- **Target**: 5-10 frames per second
- **Actual**: ~7 frames per second (varies with random delays)
- **Memory**: Displays latest 100 frames to maintain performance

### Error Simulation
- **Rate**: 10% of frames are intentionally corrupted
- **Method**: CRC value is modified for corrupted frames
- **Detection**: Frames are marked with `isCorrupted` flag

## 🎨 UI Features

### Visual Indicators
- **Green rows**: Normal frames
- **Red rows**: Corrupted frames
- **Alternating colors**: Easier row distinction
- **Status dots**: Quick visual status check

### Interactive Controls
- **Play/Pause**: Start/stop frame generation
- **Reset**: Clear all frames and statistics
- **Real-time updates**: No manual refresh needed

## 🔮 Future Enhancements

The next development phase will include:

1. **CAN Error Checker** (`can_error_checker.dart`)
   - Detailed error analysis
   - Multiple error types (CRC, format, stuffing, ACK)
   - Error pattern detection

2. **Advanced Features**
   - Frame filtering and search
   - Export functionality
   - Custom protocol support
   - Network simulation

## 🐛 Troubleshooting

### Common Issues

1. **App not starting**
   - Ensure Flutter SDK is properly installed
   - Run `flutter doctor` to check setup

2. **No frames appearing**
   - Check if simulation is running (play button)
   - Verify stream subscription is active

3. **Performance issues**
   - Reduce `_maxFramesToShow` value
   - Close other applications to free memory

## 📝 License

This project is part of a term paper on CAN bus debugging and monitoring systems.

## 🤝 Contributing

This is an educational project. For suggestions or improvements, please create an issue or pull request.

---

**Built with Flutter** 💙 **for CAN bus simulation and monitoring**