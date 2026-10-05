import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'utils/audio_converter.dart';

class ChatMessageWidget extends StatelessWidget {
  const ChatMessageWidget({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    // Handle system info messages differently
    if (message.type == MessageType.systemInfo) {
      return _buildSystemMessage(context);
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10.0),
      child: Row(
        mainAxisAlignment: message.isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: <Widget>[
          message.isUser ? const SizedBox() : _buildAvatar(),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8,
              ),
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: const Color(0xFF1a4a7c), // Same as user messages
                borderRadius: BorderRadius.circular(12.0),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Display image if available
                  if (message.hasImage) ...[
                    _buildImageWidget(context),
                    if (message.text.isNotEmpty) const SizedBox(height: 8),
                  ],

                  // Display audio if available
                  if (message.hasAudio) ...[
                    _buildAudioWidget(message.audioBytes!),
                    if (message.text.isNotEmpty) const SizedBox(height: 8),
                  ],

                  // Display text
                  if (message.text.isNotEmpty)
                    MarkdownBody(
                      data: message.text,
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(
                          color: message.isUser ? Colors.white : Colors.white,
                          fontSize: 14,
                        ),
                        code: TextStyle(
                          backgroundColor: message.isUser
                              ? const Color(0xFF2a5a8c)
                              : const Color(0xFF404040),
                          color: Colors.white,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: message.isUser
                              ? const Color(0xFF2a5a8c)
                              : const Color(0xFF404040),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    )
                  else if (!message.hasImage && !message.hasAudio)
                    const Center(child: CircularProgressIndicator()),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          message.isUser ? _buildAvatar() : const SizedBox(),
        ],
      ),
    );
  }

  Widget _buildImageWidget(BuildContext context) {
    return GestureDetector(
      onTap: () => _showImageDialog(context),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300, maxHeight: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            message.imageBytes!,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                width: 200,
                height: 100,
                color: Colors.grey[300],
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error, color: Colors.red),
                    SizedBox(height: 4),
                    Text(
                      'Image loading error',
                      style: TextStyle(color: Colors.red, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAudioWidget(Uint8List audioBytes) {
    final duration = AudioConverter.calculateDuration(
      audioBytes,
      sampleRate: AudioConverter.targetSampleRate,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2a5a8c),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.audiotrack, color: Colors.white70, size: 20),
          const SizedBox(width: 8),
          Text(
            'Audio: ${AudioConverter.formatDuration(duration)}',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          const SizedBox(width: 8),
          Text(
            '(${(audioBytes.length / 1024).toStringAsFixed(1)} KB)',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }

  void _showImageDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Stack(
            children: [
              // Full-size image
              Center(
                child: InteractiveViewer(
                  child: Image.memory(message.imageBytes!, fit: BoxFit.contain),
                ),
              ),

              // Close button
              Positioned(
                top: 40,
                right: 20,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 30),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSystemMessage(BuildContext context) {
    IconData iconData;
    Color iconColor;

    // Determine icon based on message content
    if (message.text.contains('Calling')) {
      iconData = Icons.settings;
      iconColor = Colors.blue;
    } else if (message.text.contains('Executing')) {
      iconData = Icons.flash_on;
      iconColor = Colors.orange;
    } else if (message.text.contains('completed')) {
      iconData = Icons.check_circle;
      iconColor = Colors.green;
    } else if (message.text.contains('Generating')) {
      iconData = Icons.psychology;
      iconColor = Colors.purple;
    } else {
      iconData = Icons.info;
      iconColor = Colors.blue;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: <Widget>[
          const SizedBox(width: 58), // Same spacing as regular messages
          Expanded(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8,
              ),
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: const Color(0xFF1a4a7c), // Same as user messages
                borderRadius: BorderRadius.circular(12.0),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(iconData, size: 16, color: iconColor),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      message.text,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white, // White text on blue background
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    return message.isUser
        ? const CircleAvatar(
            backgroundColor: Color(0xFF1a4a7c),
            child: Icon(Icons.person, color: Colors.white),
          )
        : _circled('assets/gemma.png');
  }

  Widget _circled(String image) => CircleAvatar(
    backgroundColor: Colors.transparent,
    foregroundImage: AssetImage(image),
  );
}
