package com.example.mazama_mobile

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

// specs/app-updates AU-R12, AU-R13: the channel `mazama/app_installer` (lib/app_installer.dart).
//   installed                    the installed app's versionName, versionCode, the phone's API level, the SHA-256 of
//                                each signing certificate, and whether "install unknown apps" is on for the app
//   inspect {path}               the same for a downloaded APK, read by Android from the file before any installer
//                                sees it (an unreadable file answers an empty package, which the app treats as a failed
//                                attempt, never a refusal)
//   openInstallSettings          Android's "install unknown apps" setting for this app
//   stage {path, sha256, size}   copies the APK into a new PackageInstaller session, hashing the bytes as they go, and
//                                abandons it unless they are exactly the signed size and SHA-256; answers
//                                `staged:<session id>` or `refused:<words>`. Earlier sessions of this app are abandoned
//                                first (one left by a killed attempt)
//   commit {session}             commits a staged session (the app calls it only after checking the carts again, review
//                                N3); the worker always confirms: setRequireUserAction is never called, so Android asks
//                                (STATUS_PENDING_USER_ACTION starts its confirmation, AppInstallReceiver)
//   abandon {session}            abandons a staged session (a cart line was added meanwhile)
//   takeStatus                   Android's words for a refusal after the commit (once), or null
// inspect and install read and copy up to 300 MiB, so they run on a background thread; the answer is posted back on the
// main thread.
class AppInstaller(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        // one background thread for the process, whatever activities come and go (review N2)
        private val background = Executors.newSingleThreadExecutor()
    }

    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installed" -> answer(result) { installed() }
            "inspect" -> {
                val path = call.argument<String>("path") ?: ""
                background.execute { answerOnMain(result) { inspect(path) } }
            }
            "openInstallSettings" -> answer(result) {
                openInstallSettings()
                null
            }
            "stage" -> {
                val path = call.argument<String>("path") ?: ""
                val sha256 = call.argument<String>("sha256") ?: ""
                val size = (call.argument<Any>("size") as? Number)?.toLong() ?: -1L
                background.execute { answerOnMain(result) { stage(path, sha256, size) } }
            }
            "commit" -> {
                val id = (call.argument<Any>("session") as? Number)?.toInt() ?: -1
                background.execute { answerOnMain(result) { commit(id) } }
            }
            "abandon" -> {
                val id = (call.argument<Any>("session") as? Number)?.toInt() ?: -1
                background.execute { answerOnMain(result) { abandon(id) } }
            }
            "takeStatus" -> answer(result) { takeStatus() }
            else -> result.notImplemented()
        }
    }

    private fun answer(result: MethodChannel.Result, work: () -> Any?) {
        try {
            result.success(work())
        } catch (e: Exception) {
            result.error("failed", e.javaClass.simpleName, null)
        }
    }

    private fun answerOnMain(result: MethodChannel.Result, work: () -> Any?) {
        try {
            val value = work()
            main.post { result.success(value) }
        } catch (e: Throwable) { // an Error too, so the Dart call never waits for ever (review N6)
            val name = e.javaClass.simpleName
            main.post { result.error("failed", name, null) }
        }
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun hexOf(sigs: Array<Signature>?): List<String> = sigs?.map { sha256Hex(it.toByteArray()) } ?: emptyList()

    @Suppress("DEPRECATION")
    private fun legacySigners(info: PackageInfo?): List<String> = hexOf(info?.signatures)

    private fun signers(info: PackageInfo): List<String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo
            if (signing != null) return hexOf(signing.apkContentsSigners)
        }
        return legacySigners(info)
    }

    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else @Suppress("DEPRECATION") info.versionCode.toLong()

    private fun packageInfo(flags: Int): PackageInfo {
        val pm = activity.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(activity.packageName, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION") pm.getPackageInfo(activity.packageName, flags)
        }
    }

    private fun archiveInfo(path: String, flags: Int): PackageInfo? {
        val pm = activity.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION") pm.getPackageArchiveInfo(path, flags)
        }
    }

    @Suppress("DEPRECATION")
    private val signaturesFlag: Int = PackageManager.GET_SIGNATURES

    private fun signingFlag(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES else signaturesFlag

    private fun installed(): Map<String, Any> {
        val info = packageInfo(signingFlag())
        val pm = activity.packageManager
        val canInstall = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) pm.canRequestPackageInstalls() else true
        return mapOf(
            "versionName" to (info.versionName ?: ""),
            "versionCode" to versionCode(info),
            "sdkInt" to Build.VERSION.SDK_INT,
            "signers" to signers(info),
            "canInstall" to canInstall,
        )
    }

    private fun inspect(path: String): Map<String, Any> {
        val info = archiveInfo(path, signingFlag())
            ?: return mapOf("package" to "", "versionCode" to 0L, "versionName" to "", "signers" to emptyList<String>())
        var found = signers(info)
        if (found.isEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // M3: some releases leave signingInfo empty for an archive; the older flag still reads its certificates
            found = legacySigners(archiveInfo(path, signaturesFlag))
        }
        return mapOf(
            "package" to info.packageName,
            "versionCode" to versionCode(info),
            "versionName" to (info.versionName ?: ""),
            "signers" to found,
        )
    }

    private fun openInstallSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + activity.packageName))
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        activity.startActivity(intent)
    }

    private fun stage(path: String, sha256: String, size: Long): String {
        val file = File(path)
        if (!file.isFile) return "refused:The downloaded update is missing."
        if (size <= 0 || !Regex("^[0-9a-f]{64}$").matches(sha256)) return "refused:The update's signed hash is missing."
        AppInstallStatus.take() // a refusal left from an earlier attempt is not this one's
        val installer = activity.packageManager.packageInstaller
        for (old in installer.mySessions) {
            try {
                installer.abandonSession(old.sessionId)
            } catch (ignored: Exception) {
            }
        }
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(activity.packageName)
        val sessionId = installer.createSession(params)
        val session = installer.openSession(sessionId)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var copied = 0L
            file.inputStream().use { input ->
                session.openWrite("update.apk", 0, size).use { output ->
                    val buffer = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        copied += n
                        if (copied > size) break
                        digest.update(buffer, 0, n)
                        output.write(buffer, 0, n)
                    }
                    session.fsync(output)
                }
            }
            val hex = digest.digest().joinToString("") { "%02x".format(it) }
            if (copied != size || hex != sha256) {
                session.abandon()
                return "refused:The downloaded update changed before it could be installed."
            }
        } catch (e: Exception) {
            session.abandon()
            return "refused:" + (e.message ?: "Android's installer refused the update.")
        } finally {
            session.close()
        }
        return "staged:$sessionId"
    }

    private fun commit(sessionId: Int): String {
        val installer = activity.packageManager.packageInstaller
        val session = try {
            installer.openSession(sessionId)
        } catch (e: Exception) {
            return "refused:The update was not ready to install."
        }
        try {
            val status = Intent(activity, AppInstallReceiver::class.java)
            val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            val pending = PendingIntent.getBroadcast(activity, sessionId, status, PendingIntent.FLAG_UPDATE_CURRENT or mutable)
            session.commit(pending.intentSender)
        } catch (e: Exception) {
            session.abandon()
            return "refused:" + (e.message ?: "Android's installer refused the update.")
        } finally {
            session.close()
        }
        return "started"
    }

    private fun abandon(sessionId: Int): String? {
        try {
            activity.packageManager.packageInstaller.abandonSession(sessionId)
        } catch (ignored: Exception) {
        }
        return null
    }

    private fun takeStatus(): String? = AppInstallStatus.take()
}

