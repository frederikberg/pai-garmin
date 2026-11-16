import Toybox.Lang;
import Toybox.WatchUi;

// The menu of sub-apps. Weather comes first and is the focused entry.
module Home {
    function open() as Void {
        var menu = new WatchUi.Menu2({:title => "PAI"});
        menu.addItem(new WatchUi.MenuItem("Weather", null, :weather, null));
        menu.addItem(new WatchUi.MenuItem("Alarm", null, :alarm, null));
        WatchUi.switchToView(menu, new HomeDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }
}

class HomeDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        if (item.getId() == :weather) {
            var view = new WeatherView();
            WatchUi.pushView(view, new WeatherDelegate(view), WatchUi.SLIDE_LEFT);
        } else {
            var list = new AlarmListView();
            WatchUi.pushView(list, new AlarmListDelegate(list), WatchUi.SLIDE_LEFT);
        }
    }
}
