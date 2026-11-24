import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

// The menu of sub-apps, the first screen however the app is opened, the one a hang-up returns to,
// and the one the app comes back to after it was hidden. Computer comes first and is the focused
// entry, where the watch has audio, so one Start begins a call. It needs no request: nothing goes to
// the server until a sub-app is chosen.
module Home {
    // A call stays up through a hide shorter than this (a notification, the music controls).
    const KEEP_CALL_MS = 10000;
    // Ticks a reset may take: more screens than the app ever stacks above the menu, with room for
    // slow pops.
    const MAX_DEPTH = 20;

    var menu as WatchUi.Menu2? = null;
    var resetsLeft as Number = 0;

    function create() as [WatchUi.Menu2, WatchUi.Menu2InputDelegate] {
        var menu = new WatchUi.Menu2({:title => "PAI"});
        Home.menu = menu;
        if (Toybox has :Audio) {
            menu.addItem(new WatchUi.MenuItem("Computer", null, :computer, null));
        }
        menu.addItem(new WatchUi.MenuItem("Weather", null, :weather, null));
        menu.addItem(new WatchUi.MenuItem("Alarm", null, :alarm, null));
        if (Toybox has :Audio) {
            menu.addItem(new WatchUi.MenuItem("Self-report", null, :selfreport, null));
        }
        return [menu, new HomeDelegate()];
    }

    // Whether the app, back after a hide of hiddenMs, keeps the screen it had: only a call does, and
    // only through a short hide. Everything else returns to the menu.
    function keepOnReturn(inCall as Boolean, hiddenMs as Number) as Boolean {
        return inCall && hiddenMs < KEEP_CALL_MS;
    }

    // Every screen above the menu is closed, one per tick, since the view stack changes only after
    // the current event; a call's screen hangs up as it closes.
    function reset() as Void {
        resetsLeft = MAX_DEPTH;
        new HomeReset().step();
    }
}

class HomeReset {
    const TICK_MS = 50;

    private var _timer as Timer.Timer = new Timer.Timer();
    // the screen popped last, which may still be on top for a tick
    private var _popped as WatchUi.View? = null;

    function step() as Void {
        var current = WatchUi.getCurrentView()[0];
        if (current == null || current == Home.menu || Home.resetsLeft <= 0) {
            WatchUi.requestUpdate();
            return;
        }
        Home.resetsLeft -= 1;
        if (current != _popped) {
            _popped = current;
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        }
        _timer.start(method(:step), TICK_MS, false);
    }
}

class HomeDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        Gate.disarm();
        if (item.getId() == :computer) {
            var computer = new ComputerView();
            WatchUi.pushView(computer, new ComputerDelegate(computer), WatchUi.SLIDE_LEFT);
        } else if (item.getId() == :weather) {
            var view = new WeatherView();
            WatchUi.pushView(view, new WeatherDelegate(view), WatchUi.SLIDE_LEFT);
        } else if (item.getId() == :selfreport) {
            var screen = SelfReportMenu.create();
            WatchUi.pushView(screen[0], screen[1], WatchUi.SLIDE_LEFT);
        } else {
            var list = new AlarmListView();
            WatchUi.pushView(list, new AlarmListDelegate(list), WatchUi.SLIDE_LEFT);
        }
    }

    // Back on the menu ends the app: the log says it was his.
    function onBack() as Void {
        Trace.exitCause = "back";
        Menu2InputDelegate.onBack();
    }
}
