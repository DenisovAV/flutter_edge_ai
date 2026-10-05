import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'utils/audio_converter.dart';
import 'utils/platform_io_helper.dart';

class ChatInputField extends StatefulWidget {
  final ValueChanged<Message> handleSubmitted;
  final bool supportsImages;
  final bool supportsAudio;

  const ChatInputField({
    super.key,
    required this.handleSubmitted,
    this.supportsImages = false,
    this.supportsAudio = false,
  });

  @override
  ChatInputFieldState createState() => ChatInputFieldState();
}

class ChatInputFieldState extends State<ChatInputField> {
  final TextEditingController _textController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  Uint8List? _selectedImageBytes;
  String? _selectedImageName;

  // Audio recording state
  final AudioRecorder _audioRecorder = AudioRecorder();
  Uint8List? _selectedAudioBytes;
  bool _isRecording = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;
  static const _maxRecordingDuration = Duration(seconds: 60);

  @override
  void dispose() {
    _textController.dispose();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  void _handleSubmitted(String text) {
    if (text.trim().isEmpty &&
        _selectedImageBytes == null &&
        _selectedAudioBytes == null) {
      return;
    }

    final Message message;
    if (_selectedAudioBytes != null) {
      message = Message.withAudio(
        text: text.trim(),
        audioBytes: _selectedAudioBytes!,
        isUser: true,
      );
    } else if (_selectedImageBytes != null) {
      message = Message.withImage(
        text: text.trim(),
        imageBytes: _selectedImageBytes!,
        isUser: true,
      );
    } else {
      message = Message.text(text: text.trim(), isUser: true);
    }

    widget.handleSubmitted(message);
    _textController.clear();
    _clearImage();
    _clearAudio();
  }

  void _clearImage() {
    setState(() {
      _selectedImageBytes = null;
      _selectedImageName = null;
    });
  }

  Future<void> _pickImage() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      final pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        final bytes = await pickedFile.readAsBytes();
        setState(() {
          _selectedImageBytes = bytes;
          _selectedImageName = pickedFile.name;
        });
      }
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Image selection error: $e')),
      );
    }
  }

  // Audio recording methods

  void _clearAudio() {
    setState(() {
      _selectedAudioBytes = null;
      _recordingDuration = Duration.zero;
    });
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    // Check microphone permission (only on mobile where permission_handler works)
    // Desktop platforms (macOS/Windows/Linux) will show OS permission dialog automatically
    if (!kIsWeb && (platformIsAndroid || platformIsIOS)) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text('Microphone permission required for audio recording'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    // Check if recorder is available
    if (!await _audioRecorder.hasPermission()) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text('Microphone not available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Clear image if present (mutually exclusive)
    if (_selectedImageBytes != null) {
      _clearImage();
    }

    try {
      // Start recording in WAV format at 16kHz mono
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 256000,
        ),
        path: kIsWeb ? '' : '$systemTempPath/audio_recording.wav',
      );

      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
      });

      // Start timer
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _recordingDuration += const Duration(seconds: 1);
        });

        // Auto-stop at max duration
        if (_recordingDuration >= _maxRecordingDuration) {
          _stopRecording();
        }
      });
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to start recording: $e')),
      );
    }
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;

    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      final path = await _audioRecorder.stop();
      debugPrint('[AudioRecording] Stop returned path: $path');

      if (path != null) {
        Uint8List audioBytes;

        if (kIsWeb) {
          // On web, path is a blob URL - fetch it
          final response = await _fetchWebBlob(path);
          audioBytes = response;
        } else {
          // On mobile/desktop, read from file
          final file = createFile(path);
          debugPrint('[AudioRecording] Reading file: ${file.path}');
          debugPrint('[AudioRecording] File exists: ${await file.exists()}');

          final wavData = await file.readAsBytes();
          debugPrint('[AudioRecording] Read ${wavData.length} bytes');
          debugPrint(
            '[AudioRecording] First 12 bytes: ${wavData.take(12).toList()}',
          );

          // Send original WAV directly - record package already creates 16kHz mono WAV
          // Skipping parse/re-wrap as it may lose metadata needed by miniaudio
          audioBytes = wavData;
          debugPrint(
            '[AudioRecording] Using original WAV: ${audioBytes.length} bytes',
          );

          // Clean up temp file
          await file.delete();
        }

        setState(() {
          _isRecording = false;
          _selectedAudioBytes = audioBytes;
        });
      } else {
        setState(() {
          _isRecording = false;
        });
      }
    } catch (e) {
      setState(() {
        _isRecording = false;
      });
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to save recording: $e')),
      );
    }
  }

  Future<Uint8List> _fetchWebBlob(String blobUrl) async {
    // On web, the record package returns blob URLs — fetch via http package
    final response = await http.get(Uri.parse(blobUrl));
    final wavData = response.bodyBytes;

    // Parse WAV and extract PCM
    final parsed = AudioConverter.parseWav(wavData);
    final pcmData = AudioConverter.toPCM16kHzMono(
      parsed.pcmData,
      sourceSampleRate: parsed.sampleRate,
      sourceChannels: parsed.channels,
    );

    return pcmData;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Selected image preview
        if (_selectedImageBytes != null) _buildImagePreview(),

        // Selected audio preview
        if (_selectedAudioBytes != null && !_isRecording) _buildAudioPreview(),

        // Recording indicator
        if (_isRecording) _buildRecordingIndicator(),

        // Input field
        IconTheme(
          data: IconThemeData(color: Theme.of(context).hoverColor),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8.0),
            decoration: BoxDecoration(
              color: const Color(0xFF1a3a5c),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: <Widget>[
                // Add image button (hidden when recording or audio selected)
                if (widget.supportsImages &&
                    !_isRecording &&
                    _selectedAudioBytes == null)
                  IconButton(
                    icon: Icon(
                      Icons.image,
                      color: _selectedImageBytes != null
                          ? Colors.blue
                          : Colors.white70,
                    ),
                    onPressed: _pickImage,
                    tooltip: 'Add image',
                  ),

                // Microphone button (hidden when image selected)
                if (widget.supportsAudio && _selectedImageBytes == null)
                  IconButton(
                    icon: Icon(
                      _isRecording ? Icons.stop : Icons.mic,
                      color: _isRecording
                          ? Colors.red
                          : _selectedAudioBytes != null
                          ? Colors.blue
                          : Colors.white70,
                    ),
                    onPressed: _toggleRecording,
                    tooltip: _isRecording ? 'Stop recording' : 'Record audio',
                  ),

                Flexible(
                  child: TextField(
                    controller: _textController,
                    onSubmitted: _handleSubmitted,
                    style: const TextStyle(color: Colors.white),
                    enabled: !_isRecording,
                    decoration: InputDecoration(
                      hintText: _getHintText(),
                      hintStyle: const TextStyle(color: Colors.white54),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 12.0,
                      ),
                    ),
                    maxLines: null,
                  ),
                ),

                // Send button (hidden when recording)
                if (!_isRecording)
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.white70),
                    onPressed: () => _handleSubmitted(_textController.text),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _getHintText() {
    if (_isRecording) {
      return 'Recording...';
    } else if (_selectedAudioBytes != null) {
      return 'Add description to audio...';
    } else if (_selectedImageBytes != null) {
      return 'Add description to image...';
    }
    return 'Send message';
  }

  Widget _buildImagePreview() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: const Color(0xFF2a4a6c),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          // Image preview
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              _selectedImageBytes!,
              width: 60,
              height: 60,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),

          // Image information
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selectedImageName ?? 'Image',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${(_selectedImageBytes!.length / 1024).toStringAsFixed(1)} KB',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),

          // Delete button
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: _clearImage,
            tooltip: 'Remove image',
          ),
        ],
      ),
    );
  }

  Widget _buildAudioPreview() {
    final duration = AudioConverter.calculateDuration(
      _selectedAudioBytes!,
      sampleRate: AudioConverter.targetSampleRate,
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: const Color(0xFF2a4a6c),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          // Audio icon
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: const Color(0xFF1a3a5c),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.audiotrack,
              color: Colors.white70,
              size: 32,
            ),
          ),
          const SizedBox(width: 12),

          // Audio information
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Audio Recording',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${AudioConverter.formatDuration(duration)} • ${(_selectedAudioBytes!.length / 1024).toStringAsFixed(1)} KB',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),

          // Delete button
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: _clearAudio,
            tooltip: 'Remove audio',
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingIndicator() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      decoration: BoxDecoration(
        color: const Color(0xFF4a1a1a),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          // Animated recording indicator
          Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),

          // Recording text and timer
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recording',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  AudioConverter.formatDuration(_recordingDuration),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),

          // Max duration indicator
          Text(
            'Max: ${AudioConverter.formatDuration(_maxRecordingDuration)}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
