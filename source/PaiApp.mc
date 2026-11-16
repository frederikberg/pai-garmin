import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

(:glance)
class PaiApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    (:typecheck(disableGlanceCheck))
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new StartView();
        return [view, new MessageDelegate(view)];
    }

    (:glanceView)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new PaiGlance()];
    }
}