// Android's words for the last refusal after a commit, kept until the app asks (takeStatus).
object AppInstallStatus {
    @Volatile private var message: String? = null

    fun put(words: String) {
        message = words
    }

    fun take(): String? {
        val m = message
        message = null
        return m
    }
}

// The installer session's status (AppInstaller.install). On STATUS_PENDING_USER_ACTION it starts Android's own
// confirmation, after checking the intent is the installer's confirmation and taking away any URI grant; any other
// failure keeps Android's words for the card (takeStatus).
class AppInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_SUCCESS) return
        if (status == PackageInstaller.STATUS_FAILURE_ABORTED) {
            // the worker said no on Android's own screen (review N5): plain words, not Android's code
            AppInstallStatus.put("The update was not installed: it was cancelled on Android's screen. Tap Install to try again.")
            return
        }
        if (status != PackageInstaller.STATUS_PENDING_USER_ACTION) {
            AppInstallStatus.put(intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Android's installer refused the update.")
            return
        }
        val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }
        // Android 10 and later send CONFIRM_INSTALL, Android 9 and older CONFIRM_PERMISSIONS (review N1); either way it
        // must open a system app (the phone's own package installer), checked before it is started
        val confirmActions = setOf("android.content.pm.action.CONFIRM_INSTALL", "android.content.pm.action.CONFIRM_PERMISSIONS")
        if (confirm == null || confirm.action !in confirmActions || !opensSystemApp(context, confirm)) {
            AppInstallStatus.put("Android's installer did not ask to confirm the update.")
            return
        }
        confirm.flags = (confirm.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION).inv()) or
            Intent.FLAG_ACTIVITY_NEW_TASK
        context.startActivity(confirm)
    }

    private fun opensSystemApp(context: Context, intent: Intent): Boolean {
        val pm = context.packageManager
        val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.resolveActivity(intent, PackageManager.ResolveInfoFlags.of(0L))
        } else {
            @Suppress("DEPRECATION") pm.resolveActivity(intent, 0)
        }
        val app = resolved?.activityInfo?.applicationInfo ?: return false
        return (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0
    }
}
