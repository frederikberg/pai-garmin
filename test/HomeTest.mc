import Toybox.Lang;
import Toybox.Test;

(:test)
function aHideShorterThanTenSecondsKeepsTheScreen(logger as Logger) as Boolean {
    return Home.keepOnReturn(3000) && Home.keepOnReturn(9999);
}

(:test)
function aHideOfTenSecondsOrMoreReturnsToTheMenu(logger as Logger) as Boolean {
    return !Home.keepOnReturn(10000) && !Home.keepOnReturn(60000);
}
