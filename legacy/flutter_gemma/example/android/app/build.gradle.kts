import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

val flutterVersionCode = localProperties.getProperty("flutter.versionCode") ?: "1"
val flutterVersionName = localProperties.getProperty("flutter.versionName") ?: "1.0"

android {
    namespace = "dev.flutterberlin.flutter_gemma_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    aaptOptions {
        noCompress("tflite", "safetensors", "bin", "model", "task")
    }

    compileOptions {
        // flutter_local_notifications (agent native-intent: schedule_notification)
        // requires core library desugaring on Android.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.flutterberlin.flutter_gemma_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Raised to 26 for flutter_gemma_builtin_ai (Gemini Nano via ML Kit
        // GenAI / AICore requires API 26+); the manifest merger rejects a lower
        // app minSdk against the library's declared minSdk 26.
        minSdk = 26
        targetSdk = 34
        versionCode = flutterVersionCode.toInt()
        versionName = flutterVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Enable minification but with basic rules only
            isMinifyEnabled = true
            isShrinkResources = false  // Disable resource shrinking to avoid MediaPipe issues
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required by flutter_local_notifications (agent schedule_notification intent).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

