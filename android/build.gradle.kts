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
}
// Some plugins (permission_handler_android 14.x) declare `compileSdk = 37`, which AGP resolves
// as "android-37", but the SDK ships that platform as "android-37.0". Point them at it.
fun Project.fixCompileSdk37() {
    val ext = extensions.findByName("android")
    if (ext is com.android.build.api.dsl.LibraryExtension && ext.compileSdk == 37) {
        ext.compileSdk { version = release(37) { minorApiLevel = 0 } }
    }
}
subprojects {
    if (state.executed) fixCompileSdk37() else afterEvaluate { fixCompileSdk37() }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

