import Toybox.Lang;
import Toybox.WatchUi;

// What opens first: asks the server for the alarms, then shows the ringing ones or the home menu.
class StartView extends MessageView {
    private var _call as Call? = null;

    function initialize() {
        MessageView.initialize("PAI");
    }

    function onShow() as Void {
        if (_call == null) {
            load();
        }
    }

    function load() as Void {
        show(null, "Loading...", null, null);
        var call = new Call(method(:onState));
        _call = call;
        call.send(Api.alarms());
    }

    function onState(outcome as Outcome) as Void {
        var state = outcome.state;
        if (state == null) {
            show(null, outcome.isOk() ? "Unexpected answer" : outcome.text(), "Enter: retry", method(:load));
        } else if (state.ringing.size() > 0) {
            var view = new RingingView(state.ringing);
            WatchUi.switchToView(view, new MessageDelegate(view), WatchUi.SLIDE_IMMEDIATE);
        } else {
            Home.open();
        }
    }
}
