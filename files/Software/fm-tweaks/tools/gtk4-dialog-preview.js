// Renders an AdwMessageDialog shaped like zenity's entry dialog to a PNG using the farm gtk-4.0 CSS. Run: OUT=x.png [DUMP=1] XDG_CONFIG_HOME=<dir with gtk-4.0/gtk.css> GSETTINGS_BACKEND=keyfile gjs -m gtk4-dialog-preview.js
import Gtk from 'gi://Gtk?version=4.0'; import Adw from 'gi://Adw'; import GLib from 'gi://GLib'; import Gio from 'gi://Gio';
Adw.init();
const out = GLib.getenv('OUT');
const app = new Adw.Application({application_id:'x.y.z', flags: Gio.ApplicationFlags.NON_UNIQUE});
function dump(w, d) { let s = ' '.repeat(d*2) + w.get_css_name() + '.' + w.get_css_classes().join('.') ; print(s); for (let c = w.get_first_child(); c; c = c.get_next_sibling()) dump(c, d+1); }
app.connect('activate', () => {
  const host = new Gtk.Window({application: app, default_width: 10, default_height: 10});
  const d = new Adw.MessageDialog({heading:'', transient_for: host, modal: true});
  const b = new Gtk.Box({orientation:1, spacing:2, margin_top:12, margin_bottom:12, margin_start:12, margin_end:12});
  b.append(new Gtk.Label({label:'Name:', xalign:0})); b.append(new Gtk.Entry({text:'untitled.txt'}));
  d.set_extra_child(b); d.add_response('cancel','_Cancel'); d.add_response('ok','_OK'); d.set_default_response('ok'); d.set_title('New File');
  d.present();
  GLib.timeout_add(900, 0, () => { if (GLib.getenv('DUMP')) dump(d, 0);
    const p = new Gtk.WidgetPaintable({widget: d}); const snap = Gtk.Snapshot.new(); p.snapshot(snap, d.get_width(), d.get_height());
    const tex = d.get_native().get_renderer().render_texture(snap.to_node(), null); tex.save_to_png(out); app.quit(); return 0; });
});
app.run([]);
