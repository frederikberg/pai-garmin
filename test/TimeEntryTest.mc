import Toybox.Lang;
import Toybox.Test;

(:test)
function repeatingSpeedsUpToAFloor(logger as Logger) as Boolean {
    var previous = TimeEntryView.repeatPause(0);
    for (var i = 1; i < 40; i++) {
        var pause = TimeEntryView.repeatPause(i);
        if (pause > previous || pause < TimeEntryView.FASTEST_MS) {
            return false;
        }
        previous = pause;
    }
    return previous == TimeEntryView.FASTEST_MS && TimeEntryView.repeatPause(0) == TimeEntryView.SLOWEST_MS;
}

(:test)
function numbersWrapAtTheirLimits(logger as Logger) as Boolean {
    var hours = TimeEntryView.limits(true)[0];
    return TimeEntryView.wrap(23, 1, hours) == 0 && TimeEntryView.wrap(0, -1, hours) == 23
        && TimeEntryView.wrap(59, 1, 60) == 0 && TimeEntryView.wrap(0, -1, 60) == 59 && TimeEntryView.wrap(10, 1, 60) == 11;
}

(:test)
function aDurationHasSecondsAndAClockTimeDoesNot(logger as Logger) as Boolean {
    var duration = TimeEntryView.limits(true);
    var clock = TimeEntryView.limits(false);
    return duration.size() == 3 && clock.size() == 2 && duration[2] == 60;
}
