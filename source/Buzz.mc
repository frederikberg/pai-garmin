import Toybox.Attention;
import Toybox.Lang;

// The one short buzz that says a ringing alarm was stopped, from the app or the glance.
(:glance)
module Buzz {
    function once() as Void {
        if (Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(100, 120)]);
        }
    }
}
