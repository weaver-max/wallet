import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("maven-publish")
}

val gemstoneRoot = project.projectDir.resolve("../..")
val rustSrcDir = gemstoneRoot.resolve("src")
val cratesDir = gemstoneRoot.resolve("../crates")
val jniLibsDir = project.projectDir.resolve("src/main/jniLibs")
val generatedKotlinDir = project.projectDir.resolve("src/main/java")
val cargoBuildFlag = if (System.getenv("BUILD_MODE") == "release") "--release" else null

// 版本号与 core/Cargo.toml 的 workspace version 对齐，避免手动维护两处。
// release.sh 会显式传 VER_NAME；本机手动发布时回退到读 Cargo.toml。
val coreVersion: String by lazy {
    System.getenv("VER_NAME")
        ?: gemstoneRoot.resolve("../Cargo.toml").readLines()
            .first { it.trimStart().startsWith("version") }
            .substringAfter('"').substringBefore('"')
}

// 发布目标仓库。GitHub Packages 的 Maven registry 挂在仓库下，与源码无关。
val githubPackagesRepo: String = System.getenv("GITHUB_PACKAGES_REPO") ?: "weaver-max/wallet"

android {
    namespace = "com.gemwallet.gemstone"
    compileSdk = 37

    defaultConfig {
        minSdk = 28

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
            withJavadocJar()
        }
        singleVariant("debug") {
            withSourcesJar()
            withJavadocJar()
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs(generatedKotlinDir)
            jniLibs.srcDirs(jniLibsDir)
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

val bindgenKotlin = tasks.register<Exec>("bindgenKotlin") {
    description = "Generate Kotlin bindings from gemstone via uniffi"
    workingDir = gemstoneRoot
    inputs.dir(rustSrcDir)
    inputs.dir(cratesDir)
    inputs.file(gemstoneRoot.resolve("Cargo.toml"))
    outputs.dir(generatedKotlinDir.resolve("uniffi"))
    commandLine("just", "bindgen-kotlin")
}

val buildCargoNdk = tasks.register<Exec>("buildCargoNdk") {
    description = "Build gemstone native libraries using cargo-ndk"
    workingDir = gemstoneRoot
    inputs.dir(rustSrcDir)
    inputs.dir(cratesDir)
    inputs.file(gemstoneRoot.resolve("Cargo.toml"))
    inputs.property("cargoBuildFlag", cargoBuildFlag.orEmpty())
    outputs.dir(jniLibsDir)
    commandLine(
        "cargo", "ndk",
        "-t", "arm64-v8a",
        "-t", "armeabi-v7a",
        "-t", "x86_64",
        "-o", jniLibsDir.absolutePath,
        "build", "--lib"
    )
    cargoBuildFlag?.let { args(it) }
}

tasks.configureEach {
    if (name.matches(Regex("(compile|extract|source|javaDoc).*(Debug|Release).*"))) {
        dependsOn(bindgenKotlin)
    }
    if (name.matches(Regex("merge.*(Debug|Release).*JniLib.*"))) {
        dependsOn(buildCargoNdk)
    }
}

dependencies {
    api("net.java.dev.jna:jna:5.18.1@aar")

    implementation("androidx.core:core-ktx:1.17.0")

    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "com.gemwallet.gemstone"
                artifactId = "gemstone"
                version = coreVersion
            }
            create<MavenPublication>("debug") {
                from(components["debug"])
                groupId = "com.gemwallet.gemstone"
                artifactId = "gemstone-debug"
                version = "$coreVersion-debug"
            }
        }

        // 发布目标。没有这个块 Gradle 只会生成 publishXxxToMavenLocal，推不了远端。
        // task 名由 name 决定：publishReleasePublicationToGitHubPackagesRepository
        repositories {
            maven {
                name = "GitHubPackages"
                url = uri("https://maven.pkg.github.com/$githubPackagesRepo")
                credentials {
                    username = System.getenv("GITHUB_ACTOR")
                        ?: providers.gradleProperty("gpr.user").orNull
                    password = System.getenv("GITHUB_TOKEN")
                        ?: providers.gradleProperty("gpr.token").orNull
                }
            }
        }
    }
}
