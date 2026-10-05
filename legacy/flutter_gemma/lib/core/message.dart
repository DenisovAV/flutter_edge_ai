import 'dart:convert';
import 'dart:typed_data';

enum MessageType {
  text,
  toolResponse,
  toolCall,
  systemInfo, // For function call indicators
  thinking, // For thinking mode content
}

class Message {
  const Message({
    required this.text,
    this.isUser = false,
    this.imageBytes,
    this.images = const [],
    this.audioBytes,
    this.type = MessageType.text,
    this.toolName,
  });

  final String text;
  final bool isUser;
  final Uint8List? imageBytes;
  final List<Uint8List> images;
  final Uint8List? audioBytes;
  final MessageType type;
  final String? toolName;

  bool get hasImage => imageBytes != null || images.isNotEmpty;
  bool get hasAudio => audioBytes != null;

  Message copyWith({
    String? text,
    bool? isUser,
    Uint8List? imageBytes,
    List<Uint8List>? images,
    Uint8List? audioBytes,
    MessageType? type,
    String? toolName,
  }) {
    return Message(
      text: text ?? this.text,
      isUser: isUser ?? this.isUser,
      imageBytes: imageBytes ?? this.imageBytes,
      images: images ?? this.images,
      audioBytes: audioBytes ?? this.audioBytes,
      type: type ?? this.type,
      toolName: toolName ?? this.toolName,
    );
  }

  factory Message.text({required String text, bool isUser = false}) {
    return Message(text: text, isUser: isUser);
  }

  factory Message.withImage({
    required String text,
    required Uint8List imageBytes,
    bool isUser = false,
  }) {
    return Message(
      text: text,
      imageBytes: imageBytes,
      images: [imageBytes],
      isUser: isUser,
    );
  }

  factory Message.withImages({
    required String text,
    required List<Uint8List> imageBytes,
    bool isUser = false,
  }) {
    return Message(
      text: text,
      imageBytes: imageBytes.isNotEmpty ? imageBytes.first : null,
      images: List<Uint8List>.from(imageBytes),
      isUser: isUser,
    );
  }

  factory Message.imageOnly({
    required Uint8List imageBytes,
    bool isUser = false,
    String text = '',
  }) {
    return Message(
      text: text,
      imageBytes: imageBytes,
      images: [imageBytes],
      isUser: isUser,
    );
  }

  factory Message.imagesOnly({
    required List<Uint8List> imageBytes,
    bool isUser = false,
    String text = '',
  }) {
    return Message(
      text: text,
      imageBytes: imageBytes.isNotEmpty ? imageBytes.first : null,
      images: List<Uint8List>.from(imageBytes),
      isUser: isUser,
    );
  }

  factory Message.withAudio({
    required String text,
    required Uint8List audioBytes,
    bool isUser = false,
  }) {
    return Message(text: text, audioBytes: audioBytes, isUser: isUser);
  }

  factory Message.audioOnly({
    required Uint8List audioBytes,
    bool isUser = false,
    String text = '',
  }) {
    return Message(text: text, audioBytes: audioBytes, isUser: isUser);
  }

  factory Message.toolResponse({
    required String toolName,
    required Map<String, dynamic> response,
  }) {
    // Tool responses are sent from the user's side.
    return Message(
      text: jsonEncode(response),
      toolName: toolName,
      type: MessageType.toolResponse,
      isUser: true,
    );
  }

  factory Message.toolCall({required String text}) {
    // Tool calls are from the model.
    return Message(text: text, type: MessageType.toolCall, isUser: false);
  }

  factory Message.systemInfo({required String text, String? icon}) {
    return Message(
      text: text,
      type: MessageType.systemInfo,
      isUser: false,
      toolName: icon, // Reuse toolName field for icon
    );
  }

  factory Message.thinking({required String text}) {
    return Message(text: text, type: MessageType.thinking, isUser: false);
  }

  @override
  String toString() {
    return 'Message(text: $text, isUser: $isUser, imageCount: ${images.isNotEmpty ? images.length : (imageBytes == null ? 0 : 1)}, hasAudio: $hasAudio, type: $type, toolName: $toolName)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Message &&
        other.text == text &&
        other.isUser == isUser &&
        _listEquals(other.imageBytes, imageBytes) &&
        _listEquals(other.images, images) &&
        _listEquals(other.audioBytes, audioBytes) &&
        other.type == type &&
        other.toolName == toolName;
  }

  @override
  int get hashCode =>
      text.hashCode ^
      isUser.hashCode ^
      imageBytes.hashCode ^
      Object.hashAll(images) ^
      audioBytes.hashCode ^
      type.hashCode ^
      toolName.hashCode;

  bool _listEquals<T>(List<T>? a, List<T>? b) {
    if (a == null) return b == null;
    if (b == null || a.length != b.length) return false;
    for (int index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}
