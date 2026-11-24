import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

(:glance)
class PaiApp extends Application.AppBase {
    private var _fromGlance as Boolean = false;
    private var _how as String = "";

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

    // The menu of sub-apps, however the app was opened, with Computer focused where the watch has audio.
    (:typecheck(disableGlanceCheck))
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Trace.bornAt = System.getTimer();
        Trace.restore();
        Gate.start();
        Trace.add("launch", {"how" => _how, "glance" => _fromGlance});
        return Home.create();
    }

    (:glanceView)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new PaiGlance()];
    }
}
