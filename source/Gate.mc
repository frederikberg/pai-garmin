import Toybox.Lang;
import Toybox.WatchUi;

// The check for a ringing alarm that runs when the app opens, behind the menu. A call of a sub-app
// waits until it is over, so one request is in flight at a time and a ringing alarm is stopped
// before anything else goes out. If an alarm rings, the waiting calls are dropped and "Alarm
// stopped" takes the place of the screen that asked; otherwise they go out in turn.
module Gate {
    var open as Boolean = true;
    var waiting as Array<Call> = [];
    var check as Call? = null;

    function start() as Void {
        open = false;
        var call = new Call(new GateCheck().method(:onChecked));
        check = call;
        call.sendNow(Api.alarms());
    }

    // The check found nothing that rings, or could not tell: whatever waits goes out now.
    function release() as Void {
        open = true;
        var calls = waiting;
        waiting = [];
        for (var i = 0; i < calls.size(); i++) {
            calls[i].release();
        }
    }

    // The check found ringing alarms: drop what waits and show the stopped screen, in place of the
    // sub-app screen that was waiting, or over the menu.
    function stop(ringing as Array<Alarm>) as Void {
        open = true;
        var calls = waiting;
        waiting = [];
        for (var i = 0; i < calls.size(); i++) {
            calls[i].cancel();
        }
        var view = new RingingView(ringing);
        var delegate = new MessageDelegate(view);
        if (calls.size() > 0) {
            WatchUi.switchToView(view, delegate, WatchUi.SLIDE_IMMEDIATE);
        } else {
            WatchUi.pushView(view, delegate, WatchUi.SLIDE_IMMEDIATE);
        }
    }
}

class GateCheck {
    function onChecked(outcome as Outcome) as Void {
        var state = outcome.state;
        if (state != null && state.ringing.size() > 0) {
            Gate.stop(state.ringing);
        } else {
            Gate.release();
        }
    }
}
