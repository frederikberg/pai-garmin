import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
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

    // Text centred on y (percent of the height) in the first font whose width fits the round
    // screen at that height, or the last one when none does.
    function fitted(dc as Graphics.Dc, y as Number, text as String, fonts as Array<Graphics.FontType>) as Void {
        var cy = dc.getHeight() * y / 100;
        var font = fonts[fonts.size() - 1];
        for (var i = 0; i < fonts.size(); i++) {
            if (dc.getTextWidthInPixels(text, fonts[i]) <= widthAt(dc, cy, dc.getFontHeight(fonts[i]))) {
                font = fonts[i];
                break;
            }
        }
        dc.drawText(dc.getWidth() / 2, cy, font, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // How wide a line of text centred on cy can be without touching the edge of the screen.
    function widthAt(dc as Graphics.Dc, cy as Number, lineHeight as Number) as Number {
        var round = System.getDeviceSettings().screenShape == System.SCREEN_SHAPE_ROUND;
        return chord(dc.getWidth(), dc.getHeight(), round, cy, lineHeight);
    }

    // On a round screen the narrower of the line's top and bottom chord, less a small margin.
    function chord(width as Number, height as Number, round as Boolean, cy as Number, lineHeight as Number) as Number {
        var margin = width * 6 / 100;
        if (!round) {
            return width - 2 * margin;
        }
        var r = width / 2.0;
        var dy = (cy - height / 2.0).abs() + lineHeight / 2.0;
        if (dy >= r) {
            return 0;
        }
        return (2 * Math.sqrt(r * r - dy * dy)).toNumber() - 2 * margin;
    }
}
