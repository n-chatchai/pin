allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    // Some plugins (e.g. receive_sharing_intent 1.8.x) still declare Java 8 while
    // their Kotlin compiles at 17 (inherited), which Gradle rejects as an
    // inconsistent JVM target. The app is on 17, so raise every Android
    // subproject's Java compatibility to 17 to match. Registered here (before the
    // evaluationDependsOn below forces evaluation) so afterEvaluate still fires.
    afterEvaluate {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
            ?.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
