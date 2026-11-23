import Toybox.Application;
import Toybox.Graphics;
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

    // The lines this run did not get to send are kept for the next launch.
    (:typecheck(disableGlanceCheck))
    function onStop(state as Dictionary?) as Void {
        Trace.keep();
    }

    // Computer at once where the setting and the way the app was opened say so, with the microphone
    // started here; the menu otherwise.
    (:typecheck(disableGlanceCheck))
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Trace.bornAt = System.getTimer();
        Trace.restore();
        Gate.start();
        // a unit test run starts the app too, and must not start a call
        var computer = !($ has :UnderTest) && ServerConfig.opensComputer(ServerConfig.openWith(), _fromGlance, Toybox has :Audio);
        Trace.add("launch", {"how" => _how, "glance" => _fromGlance, "open_with" => ServerConfig.openWith(), "computer" => computer});
        if (computer) {
            return [new Launcher(), new WatchUi.BehaviorDelegate()];
        }
        return Home.create();
    }

    (:glanceView)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new PaiGlance()];
    }
}

// The first view of a launch that goes straight to Computer: it puts the Computer screen on top of
// itself, and when that screen leaves, the app ends, or the menu takes this view's place if the menu
// was asked for there.
(:typecheck(false))
class Launcher extends WatchUi.View {
    private var _computer as ComputerView;
    private var _pushed as Boolean = false;

    function initialize() {
        View.initialize();
        // the microphone starts here, before anything is drawn
        _computer = new ComputerView(true);
    }

    function onShow() as Void {
        if (!_pushed) {
            _pushed = true;
            WatchUi.pushView(_computer, new ComputerDelegate(_computer), WatchUi.SLIDE_IMMEDIATE);
        } else if (_computer.wantsMenu()) {
            var home = Home.create();
            WatchUi.switchToView(home[0], home[1], WatchUi.SLIDE_IMMEDIATE);
        } else {
            Trace.keep();
            System.exit();
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
    }
}
