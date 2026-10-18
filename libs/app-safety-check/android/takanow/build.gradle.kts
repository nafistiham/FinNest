// TakaNow Loan demo fixture for the App Safety Check. Single-module project: this file is the app module,
// settings.gradle.kts next to it is the project root. No library dependencies on purpose.
plugins {
    id("com.android.application") version "8.7.3"
    id("org.jetbrains.kotlin.android") version "2.1.0"
}

android {
    namespace = "com.demo.takanow"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.demo.takanow"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    // Debug signing only: the demo is installed from a direct download link, never published.
    // `./gradlew assembleDebug` is the only build the README documents.
    buildTypes {
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
