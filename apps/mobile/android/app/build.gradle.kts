plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase is initialised from Dart (firebase_options.dart); the google-services
// Gradle plugin is deliberately not applied so the app builds without
// google-services.json. See README.md, "Configuration".

android {
    namespace = "com.bhorosha.app"
    // Android 17 ships as minor SDK releases (platforms;android-37.0, 37.1, ...); there is no
    // plain "android-37" package any more. Naming the minor keeps AGP's SDK auto-download
    // working on a clean machine or CI. 37 is required by permission_handler.
    compileSdk = 37
    compileSdkMinor = 0

    // BuildConfig.DEBUG guards the package-name diagnostics in AppSafety.kt.
    buildFeatures {
        buildConfig = true
    }
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.bhorosha.app"
        minSdk = 28
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Demo only: the release APK is signed with the debug key so it can be
            // side-loaded. Use a real upload key before any store release.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.play:integrity:1.4.0")
    implementation("androidx.core:core-ktx:1.15.0")
}
