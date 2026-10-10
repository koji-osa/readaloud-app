import java.security.KeyStore
import java.security.MessageDigest
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// 既存 Release (v1.2.23) の signer 証明書 SHA-256。署名継続性の期待値(鍵 rotation は対象外)。
val expectedReleaseCertSha256 = "c40d3d43e05e46a22119ad28f1343d93f9fe0ad912a44b2bb027be2a562ff568"
val keyPropsFile = rootProject.file("key.properties")
val keyProps = Properties().apply {
    if (keyPropsFile.isFile) keyPropsFile.inputStream().use { load(it) }
}

android {
    namespace = "com.example.readaloud_app"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.readaloud_app"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release 署名は repo 外の legacy keystore を android/key.properties で明示的に指す。
    // debug keystore (環境依存) には fallback しない。docs/RELEASE_SIGNING.md 参照。
    signingConfigs {
        create("release") {
            keyProps.getProperty("storeFile")?.let { storeFile = File(it) }
            storePassword = keyProps.getProperty("storePassword")
            keyAlias = keyProps.getProperty("keyAlias")
            keyPassword = keyProps.getProperty("keyPassword")
            enableV1Signing = false
            enableV2Signing = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// build 前: keystore の証明書 SHA-256 が期待値と一致しなければ fail-closed。
// 入力 (key.properties) が無い環境 (Codespaces 等) もここで止まる。
// password はログに出さない。debug build / flutter test / flutter run では実行されない。
val verifyReleaseSigningInputs = tasks.register("verifyReleaseSigningInputs") {
    doLast {
        fun fail(msg: String): Nothing =
            throw GradleException("Release signing: $msg (see docs/RELEASE_SIGNING.md)")
        if (!keyPropsFile.isFile) fail("android/key.properties not found; release builds require signing inputs")
        val missing = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .filter { keyProps.getProperty(it).isNullOrBlank() }
        if (missing.isNotEmpty()) fail("key.properties is missing: ${missing.joinToString()}")
        val storeFile = File(keyProps.getProperty("storeFile"))
        if (!storeFile.isAbsolute || !storeFile.isFile) fail("storeFile is not an existing absolute file path")
        val alias = keyProps.getProperty("keyAlias")
        val actual = try {
            val ks = KeyStore.getInstance(storeFile, keyProps.getProperty("storePassword").toCharArray())
            if (ks.getKey(alias, keyProps.getProperty("keyPassword").toCharArray()) == null) {
                fail("cannot read the private key for the alias")
            }
            val cert = ks.getCertificate(alias) ?: fail("no certificate for the alias")
            MessageDigest.getInstance("SHA-256").digest(cert.encoded)
                .joinToString("") { "%02x".format(it) }
        } catch (e: GradleException) {
            throw e
        } catch (e: Exception) {
            fail("cannot open keystore (${e.javaClass.simpleName})")
        }
        if (actual != expectedReleaseCertSha256) {
            fail("keystore certificate SHA-256 does not match the expected value (actual=$actual expected=$expectedReleaseCertSha256)")
        }
        logger.lifecycle("Release signing: keystore cert SHA-256 matches expected ($actual)")
    }
}
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(verifyReleaseSigningInputs)
}

// build 後: 完成した APK の signer を apksigner で検証する。
val sdkDirForVerify = android.sdkDirectory
val buildToolsForVerify = android.buildToolsVersion
val verifyReleaseApkSigner = tasks.register("verifyReleaseApkSigner") {
    doLast {
        val apks = layout.buildDirectory.dir("outputs/apk/release").get().asFile
            .listFiles { f -> f.extension == "apk" }.orEmpty()
        if (apks.size != 1) {
            throw GradleException("Release signing: cannot identify the release APK (${apks.size} found)")
        }
        val jar = File(sdkDirForVerify, "build-tools/$buildToolsForVerify/lib/apksigner.jar")
        if (!jar.isFile) throw GradleException("Release signing: apksigner.jar not found: $jar")
        val javaBin = File(System.getProperty("java.home"), "bin/java").path
        val proc = ProcessBuilder(javaBin, "-jar", jar.path, "verify", "--print-certs", apks[0].path)
            .redirectErrorStream(true).start()
        val out = proc.inputStream.bufferedReader().readText()
        if (proc.waitFor() != 0) {
            throw GradleException("Release signing: apksigner verify failed\n$out")
        }
        val digests = Regex("""certificate SHA-256 digest: ([0-9a-f]{64})""").findAll(out)
            .map { it.groupValues[1] }.toList()
        if (digests != listOf(expectedReleaseCertSha256)) {
            throw GradleException("Release signing: APK signer mismatch (actual=$digests expected=$expectedReleaseCertSha256)")
        }
        logger.lifecycle("Release signing: APK signer verified ($expectedReleaseCertSha256)")
    }
}
tasks.matching { it.name == "assembleRelease" }.configureEach {
    finalizedBy(verifyReleaseApkSigner)
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
