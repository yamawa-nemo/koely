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

    // 古いプラグイン（namespace未指定）を新AGPでビルド可能に：
    // 各プラグインの AndroidManifest の package を namespace に補う（reflectionでAGP非依存）。
    // evaluationDependsOn より前に afterEvaluate を登録する必要がある。
    afterEvaluate {
        val androidExt = project.extensions.findByName("android")
        if (androidExt != null) {
            val getNs = androidExt.javaClass.methods.firstOrNull {
                it.name == "getNamespace" && it.parameterCount == 0
            }
            val current = runCatching { getNs?.invoke(androidExt) }.getOrNull()
            if (current == null) {
                val manifest = project.file("src/main/AndroidManifest.xml")
                if (manifest.exists()) {
                    val pkg = Regex("package=\"(.+?)\"")
                        .find(manifest.readText())?.groupValues?.getOrNull(1)
                    if (pkg != null) {
                        androidExt.javaClass.methods.firstOrNull {
                            it.name == "setNamespace" && it.parameterCount == 1
                        }?.invoke(androidExt, pkg)
                    }
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
