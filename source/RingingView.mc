import Toybox.Lang;
import Toybox.WatchUi;

// A ringing alarm. Showing it stops every ringing alarm at once; Enter then goes back to the menu.
// Only the app does this: the glance just reports that an alarm rings.
class RingingView extends MessageView {
    private var _started as Boolean = false;
    private var _time as String;
    private var _name as String;

    function initialize(ringing as Array<Alarm>) {
        MessageView.initialize("Alarm ringing");
        var first = ringing[0];
        var more = ringing.size() - 1;
        _time = AlarmTime.clock(first.fireAt);
        _name = first.name + (more > 0 ? " (+" + more + ")" : "");
        show(_time, _name, "Stopping...", null);
    }

    function onShow() as Void {
        if (!_started) {
            _started = true;
            dismiss();
        }
    }

    function dismiss() as Void {
        new Call(method(:onDismissed)).sendNow(Api.dismissAll());
    }

    function onDismissed(outcome as Outcome) as Void {
        if (outcome.isOk()) {
            setTitle("Alarm stopped");
            show(_time, _name, "Enter: menu", method(:menu));
        } else {
            setTitle("Alarm ringing");
            show(null, outcome.text(), "Enter: retry", method(:retry));
        }
    }

    function menu() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    function retry() as Void {
        show(_time, _name, "Stopping...", null);
        dismiss();
    }
}
