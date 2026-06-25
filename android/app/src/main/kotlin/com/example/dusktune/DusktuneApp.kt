package com.example.dusktune

import android.app.Application
import android.os.Bundle
import android.os.Process
import android.util.Log

/**
 * Custom Application that tracks activity lifecycle to detect when the app
 * is being closed (swiped away from recent apps). When all activities are
 * destroyed, kills the process to stop mpv playback.
 *
 * This works independently of MpvMediaSessionService.onTaskRemoved which may
 * not fire for mediaPlayback foreground services on some Android versions.
 */
class DusktuneApp : Application() {

    private companion object {
        const val TAG = "DuskTune"
    }

    private var activityCount = 0

    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: android.app.Activity, savedInstanceState: Bundle?) {
                activityCount++
                Log.d(TAG, "Activity created (count=$activityCount)")
            }

            override fun onActivityStarted(activity: android.app.Activity) {}
            override fun onActivityResumed(activity: android.app.Activity) {}
            override fun onActivityPaused(activity: android.app.Activity) {}
            override fun onActivityStopped(activity: android.app.Activity) {}
            override fun onActivitySaveInstanceState(activity: android.app.Activity, outState: Bundle) {}

            override fun onActivityDestroyed(activity: android.app.Activity) {
                activityCount--
                Log.d(TAG, "Activity destroyed (count=$activityCount)")
                if (activityCount <= 0) {
                    Log.e(TAG, "All activities destroyed — killing process to stop playback")
                    Process.killProcess(Process.myPid())
                }
            }
        })
    }
}
