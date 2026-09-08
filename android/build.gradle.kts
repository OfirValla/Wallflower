allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Flutter's standard out-of-tree build directory layout.
rootProject.layout.buildDirectory.value(rootProject.layout.buildDirectory.dir("../../build").get())

subprojects {
    project.layout.buildDirectory.value(
        rootProject.layout.buildDirectory.dir(project.name).get(),
    )
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
