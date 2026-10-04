# MediaPipe and protobuf
-keep class com.google.mediapipe.** { *; }
-keep class com.google.mediapipe.proto.** { *; }
-keepclassmembers class com.google.mediapipe.tasks.genai.llminference.LlmInference { *; }

# Protocol Buffers
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**

# Classes MediaPipe references but does not ship. Without these R8 fails the
# app's release build with "Missing class" (measured with AGP 9.1). AutoValue's
# annotations have CLASS or SOURCE retention and are never loaded at run time,
# and nothing in tasks-genai or this plugin calls the methods that use the two
# protos.
-dontwarn com.google.auto.value.**
-dontwarn com.google.mediapipe.proto.CalculatorProfileProto$CalculatorProfile
-dontwarn com.google.mediapipe.proto.GraphTemplateProto$CalculatorGraphTemplate
