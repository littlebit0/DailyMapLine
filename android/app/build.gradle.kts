plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.kimhwi.dailymapline"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.kimhwi.dailymapline"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Map and routing data are large binary assets; never compress them so they can be copied fast.
    androidResources { noCompress += listOf("pmtiles", "tar", "pbf") }
    // Shares the iOS map, glyph and routing resources instead of keeping a second copy.
    sourceSets["main"].assets.srcDirs("../../ios/DailyMapLine/Resources")
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    implementation(project(":core"))
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.navigation:navigation-compose:2.8.5")
    implementation("androidx.media3:media3-exoplayer:1.5.1")
    implementation("androidx.media3:media3-ui:1.5.1")
    implementation("org.maplibre.gl:android-sdk:11.8.0")
    implementation("io.github.rallista:valhalla-mobile:0.6.4")
    implementation("io.github.rallista:valhalla-models:0.6.0")
    implementation("io.github.rallista:valhalla-models-config:0.6.0")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
