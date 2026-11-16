import Toybox.Lang;
import Toybox.Test;

class Counter {
    var answers as Number = 0;

    function onAnswer(outcome as Outcome) as Void {
        answers += 1;
    }
}

(:test)
function aCallWaitsForTheGateAndGoesOutWhenItOpens(logger as Logger) as Boolean {
    var counter = new Counter();
    Gate.open = false;
    Gate.waiting = [];
    // without a configured server a call that goes out answers at once, so an answer shows it went out
    new Call(counter.method(:onAnswer)).send(Api.weather());
    var heldBack = counter.answers == 0 && Gate.waiting.size() == 1;
    Gate.release();
    return heldBack && counter.answers == 1 && Gate.open && Gate.waiting.size() == 0;
}

(:test)
function aCancelledCallNeverGoesOut(logger as Logger) as Boolean {
    var counter = new Counter();
    Gate.open = false;
    Gate.waiting = [];
    var call = new Call(counter.method(:onAnswer));
    call.send(Api.weather());
    call.cancel();
    var dropped = Gate.waiting.size() == 0;
    Gate.release();
    return dropped && counter.answers == 0;
}

(:test)
function anOpenGateLetsACallStraightThrough(logger as Logger) as Boolean {
    var counter = new Counter();
    Gate.open = true;
    new Call(counter.method(:onAnswer)).send(Api.weather());
    return counter.answers == 1 && Gate.waiting.size() == 0;
}
