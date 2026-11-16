import Toybox.Lang;
import Toybox.WatchUi;

// The ringing alarm; Enter stops every ringing alarm and goes on to the home menu.
class RingingView extends MessageView {
    function initialize(ringing as Array<Alarm>) {
        MessageView.initialize("Alarm ringing");
        var first = ringing[0];
        var more = ringing.size() - 1;
        show(AlarmTime.hhmm(first.fireAt), first.name + (more > 0 ? " (+" + more + ")" : ""), "Enter: stop", method(:dismiss));
    }

    function dismiss() as Void {
        show(null, "Stopping...", null, null);
        new Call(method(:onDismissed)).send(Api.dismissAll());
    }

    function onDismissed(outcome as Outcome) as Void {
        if (outcome.isOk()) {
            // the server's state decides what comes next: the menu, or the alarm that rings still
            var start = new StartView();
            WatchUi.switchToView(start, new MessageDelegate(start), WatchUi.SLIDE_IMMEDIATE);
        } else {
            show(null, outcome.text(), "Enter: retry", method(:dismiss));
        }
    }
}
