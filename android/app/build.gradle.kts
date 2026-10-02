plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.debloat"
    compileSdk = flutter.compileSdkVersion
    // Pin to the NDK that is actually installed locally (cmdline-tools is missing,
    // so Gradle cannot auto-download a different version).
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.debloat"
        // Wireless Debugging pairing (the 6-digit code flow) was introduced in
        // Android 11 (API 30), so that is the real floor for this app to work.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Signing with the debug keys for now, so `flutter build apk` works
            // out of the box. Keep R8 off so the ADB/crypto reflection paths stay intact.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/license.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/notice.txt",
                "META-INF/*.kotlin_module",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // On-device ADB client + Android 11 wireless-debugging pairing (SPAKE2 + TLS1.3).
    // This talks directly to the local adbd over the loopback interface — no PC adb
    // server required (unlike com.malinskiy.adam, which needs a running adb server).
    implementation("com.github.MuntashirAkon:libadb-android:3.1.1")
    // Conscrypt provides the TLS 1.3 stack adbd's TLS handshake needs.
    implementation("org.conscrypt:conscrypt-android:2.5.3")
    // NOTE: certificate generation is done in SelfSignedCert.kt using only java.security
    // (no BouncyCastle) to avoid the EdECObjectIdentifiers class conflict on some devices.
}
