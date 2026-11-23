import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

(:glance)
class PaiApp extends Application.AppBase {
    private var _stored as StoredLog? = null;

    function initialize() {
        AppBase.initialize();
    }

    // The last lines of this run are kept for the next launch.
    (:typecheck(disableGlanceCheck))
    function onStop(state as Dictionary?) as Void {
        if (Trace.lines.size() > 0) {
            Trace.persist();
        }
    }

    (:typecheck(disableGlanceCheck))
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Gate.start();
        var stored = new StoredLog();
        _stored = stored;
        stored.start();
        return Home.create();
    }

    (:glanceView)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new PaiGlance()];
    }
}
