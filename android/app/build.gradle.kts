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
    testOptions { unitTests { isIncludeAndroidResources = true; isReturnDefaultValues = true } }
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
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// The tests draw the app's screens on a copy of Android that runs on any computer. Gradle fetches that
// copy like any other dependency, so the tests don't need to reach the internet themselves.
val androidAll by configurations.creating
dependencies {
    androidAll("org.robolectric:android-all-instrumented:14-robolectric-10818077-i7")
    androidAll("org.robolectric:android-all-instrumented:15-robolectric-12650502-i7")
}
val androidAllFolder = layout.buildDirectory.dir("android-all")
val fetchAndroidAll by tasks.registering(Sync::class) {
    from(androidAll)
    into(androidAllFolder)
}
tasks.withType<Test>().configureEach {
    dependsOn(fetchAndroidAll)
    systemProperty("robolectric.offline", "true")
    systemProperty("robolectric.dependency.dir", androidAllFolder.get().asFile.absolutePath)
    testLogging { exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}
