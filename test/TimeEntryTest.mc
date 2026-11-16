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
