import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

// The menu of sub-apps, the first screen however the app is opened, the one a hang-up returns to,
// and the one the app comes back to after it was hidden for KEEP_MS or longer. Computer comes first and is the focused
// entry, where the watch has audio, so one Start begins a call. It needs no request: nothing goes to
// the server until a sub-app is chosen.
module Home {
    // Any screen, a call included, stays through a hide shorter than this (a notification, the music
    // controls, a quick look at the watch face); a longer hide closes it.
    const KEEP_MS = 10000;
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

    // Whether the app, back after a hide of hiddenMs, keeps the screen it had.
    function keepOnReturn(hiddenMs as Number) as Boolean {
        return hiddenMs < KEEP_MS;
    }

    // Every screen above the menu is closed, one per tick, since the view stack changes only after
    // the current event; a call's screen hangs up as it closes. The menu keeps the entry chosen last
    // selected, so it is moved back to the first.
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
            var menu = Home.menu;
            if (menu != null) {
                menu.setFocus(0);
            }
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
        var id = item.getId();
        Trace.add("open", {"app" => id == :computer ? "computer" : id == :weather ? "weather" : id == :selfreport ? "selfreport" : "alarm"});
        if (id == :computer) {
            var computer = new ComputerView();
            WatchUi.pushView(computer, new ComputerDelegate(computer), WatchUi.SLIDE_LEFT);
        } else if (id == :weather) {
            var view = new WeatherView();
            WatchUi.pushView(view, new WeatherDelegate(view), WatchUi.SLIDE_LEFT);
        } else if (id == :selfreport) {
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
