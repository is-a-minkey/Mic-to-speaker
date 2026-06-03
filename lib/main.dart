// ═══════════════════════════════════════════════════════════
//  MEGAPHONE — Real-Time Audio Passthrough App
//  Flutter / Dart
//  Packages: flutter_sound ^9.28.0, permission_handler ^11.x
// ═══════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

// ─── Entry Point ────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Force portrait orientation
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  // Edge-to-edge immersive UI
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );
  runApp(const MegaphoneApp());
}

// ─── App Root ────────────────────────────────────────────────
class MegaphoneApp extends StatelessWidget {
  const MegaphoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Megaphone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF6B00),
          secondary: Color(0xFFFF9A3C),
          surface: Color(0xFF12121A),
        ),
        fontFamily: 'monospace',
      ),
      home: const MegaphoneScreen(),
    );
  }
}

// ─── Main Screen ─────────────────────────────────────────────
class MegaphoneScreen extends StatefulWidget {
  const MegaphoneScreen({super.key});

  @override
  State<MegaphoneScreen> createState() => _MegaphoneScreenState();
}

class _MegaphoneScreenState extends State<MegaphoneScreen>
    with TickerProviderStateMixin {
  // ── Audio Engine ──────────────────────────────────────────
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  StreamController<List<int>>? _audioFeedController;
  StreamSubscription<List<int>>? _audioSubscription;

  // ── State ─────────────────────────────────────────────────
  bool _isInitialized = false;
  bool _isActive = false;   // microphone + speaker running
  bool _isMuted = false;    // gate: stop feeding audio to player
  double _volume = 0.85;    // 0.0 → 1.0
  String _statusMessage = 'Initializing…';
  PermissionStatus _micPermission = PermissionStatus.denied;

  // ── Animation Controllers ─────────────────────────────────
  late final AnimationController _pulseController;
  late final AnimationController _ringController;
  late final AnimationController _waveController;
  late final AnimationController _buttonPressController;

  late final Animation<double> _pulseAnim;
  late final Animation<double> _ringAnim;
  late final Animation<double> _buttonPressAnim;

  // Waveform bars – 12 bars, each with its own amplitude driver
  final List<_BarData> _bars = List.generate(
    12,
    (i) => _BarData(phase: i * (math.pi * 2 / 12)),
  );

  // ── Constants ─────────────────────────────────────────────
  static const int _sampleRate = 44100;
  static const int _numChannels = 1;
  static const int _bufferSize = 4096;

  // ══════════════════════════════════════════════════════════
  //  LIFECYCLE
  // ══════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _initAudio();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _ringController.dispose();
    _waveController.dispose();
    _buttonPressController.dispose();
    _teardownAudio();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════
  //  ANIMATION SETUP
  // ══════════════════════════════════════════════════════════

  void _setupAnimations() {
    // Outer pulse ring
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.35).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOut),
    );

    // Inner ring shimmer
    _ringController = AnimationController(
      duration: const Duration(milliseconds: 2200),
      vsync: this,
    )..repeat();
    _ringAnim = Tween<double>(begin: 0.0, end: 1.0).animate(_ringController);

    // Waveform bars
    _waveController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..addListener(() {
        setState(() {
          final t = _waveController.value * math.pi * 2;
          for (final bar in _bars) {
            bar.height = (0.35 +
                    0.65 *
                        math.sin(t + bar.phase) *
                        math.sin(t * 0.7 + bar.phase * 1.3)
                            .abs()) *
                (!_isMuted && _isActive ? 1.0 : 0.15);
          }
        });
      });

    // Button press micro-animation
    _buttonPressController = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _buttonPressAnim = Tween<double>(begin: 1.0, end: 0.93).animate(
      CurvedAnimation(
          parent: _buttonPressController, curve: Curves.easeInOut),
    );
  }

  // ══════════════════════════════════════════════════════════
  //  AUDIO ENGINE
  // ══════════════════════════════════════════════════════════

  Future<void> _initAudio() async {
    // 1. Request microphone permission
    _micPermission = await Permission.microphone.request();

    if (!_micPermission.isGranted) {
      setState(() => _statusMessage = 'Microphone permission denied');
      return;
    }

    try {
      // 2. Open recorder & player sessions
      await _recorder.openRecorder();
      await _player.openPlayer();

      await _recorder.setSubscriptionDuration(
        const Duration(milliseconds: 10),
      );

      setState(() {
        _isInitialized = true;
        _statusMessage = 'Ready';
      });

      // 3. Auto-start transmission immediately on launch
      await _startTransmission();
    } catch (e) {
      setState(() => _statusMessage = 'Init error: $e');
    }
  }

  /// Opens the audio stream pipeline:
  ///   Microphone → PCM stream → Player (speaker/BT)
  Future<void> _startTransmission() async {
    if (!_isInitialized || _isActive) return;

    try {
      // Create the inter-component stream
      _audioFeedController = StreamController<List<int>>.broadcast();

      // ── Player: consume PCM from stream ──────────────────
      await _player.startPlayerFromStream(
        codec: Codec.pcm16,
        numChannels: _numChannels,
        sampleRate: _sampleRate,
        bufferSize: _bufferSize,
        interleaved: true,
      );
      await _player.setVolume(_volume);

      // ── Recorder: produce PCM into stream ────────────────
      await _recorder.startRecorder(
        toStream: _audioFeedController!.sink,
        codec: Codec.pcm16,
        numChannels: _numChannels,
        sampleRate: _sampleRate,
        bufferSize: _bufferSize,
        audioSource: AudioSource.microphone,
      );

      // ── Wire them together ────────────────────────────────
      _audioSubscription =
          _audioFeedController!.stream.listen((List<int> buffer) {
        if (!_isMuted) {
          // Feed PCM bytes directly to the player
          _player.feedUint8FromStream(Uint8List.fromList(buffer));
        }
      });

      setState(() {
        _isActive = true;
        _statusMessage = 'Live';
      });

      // Start animations
      _pulseController.repeat(reverse: true);
      _waveController.repeat();
    } catch (e) {
      setState(() => _statusMessage = 'Stream error: $e');
    }
  }

  Future<void> _stopTransmission() async {
    if (!_isActive) return;

    await _audioSubscription?.cancel();
    _audioSubscription = null;

    if (_recorder.isRecording) await _recorder.stopRecorder();
    if (_player.isPlaying) await _player.stopPlayer();

    await _audioFeedController?.close();
    _audioFeedController = null;

    setState(() {
      _isActive = false;
      _statusMessage = 'Stopped';
    });

    _pulseController.stop();
    _waveController.stop();
  }

  Future<void> _teardownAudio() async {
    await _stopTransmission();
    await _recorder.closeRecorder();
    await _player.closePlayer();
  }

  // ══════════════════════════════════════════════════════════
  //  UI ACTIONS
  // ══════════════════════════════════════════════════════════

  Future<void> _handleMuteToggle() async {
    // Micro press animation
    await _buttonPressController.forward();
    await _buttonPressController.reverse();

    HapticFeedback.mediumImpact();

    setState(() => _isMuted = !_isMuted);

    if (_isMuted) {
      _statusMessage = 'Muted';
      _pulseController.stop();
    } else {
      _statusMessage = 'Live';
      _pulseController.repeat(reverse: true);
    }
  }

  Future<void> _handleVolumeChange(double v) async {
    setState(() => _volume = v);
    if (_isActive) await _player.setVolume(v);
  }

  // ══════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final btnRadius = size.width * 0.30;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──────────────────────────────────────
            _buildTopBar(),

            // ── Waveform visualiser ──────────────────────────
            Expanded(
              flex: 2,
              child: _buildWaveform(),
            ),

            // ── Central toggle button ────────────────────────
            SizedBox(
              height: btnRadius * 2 + 60,
              child: Center(child: _buildMainButton(btnRadius)),
            ),

            // ── Volume slider ────────────────────────────────
            Expanded(
              flex: 1,
              child: _buildVolumeControl(),
            ),

            // ── Footer status ────────────────────────────────
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  //  TOP BAR
  // ─────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // App name
          const Text(
            'MEGAPHONE',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
              color: Color(0xFFFF6B00),
            ),
          ),
          // Live / Muted badge
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: (!_isMuted && _isActive)
                  ? const Color(0xFFFF6B00).withOpacity(0.15)
                  : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: (!_isMuted && _isActive)
                    ? const Color(0xFFFF6B00).withOpacity(0.6)
                    : Colors.white.withOpacity(0.1),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (!_isMuted && _isActive)
                        ? const Color(0xFFFF6B00)
                        : Colors.white.withOpacity(0.3),
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _statusMessage.toUpperCase(),
                    key: ValueKey(_statusMessage),
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600,
                      color: (!_isMuted && _isActive)
                          ? const Color(0xFFFF6B00)
                          : Colors.white.withOpacity(0.4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  //  WAVEFORM VISUALISER
  // ─────────────────────────────────────────────────────────
  Widget _buildWaveform() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: _bars.asMap().entries.map((entry) {
          final bar = entry.value;
          final isCenter = entry.key == 5 || entry.key == 6;

          return AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: isCenter ? 6 : 4,
            height: bar.height * 80 + 4,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  const Color(0xFFFF6B00).withOpacity(0.9),
                  const Color(0xFFFFD166).withOpacity(0.6),
                ],
              ),
              boxShadow: (!_isMuted && _isActive)
                  ? [
                      BoxShadow(
                        color: const Color(0xFFFF6B00).withOpacity(0.4),
                        blurRadius: 8,
                        spreadRadius: 1,
                      )
                    ]
                  : [],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  //  MAIN BUTTON
  // ─────────────────────────────────────────────────────────
  Widget _buildMainButton(double radius) {
    return GestureDetector(
      onTap: _isInitialized ? _handleMuteToggle : null,
      child: AnimatedBuilder(
        animation: Listenable.merge(
            [_pulseController, _ringController, _buttonPressController]),
        builder: (context, _) {
          return SizedBox(
            width: radius * 2 + 60,
            height: radius * 2 + 60,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // ── Outer pulse ring (only when live) ────────
                if (!_isMuted && _isActive)
                  Transform.scale(
                    scale: _pulseAnim.value,
                    child: Container(
                      width: radius * 2,
                      height: radius * 2,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFFF6B00).withOpacity(
                              (1.0 - (_pulseAnim.value - 1.0) / 0.35)
                                  .clamp(0.0, 0.5)),
                          width: 2,
                        ),
                      ),
                    ),
                  ),

                // ── Rotating shimmer ring ─────────────────────
                Transform.rotate(
                  angle: _ringAnim.value * math.pi * 2,
                  child: Container(
                    width: radius * 2 + 4,
                    height: radius * 2 + 4,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          (!_isMuted && _isActive)
                              ? const Color(0xFFFF6B00).withOpacity(0.6)
                              : Colors.white.withOpacity(0.1),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.6, 0.8, 1.0],
                      ),
                    ),
                  ),
                ),

                // ── Main button circle ────────────────────────
                Transform.scale(
                  scale: _buttonPressAnim.value,
                  child: Container(
                    width: radius * 2,
                    height: radius * 2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: _isMuted
                            ? [
                                const Color(0xFF2A2A35),
                                const Color(0xFF16161F),
                              ]
                            : [
                                const Color(0xFFFF8C2A),
                                const Color(0xFFCC4400),
                              ],
                        center: const Alignment(-0.3, -0.3),
                      ),
                      boxShadow: _isMuted
                          ? [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.4),
                                blurRadius: 20,
                                spreadRadius: 5,
                              )
                            ]
                          : [
                              BoxShadow(
                                color:
                                    const Color(0xFFFF6B00).withOpacity(0.5),
                                blurRadius: 35,
                                spreadRadius: 8,
                              ),
                              BoxShadow(
                                color:
                                    const Color(0xFFFF6B00).withOpacity(0.2),
                                blurRadius: 60,
                                spreadRadius: 15,
                              ),
                            ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                          size: radius * 0.55,
                          color: _isMuted
                              ? Colors.white.withOpacity(0.3)
                              : Colors.white.withOpacity(0.95),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _isMuted ? 'TAP TO UNMUTE' : 'TAP TO MUTE',
                          style: TextStyle(
                            fontSize: 9,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w600,
                            color: _isMuted
                                ? Colors.white.withOpacity(0.2)
                                : Colors.white.withOpacity(0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  //  VOLUME SLIDER
  // ─────────────────────────────────────────────────────────
  Widget _buildVolumeControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(Icons.volume_down_rounded,
                  size: 18, color: Colors.white.withOpacity(0.3)),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: const Color(0xFFFF6B00),
                    inactiveTrackColor: Colors.white.withOpacity(0.08),
                    thumbColor: const Color(0xFFFF9A3C),
                    overlayColor:
                        const Color(0xFFFF6B00).withOpacity(0.15),
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7),
                  ),
                  child: Slider(
                    value: _volume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: _handleVolumeChange,
                  ),
                ),
              ),
              Icon(Icons.volume_up_rounded,
                  size: 18, color: Colors.white.withOpacity(0.3)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'OUTPUT VOLUME  ·  ${(_volume * 100).round()}%',
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 2,
              color: Colors.white.withOpacity(0.2),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  //  FOOTER
  // ─────────────────────────────────────────────────────────
  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Text(
        'AEC  ·  44.1 kHz  ·  PCM-16',
        style: TextStyle(
          fontSize: 9,
          letterSpacing: 2,
          color: Colors.white.withOpacity(0.12),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
//  HELPERS
// ══════════════════════════════════════════════════════════

/// Holds per-bar animation state for the waveform visualiser.
class _BarData {
  final double phase;
  double height;

  _BarData({required this.phase, this.height = 0.15});
}
