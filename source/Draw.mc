import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Text placement shared by the screens, as fractions of the screen so every round display fits.
module Draw {
    function background(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
    }

    // The small grey heading near the top edge.
    function title(dc as Graphics.Dc, text as String) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() * 14 / 100, Graphics.FONT_XTINY, text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // The small grey line near the bottom edge.
    function hint(dc as Graphics.Dc, text as String) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() * 86 / 100, Graphics.FONT_XTINY, text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Wrapped text centered in the band from top to bottom (percent of the height).
    function paragraph(dc as Graphics.Dc, text as String, top as Number, bottom as Number) as Void {
        var width = dc.getWidth() * 70 / 100;
        var area = new WatchUi.TextArea({
            :text => text,
            :color => Graphics.COLOR_WHITE,
            :font => [Graphics.FONT_SMALL, Graphics.FONT_XTINY],
            :locX => (dc.getWidth() - width) / 2,
            :locY => dc.getHeight() * top / 100,
            :width => width,
            :height => dc.getHeight() * (bottom - top) / 100,
            :justification => Graphics.TEXT_JUSTIFY_CENTER
        });
        area.draw(dc);
    }
}
