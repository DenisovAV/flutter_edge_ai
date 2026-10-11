# GGUF Lab

Text-chat example for the [Flutter Edge AI llamadart connector](../README.md),
with runners for Android, iOS, macOS, Windows, Linux and Web.

The demo packages CPU inference on Android, Linux and Windows through its
`hooks.user_defines.llamadart.llamadart_native_backends.platforms` settings.
Apps can select and qualify optional GPU backends in their own configuration.

```sh
flutter pub get
flutter run -d macos
# Use your Android/iOS device ID, windows or linux on the corresponding host.
# Web:
cd ..
python3 tool/fetch_web_assets.py
cd example
flutter run -d chrome \
  --web-header Cross-Origin-Opener-Policy=same-origin \
  --web-header Cross-Origin-Embedder-Policy=require-corp
```

**Choose model** copies a GGUF file into durable app-owned storage. The original
is preserved, so allow disk space for the import. The installed model resumes
at startup. On Web, enter a CORS-enabled GGUF URL and use **Load URL**.

**Stop** discards the interrupted turn, allowing another message. Backgrounding
the native app also stops generation. **New chat** clears history. Text updates
are buffered to at most 30 refreshes per second, and the composer stays visible
with a phone keyboard. Backend identity and missing usage are reported honestly.

Tools, thinking, media, embeddings and native LoRA are exposed through the
connector API; this UI focuses on text chat. See [qualification and consumer
setup](../doc/platforms.md) before claiming device/backend support or deploying.
