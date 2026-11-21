plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val buildNumber = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()

android {
    namespace = "com.jarredsmith.glasseshub"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.jarredsmith.glasseshub"
        minSdk = 26
        targetSdk = 35
        versionCode = buildNumber
        versionName = "2.0"
        // The key for looking up subtitle files, put in by the build when there is one.
        buildConfigField("String", "SUBTITLE_KEY", "\"${System.getenv("SUBTITLE_KEY") ?: ""}\"")
    }
    signingConfigs {
        // Test builds are signed with a key kept in the repository so each one installs over the last.
        // A store release needs its own private key: set ANDROID_KEYSTORE_FILE and friends in the build.
        create("hub") {
            storeFile = file(System.getenv("ANDROID_KEYSTORE_FILE") ?: "../testing.keystore")
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: "glasseshub"
            keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "hub"
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: "glasseshub"
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("hub")
        }
        debug { signingConfig = signingConfigs.getByName("hub") }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    lint { checkReleaseBuilds = false; abortOnError = false }
}

dependencies {
    implementation(project(":core"))
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.navigation:navigation-compose:2.8.5")
}
