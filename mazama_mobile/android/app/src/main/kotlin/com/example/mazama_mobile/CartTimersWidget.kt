package com.example.mazama_mobile

// The cart timers home-screen widget (specs/multi-cart MC-D15): every cart's running session timer at the center the
// app was last on. The app sends a snapshot over the "mazama/cart_timer_widget" channel (lib/cart_timer_widget.dart)
// whenever a timer, a cart's lines or the list of carts changes; it holds moments (when each timer started, when its
// session ends), never durations, so the rows count on their own with Chronometer while the app is closed.
//
// Nothing here decides a number: the session length comes worked out from the app (endMs). This only draws it.

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date

/** One running timer from the app's snapshot. [endMs] is null when its dose gives no session length: it counts up. */
data class CartTimer(val name: String, val startMs: Long, val endMs: Long?, val booster: Boolean)

/** The app's snapshot (cartTimerSnapshot in lib/cart_timer_widget.dart). */
data class CartTimersSnapshot(val center: String, val maxAgeMs: Long, val carts: List<CartTimer>) {
    /** The timers still running at [nowMs]: one past maxAge is reset by the app (sessionTimerMaxAge), so it's gone. */
    fun running(nowMs: Long): List<CartTimer> = carts.filter { nowMs - it.startMs < maxAgeMs }

    /** The next moment a row changes by itself: a session running out (left -> over), or a timer aging out. */
    fun nextChange(nowMs: Long): Long? =
        carts.flatMap { listOfNotNull(it.endMs, it.startMs + maxAgeMs) }.filter { it > nowMs }.minOrNull()

    companion object {
        const val VERSION = 1

        /** Null for anything the app didn't write in this version. */
        fun parse(json: String?): CartTimersSnapshot? {
            if (json == null) return null
            return try {
                val o = JSONObject(json)
                if (o.optInt("version") != VERSION) return null
                val arr = o.getJSONArray("carts")
                val carts = (0 until arr.length()).map { i ->
                    val c = arr.getJSONObject(i)
                    CartTimer(
                        name = c.getString("name"),
                        startMs = c.getLong("startMs"),
                        endMs = if (c.has("endMs") && !c.isNull("endMs")) c.getLong("endMs") else null,
                        booster = c.optBoolean("booster", false),
                    )
                }
                CartTimersSnapshot(o.optString("center", ""), o.getLong("maxAgeMs"), carts)
            } catch (e: Exception) {
                null
            }
        }
    }
}

/** Where the last snapshot is kept, so the widget can be drawn with the app closed. */
object CartTimersStore {
    private const val PREFS = "mazama_cart_timers_widget"
    private const val KEY = "snapshot"

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun save(context: Context, json: String) = prefs(context).edit().putString(KEY, json).apply()

    fun clear(context: Context) = prefs(context).edit().remove(KEY).apply()

    fun load(context: Context): CartTimersSnapshot? = CartTimersSnapshot.parse(prefs(context).getString(KEY, null))
}

/** The native end of "mazama/cart_timer_widget": "update" (the snapshot as a JSON string) and "clear". */
class CartTimersChannel(context: Context) : MethodChannel.MethodCallHandler {
    private val context = context.applicationContext

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "update" -> {
                val json = call.arguments as? String
                if (CartTimersSnapshot.parse(json) == null) {
                    result.error("BAD_SNAPSHOT", "The cart timers snapshot couldn't be read.", null)
                    return
                }
                CartTimersStore.save(context, json!!)
                CartTimersWidgetProvider.refresh(context)
                result.success(null)
            }
            "clear" -> {
                CartTimersStore.clear(context)
                CartTimersWidgetProvider.refresh(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

class CartTimersWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        draw(context, appWidgetManager, appWidgetIds)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            // The alarm set below, the clock or zone being changed, and a restart (which resets the elapsedRealtime
            // clock every Chronometer counts on, and drops the alarm): every base is worked out again.
            ACTION_REFRESH, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_BOOT_COMPLETED ->
                refresh(context)
        }
    }

    override fun onDisabled(context: Context) {
        alarms(context).cancel(refreshIntent(context))
    }

