package com.anxcye.anx_reader

import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.Intent
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Ensure the latest intent is stored so plugins relying on Activity#getIntent can read it.
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INSTALL_INFO_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstallInfo" -> {
                    try {
                        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            packageManager.getPackageInfo(
                                packageName,
                                PackageManager.PackageInfoFlags.of(0),
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, 0)
                        }
                        result.success(
                            hashMapOf(
                                "firstInstallTime" to packageInfo.firstInstallTime,
                                "lastUpdateTime" to packageInfo.lastUpdateTime,
                            ),
                        )
                    } catch (e: Exception) {
                        result.error("PACKAGE_INFO_ERROR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EXTERNAL_DICTIONARY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "listHandlers" -> result.success(listProcessTextHandlers())
                "launch" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.error("INVALID_ARGUMENT", "Selected text is required", null)
                        return@setMethodCallHandler
                    }
                    val componentName = call.argument<String>("componentName")
                    result.success(launchProcessText(text, componentName))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun processTextIntent(text: String? = null): Intent =
        Intent(Intent.ACTION_PROCESS_TEXT).apply {
            type = "text/plain"
            if (text != null) {
                putExtra(Intent.EXTRA_PROCESS_TEXT, text)
                putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
            }
        }

    private fun processTextActivities() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                processTextIntent(),
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(
                processTextIntent(),
                PackageManager.MATCH_DEFAULT_ONLY,
            )
        }

    private fun listProcessTextHandlers(): List<Map<String, String>> =
        processTextActivities()
            .map { resolveInfo ->
                val activityInfo = resolveInfo.activityInfo
                val component = ComponentName(activityInfo.packageName, activityInfo.name)
                mapOf(
                    "label" to resolveInfo.loadLabel(packageManager).toString(),
                    "packageName" to activityInfo.packageName,
                    "activityName" to activityInfo.name,
                    "componentName" to component.flattenToString(),
                )
            }
            .distinctBy { it.getValue("componentName") }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.getValue("label") })

    private fun launchProcessText(text: String, requestedComponent: String?): String {
        val handlers = processTextActivities()
        if (handlers.isEmpty()) return "noHandlers"

        val intent = processTextIntent(text)
        if (requestedComponent != null) {
            val component = ComponentName.unflattenFromString(requestedComponent)
                ?: return "handlerUnavailable"
            val isAvailable = handlers.any {
                it.activityInfo.packageName == component.packageName &&
                    it.activityInfo.name == component.className
            }
            if (!isAvailable) return "handlerUnavailable"
            intent.component = component
        }

        return try {
            val launchIntent = if (requestedComponent == null) {
                Intent.createChooser(intent, "Dictionary")
            } else {
                intent
            }
            startActivity(launchIntent)
            "launched"
        } catch (_: Exception) {
            "failed"
        }
    }

    companion object {
        private const val INSTALL_INFO_CHANNEL = "com.anxcye.anx_reader/install_info"
        private const val EXTERNAL_DICTIONARY_CHANNEL =
            "com.anxcye.anx_reader/external_dictionary"
    }
}
