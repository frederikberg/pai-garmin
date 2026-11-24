import Toybox.Lang;
import Toybox.Timer;

// The check for a ringing alarm. It goes out only once the menu has stayed on screen for IDLE_MS
// after the app opened or came back, with no sub-app chosen, so a quick way into a sub-app never
// waits for it and nothing goes to the server before a sub-app asks. A ringing alarm is stopped
// without a screen of its own; one short buzz says so. While the check is out, a sub-app's call
// waits behind it, so one request is in flight at a time.
module Gate {
    const IDLE_MS = 1000;

    var open as Boolean = true;
    var waiting as Array<Call> = [];
    var idle as Timer.Timer? = null;

    // The menu shows after the app opened or came back: the check runs once the idle time passed.
    function arm() as Void {
        disarm();
        var timer = new Timer.Timer();
        idle = timer;
        timer.start(new GateCheck().method(:onIdle), IDLE_MS, false);
    }

    // A sub-app was chosen within the idle time: no check this time.
    function disarm() as Void {
        var timer = idle;
        if (timer != null) {
            timer.stop();
            idle = null;
        }
    }

    function check() as Void {
        idle = null;
        open = false;
        new Call(new GateCheck().method(:onChecked)).sendNow(Api.alarms());
    }

    // The check is over: whatever waits goes out now.
    function release() as Void {
        open = true;
        var calls = waiting;
        waiting = [];
        for (var i = 0; i < calls.size(); i++) {
            calls[i].release();
        }
    }
}

class GateCheck {
    function onIdle() as Void {
        Gate.check();
    }

    // Something rings: stop every ringing alarm before the waiting calls go out. Nothing rings, or
    // the check could not tell: they go out at once.
    function onChecked(outcome as Outcome) as Void {
        var state = outcome.state;
        if (state != null && state.ringing.size() > 0) {
            Trace.add("alarm_ringing", {"count" => state.ringing.size()});
            new Call(method(:onDismissed)).sendNow(Api.dismissAll());
        } else {
            Gate.release();
        }
    }

    function onDismissed(outcome as Outcome) as Void {
        Trace.add("alarm_stopped", {"ok" => outcome.isOk()});
        if (outcome.isOk()) {
            Trace.add("buzz", {"cue" => "alarm"});
            Buzz.once();
        }
        Gate.release();
    }
}
