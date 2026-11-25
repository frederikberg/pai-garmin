import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

(:glance)
class PaiApp extends Application.AppBase {
    private var _fromGlance as Boolean = false;
    private var _how as String = "";
    // the uptime clock when the app was last hidden, null while it is on screen
    private var _hiddenAt as Number? = null;
    // tells the sub-app screen once the hide has lasted Home.KEEP_MS, so a call ends then and not
    // only when the app is opened again
    private var _hideJob as Number = 0;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        if (state != null) {
            var glance = state[:launchedFromGlance] as Object?;
            _fromGlance = glance instanceof Boolean && glance;
            _how = state.toString();
        }
    }

    // The app ends: why and after how long go into the log, and the lines this run did not get to
    // send are kept for the next launch. Back on the menu is the one way out of the app's own; any
    // other end (the glance list's timeout, another app, the watch itself) is the system's.
    (:typecheck(disableGlanceCheck))
    function onStop(state as Dictionary?) as Void {
        if (Trace.bornAt > 0) {
            Trace.add("exit", {"cause" => Trace.exitCause, "uptime_ms" => System.getTimer() - Trace.bornAt, "in_call" => Trace.active});
        }
        Trace.keep();
    }

    // The app is hidden but stays alive (the watch face, recent apps, an overlay).
    (:typecheck(disableGlanceCheck))
    function onInactive(state as Dictionary?) as Void {
        if (Trace.bornAt > 0) {
            _hiddenAt = System.getTimer();
            Home.covered = true;
            Trace.add("inactive", {"in_call" => Trace.active});
            Later.cancel(_hideJob);
            _hideJob = Later.at(Home.KEEP_MS, method(:onLongHide));
        }
    }

    // The screens stay as they are while hidden (a pop from a timer then ended in the watch's crash
    // screen): the sub-app on screen only ends what it runs, and the menu shows when the app is back.
    (:typecheck(false))
    function onLongHide() as Void {
        _hideJob = 0;
        if (_hiddenAt != null) {
            Trace.add("hide_timeout", {"in_call" => Trace.active});
            var target = Home.target;
            if (target != null && target has :hiddenTooLong) {
                target.hiddenTooLong();
            }
        }
    }

    // Back on screen: the screen it had after a short hide, the menu again, as after a fresh start,
    // after a long one.
    (:typecheck(disableGlanceCheck))
    function onActive(state as Dictionary?) as Void {
        var at = _hiddenAt;
        if (at == null) {
            return;
        }
        _hiddenAt = null;
        Home.covered = false;
        Later.cancel(_hideJob);
        _hideJob = 0;
        var away = System.getTimer() - at;
        var keep = Home.keepOnReturn(away);
        Trace.add("active", {"hidden_ms" => away, "in_call" => Trace.active, "kept" => keep});
        if (keep) {
            Home.closePending();
            WatchUi.requestUpdate();
        } else {
            Home.reset();
            Gate.arm();
        }
    }

    // The menu of sub-apps, however the app was opened, with Computer focused where the watch has audio.
    (:typecheck(disableGlanceCheck))
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Trace.bornAt = System.getTimer();
        Trace.restore();
        Gate.arm();
        Trace.add("launch", {"how" => _how, "glance" => _fromGlance});
        if (Outbox.pending()) {
            // a self-report an earlier run could not send goes once the menu has settled
            Idle.poke(Idle.DELAY_MS);
        }
        return Home.create();
    }

    (:glanceView)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new PaiGlance()];
    }
}