    companion object {
        private const val ACTION_REFRESH = "com.example.mazama_mobile.CART_TIMERS_REFRESH"

        // One row per cart a center may have (cart_slots.dart maxCartsPerCenter): see layout/cart_timers_widget.xml.
        private val ROWS = intArrayOf(
            R.id.cart_timer_row0, R.id.cart_timer_row1, R.id.cart_timer_row2, R.id.cart_timer_row3, R.id.cart_timer_row4,
            R.id.cart_timer_row5, R.id.cart_timer_row6, R.id.cart_timer_row7, R.id.cart_timer_row8, R.id.cart_timer_row9,
        )
        private val NAMES = intArrayOf(
            R.id.cart_timer_name0, R.id.cart_timer_name1, R.id.cart_timer_name2, R.id.cart_timer_name3, R.id.cart_timer_name4,
            R.id.cart_timer_name5, R.id.cart_timer_name6, R.id.cart_timer_name7, R.id.cart_timer_name8, R.id.cart_timer_name9,
        )
        private val CLOCKS = intArrayOf(
            R.id.cart_timer_clock0, R.id.cart_timer_clock1, R.id.cart_timer_clock2, R.id.cart_timer_clock3, R.id.cart_timer_clock4,
            R.id.cart_timer_clock5, R.id.cart_timer_clock6, R.id.cart_timer_clock7, R.id.cart_timer_clock8, R.id.cart_timer_clock9,
        )
        private val NOTES = intArrayOf(
            R.id.cart_timer_note0, R.id.cart_timer_note1, R.id.cart_timer_note2, R.id.cart_timer_note3, R.id.cart_timer_note4,
            R.id.cart_timer_note5, R.id.cart_timer_note6, R.id.cart_timer_note7, R.id.cart_timer_note8, R.id.cart_timer_note9,
        )

        private val immutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

        /** Redraws every cart timers widget on the home screen from the stored snapshot. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, CartTimersWidgetProvider::class.java))
            if (ids.isEmpty()) {
                alarms(context).cancel(refreshIntent(context))
                return
            }
            draw(context, manager, ids)
        }

        private fun draw(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val nowMs = System.currentTimeMillis()
            val nowRealtime = SystemClock.elapsedRealtime()
            val snapshot = CartTimersStore.load(context)
            val running = snapshot?.running(nowMs).orEmpty()

            val views = RemoteViews(context.packageName, R.layout.cart_timers_widget)
            val center = snapshot?.center.orEmpty()
            views.setTextViewText(
                R.id.cart_timers_title,
                if (center.isBlank()) context.getString(R.string.cart_timers_widget_title)
                else context.getString(R.string.cart_timers_widget_title_center, center),
            )
            views.setViewVisibility(R.id.cart_timers_empty, if (running.isEmpty()) View.VISIBLE else View.GONE)
            for (i in ROWS.indices) {
                val timer = running.getOrNull(i)
                if (timer == null) {
                    views.setViewVisibility(ROWS[i], View.GONE)
                    views.setChronometer(CLOCKS[i], nowRealtime, null, false)
                    continue
                }
                views.setViewVisibility(ROWS[i], View.VISIBLE)
                views.setTextViewText(NAMES[i], timer.name)
                drawClock(context, views, i, timer, nowMs, nowRealtime)
            }
            views.setOnClickPendingIntent(R.id.cart_timers_root, openApp(context))
            manager.updateAppWidget(ids, views)
            schedule(context, snapshot?.nextChange(nowMs))
        }

        /**
         * One row's clock, as the app's carts list words it (MC-D14): counting down to the session's end ("left", "left
         * w/ booster"), then up from it ("over · time up"); with no session length, up from the start ("elapsed").
         */
        private fun drawClock(context: Context, views: RemoteViews, i: Int, timer: CartTimer, nowMs: Long, nowRealtime: Long) {
            // A Chronometer counts from a base on the elapsedRealtime clock: where a wall-clock moment falls on it.
            fun base(atMs: Long) = nowRealtime + (atMs - nowMs)
            val end = timer.endMs
            val over = end != null && nowMs >= end
            val note: String
            when {
                end != null && !over && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N -> {
                    views.setChronometer(CLOCKS[i], base(end), null, true)
                    views.setChronometerCountDown(CLOCKS[i], true)
                    note = context.getString(if (timer.booster) R.string.cart_timers_note_left_booster else R.string.cart_timers_note_left)
                }
                end != null && over -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) views.setChronometerCountDown(CLOCKS[i], false)
                    views.setChronometer(CLOCKS[i], base(end), null, true)
                    note = context.getString(R.string.cart_timers_note_over)
                }
                else -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) views.setChronometerCountDown(CLOCKS[i], false)
                    views.setChronometer(CLOCKS[i], base(timer.startMs), null, true)
                    // Android 6 and older can't count down: count up, and say when the session ends.
                    note = if (end == null) context.getString(R.string.cart_timers_note_elapsed)
                    else context.getString(R.string.cart_timers_note_ends, DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(end)))
                }
            }
            views.setTextViewText(NOTES[i], note)
            // Set every time, not only when over: a launcher re-applies an update onto the views it already has, so
            // a row that was red for an earlier cart would stay red.
            textColor(context, views, CLOCKS[i], if (over) R.color.cart_timers_over else R.color.cart_timers_text)
            textColor(context, views, NOTES[i], if (over) R.color.cart_timers_over else R.color.cart_timers_subtle)
        }

        /** From Android 12 the launcher resolves [colorRes], so it follows a later switch to dark mode. */
        private fun textColor(context: Context, views: RemoteViews, viewId: Int, colorRes: Int) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                views.setColorStateList(viewId, "setTextColor", colorRes)
            } else {
                views.setTextColor(viewId, ContextCompat.getColor(context, colorRes))
            }
        }

        private fun openApp(context: Context): PendingIntent {
            val intent = (context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or immutable)
        }

        private fun alarms(context: Context) = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        private fun refreshIntent(context: Context): PendingIntent {
            val intent = Intent(context, CartTimersWidgetProvider::class.java).setAction(ACTION_REFRESH)
            return PendingIntent.getBroadcast(context, 1, intent, PendingIntent.FLAG_UPDATE_CURRENT or immutable)
        }

        /**
         * Wakes the widget at [atMs] to redraw a row that changes then (a countdown reaching zero, a timer aging out).
         * Exact before Android 12. From 12 an app needs a special permission for exact alarms, which a widget doesn't
         * justify, so it's a window; Android 12 stretches any window shorter than 10 minutes to 10, so the change can
         * come up to ~10 minutes late; meanwhile a countdown that has
         * passed zero shows as negative ("−00:42"). Not a wake-up alarm: an idle, dark phone waits for the screen.
         */
        private fun schedule(context: Context, atMs: Long?) {
            val alarms = alarms(context)
            val pending = refreshIntent(context)
            alarms.cancel(pending)
            if (atMs == null) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                alarms.setWindow(AlarmManager.RTC, atMs, 60_000L, pending)
            } else {
                alarms.setExact(AlarmManager.RTC, atMs, pending)
            }
        }
    }
}
