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
    // a reset is closing screens: a second one waits for it rather than popping the same screen again
    var resetting as Boolean = false;
    // the app is hidden (onInactive until onActive): the screens are left as they are then (a pop
    // from a timer while hidden ended in the watch's crash screen)
    var covered as Boolean = false;
    // the sub-app screen told when a hide lasts KEEP_MS (it has hiddenTooLong), null when none is up
    var target as Object? = null;
    // a screen that wanted to close while it was not on top (hidden, under a notification or its own
    // menu); it closes once it is shown again
    var pendingPop as Object? = null;

    function create() as [WatchUi.Menu2, WatchUi.Menu2InputDelegate] {
        var menu = new WatchUi.Menu2({:title => "PAI"});
        Home.menu = menu;
        if (Toybox has :Audio) {
            menu.addItem(new WatchUi.MenuItem("Computer", null, :computer, null));
        }
        menu.addItem(new WatchUi.MenuItem("Weather", null, :weather, null));
        menu.addItem(new WatchUi.MenuItem("Alarm", null, :alarm, null));
        if (Toybox has :Audio) {
            menu.addItem(new WatchUi.MenuItem("Self-report", waitingLabel(Outbox.count()), :selfreport, null));
        }
        return [menu, new HomeDelegate()];
    }

    // The Self-report entry's second line: how many recordings wait on the watch, none when none do.
    function waitingLabel(count as Number) as String? {
        return count > 0 ? count + " waiting" : null;
    }

    // The number of waiting recordings changed: the entry says so.
    function showWaiting(count as Number) as Void {
        var m = menu;
        if (m == null) {
            return;
        }
        var index = m.findItemById(:selfreport);
        if (index >= 0) {
            var item = m.getItem(index);
            if (item != null) {
                item.setSubLabel(waitingLabel(count));
                redraw();
            }
        }
    }

    // Whether the app, back after a hide of hiddenMs, keeps the screen it had.
    function keepOnReturn(hiddenMs as Number) as Boolean {
        return hiddenMs < KEEP_MS;
    }

    // Asks for a redraw, except while hidden.
    function redraw() as Void {
        if (!covered) {
            WatchUi.requestUpdate();
        }
    }

    // A screen closes itself: now when it is on screen, else once it is shown again (shown says
    // whether the watch has it on screen: a notification or a menu on top hides it).
    function close(view as Object, shown as Boolean) as Void {
        if (covered || !shown || WatchUi.getCurrentView()[0] != view) {
            pendingPop = view;
        } else {
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
    }

    // A screen is on screen again: if it wanted to close meanwhile, it closes now, just after this
    // event. Nothing while hidden or while a reset closes the screens itself.
    function showing(view as Object) as Void {
        if (pendingPop == view && !covered && !resetting) {
            Later.at(0, new HomeClose().method(:run));
        }
    }

    function closePending() as Void {
        var view = pendingPop;
        pendingPop = null;
        if (view != null && !covered && !resetting && WatchUi.getCurrentView()[0] == view) {
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
    }

    // Every screen above the menu is closed, one per tick, since the view stack changes only after
    // the current event; a call's screen hangs up as it closes. The menu keeps the entry chosen last
    // selected, so it is replaced by a fresh one.
    function reset() as Void {
        resetsLeft = MAX_DEPTH;
        pendingPop = null;
        if (!resetting) {
            resetting = true;
            new HomeReset().step();
        }
    }
}

class HomeClose {
    function initialize() {
    }

    function run() as Void {
        Home.closePending();
    }
}

class HomeReset {
    const TICK_MS = 50;

    // the screen popped last, which may still be on top for a tick
    private var _popped as WatchUi.View? = null;

    function step() as Void {
        var current = WatchUi.getCurrentView()[0];
        if (current == null || current == Home.menu || Home.resetsLeft <= 0) {
            if (current != null && current == Home.menu) {
                // a fresh menu has its first entry selected; the watch puts the old one back on the
                // entry chosen last, whatever setFocus asked for
                var fresh = Home.create();
                WatchUi.switchToView(fresh[0], fresh[1], WatchUi.SLIDE_IMMEDIATE);
            }
            Home.resetting = false;
            WatchUi.requestUpdate();
            return;
        }
        Home.resetsLeft -= 1;
        if (current != _popped) {
            _popped = current;
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        }
        Later.at(TICK_MS, method(:step));
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
