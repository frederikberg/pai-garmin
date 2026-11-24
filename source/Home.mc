import Toybox.Lang;
import Toybox.WatchUi;

// The menu of sub-apps, the first screen however the app is opened, and the one a hang-up returns
// to. Computer comes first and is the focused entry, where the watch has audio, so one Start begins a
// call. It needs no request: nothing goes to the server until a sub-app is chosen.
module Home {
    function create() as [WatchUi.Menu2, WatchUi.Menu2InputDelegate] {
        var menu = new WatchUi.Menu2({:title => "PAI"});
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
}

class HomeDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
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
