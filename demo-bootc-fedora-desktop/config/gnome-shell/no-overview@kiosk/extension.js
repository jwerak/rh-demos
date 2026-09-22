import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class NoOverview extends Extension {
    enable() {
        this._hiding = false;
        this._showingId = Main.overview.connect('showing', () => {
            this._closeOverview();
        });
        this._closeOverview();
    }

    disable() {
        if (this._showingId) {
            Main.overview.disconnect(this._showingId);
            this._showingId = 0;
        }
    }

    _closeOverview() {
        if (this._hiding)
            return;
        this._hiding = true;
        Main.overview.hide();
        this._hiding = false;
    }
}
