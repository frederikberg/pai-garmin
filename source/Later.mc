import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// One timer for every one-shot wait of the app outside a call's own clock and player: request
// watchdogs, the alarm check's idle time, the menu reset's ticks, the hide timeout and Idle. A watch
// runs only a few timers at once (three on a fēnix 8 in the simulator, a fourth is fatal), and a call
// already holds two.
module Later {
    // the shortest wait the timer takes
    const MIN_MS = 50;

    // waiting jobs: id, due (uptime ms), job
    var jobs as Array<Array<Object>> = [];
    var nextId as Number = 0;
    var timer as Timer.Timer? = null;
    // the due jobs of the firing in progress, so a job can still cancel one of them
    var firing as Array<Array<Object>> = [];

    // Runs job once, ms from now; the answer names it for cancel().
    function at(ms as Number, job as Method() as Void) as Number {
        nextId += 1;
        jobs.add([nextId, System.getTimer() + ms, job] as Array<Object>);
        arm();
        return nextId;
    }

    function cancel(id as Number) as Void {
        jobs = without(jobs, id);
        firing = without(firing, id);
        if (jobs.size() == 0) {
            var t = timer;
            if (t != null) {
                t.stop();
            }
        }
    }

    function without(list as Array<Array<Object>>, id as Number) as Array<Array<Object>> {
        var out = [] as Array<Array<Object>>;
        for (var i = 0; i < list.size(); i++) {
            if ((list[i][0] as Number) != id) {
                out.add(list[i]);
            }
        }
        return out;
    }

    function arm() as Void {
        var t = timer;
        if (t == null) {
            t = new Timer.Timer();
            timer = t;
        }
        t.stop();
        if (jobs.size() == 0) {
            return;
        }
        var due = jobs[0][1] as Number;
        for (var i = 1; i < jobs.size(); i++) {
            if ((jobs[i][1] as Number) < due) {
                due = jobs[i][1] as Number;
            }
        }
        var wait = due - System.getTimer();
        t.start(new LaterFire().method(:fire), wait < MIN_MS ? MIN_MS : wait, false);
    }

    // Every job that is due runs; a job may add or cancel others.
    function fire() as Void {
        var now = System.getTimer();
        var keep = [] as Array<Array<Object>>;
        firing = [];
        for (var i = 0; i < jobs.size(); i++) {
            if ((jobs[i][1] as Number) <= now) {
                firing.add(jobs[i]);
            } else {
                keep.add(jobs[i]);
            }
        }
        jobs = keep;
        while (firing.size() > 0) {
            var job = firing[0][2] as Method() as Void;
            firing = firing.slice(1, null) as Array<Array<Object>>;
            job.invoke();
        }
        arm();
    }
}

class LaterFire {
    function initialize() {
    }

    function fire() as Void {
        Later.fire();
    }
}
