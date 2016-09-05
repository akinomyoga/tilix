/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

 module gx.terminix.terminal.password;

import std.algorithm;
import std.conv;
import std.experimental.logger;
import std.format;
import std.process;
import std.string;
import std.uuid;

import gobject.ObjectG;

import gio.Cancellable;
import gio.SimpleAsyncResult;

import glib.GException;
import glib.HashTable;
import glib.ListG;

import gtk.Box;
import gtk.Button;
import gtk.CellRendererText;
import gtk.Dialog;
import gtk.Entry;
import gtk.Grid;
import gtk.Label;
import gtk.ListStore;
import gtk.TreeIter;
import gtk.TreePath;
import gtk.TreeView;
import gtk.TreeViewColumn;
import gtk.ScrolledWindow;
import gtk.SearchEntry;
import gtk.Window;

import vte.Terminal: VTE=Terminal;

import secret.Collection;
import secret.Item;
import secret.Schema;
import secret.Secret;
import secret.Service;

import gx.i18n.l10n;

class PasswordManagerDialog: Dialog {

private:

    enum COLUMN_NAME = 0;
    enum COLUMN_ID = 1;

    enum SCHEMA_NAME = "com.gexperts.Terminix.Password";

    enum ATTRIBUTE_ID = "id";
    enum ATTRIBUTE_DESCRIPTION = "description";

    enum PENDING_COLLECTION = "collection";
    enum PENDING_SERVICE = "service";
    enum PENDING_SEARCH = "search";

    enum DEFAULT_COLLECTION = "default";

    HashTable EMPTY_ATTRIBUTES;

    SearchEntry se;
    TreeView tv;
    ListStore ls;

    Schema schema;
    // These are populated asynchronously
    Service service;
    Collection collection;

    // Keep a list of pending async operations so we can cancel them
    // if the user closes the app
    Cancellable[string] pending;

    // Null terminated strings we need to keep a reference for C async methods
    immutable(char*) attrDescription;
    immutable(char*) attrID;
    immutable(char*) descriptionValue;

    // List of items
    string[][] rows;

    void createUI() {
        with (getContentArea()) {
            setMarginLeft(18);
            setMarginRight(18);
            setMarginTop(18);
            setMarginBottom(18);
        }

        Box b = new Box(Orientation.VERTICAL, 6);

        se = new SearchEntry();
        se.addOnSearchChanged(delegate(SearchEntry) {
            filterEntries();
        });
        b.add(se);

        Box bList = new Box(Orientation.HORIZONTAL, 6);

        ls = new ListStore([GType.STRING, GType.STRING]);
        tv = new TreeView(ls);
        tv.setHeadersVisible(false);
        TreeViewColumn column = new TreeViewColumn(_("Name"), new CellRendererText(), "text", COLUMN_NAME);
        column.setMinWidth(200);
        tv.appendColumn(column);
        column = new TreeViewColumn(_("ID"), new CellRendererText(), "text", COLUMN_NAME);
        column.setVisible(false);
        tv.appendColumn(column);

        tv.addOnCursorChanged(delegate(TreeView) {
            updateUI();   
        });
        tv.addOnRowActivated(delegate(TreePath, TreeViewColumn, TreeView) {
            response(ResponseType.APPLY);
        });

        ScrolledWindow sw = new ScrolledWindow(tv);
        sw.setShadowType(ShadowType.ETCHED_IN);
        sw.setPolicy(PolicyType.NEVER, PolicyType.AUTOMATIC);
        sw.setHexpand(true);
        sw.setVexpand(true);
        sw.setSizeRequest(-1, 250);
        
        bList.add(sw);

        Box bButtons = new Box(Orientation.VERTICAL, 6);
        Button btnNew = new Button(_("New"));
        btnNew.addOnClicked(delegate(Button) {
            PasswordDialog pd = new PasswordDialog(this);
            scope (exit) {pd.destroy();}
            pd.showAll();
            if (pd.run() == ResponseType.OK) {
                SecretSchema* ss = schema.getSchemaStruct();
                trace("Schema name is " ~ to!string(ss.name));
                trace(format("Storing password, label=%s",pd.label));
                Cancellable c = new Cancellable();
                //We could potentially have many password operations on the go, use random key
                string uuid = randomUUID().toString(); 
                pending[uuid] = c;
                import gtkc.glib;
                HashTable attributes = new HashTable(g_str_hash, g_str_equal);
                immutable(char*) uuidz = toStringz(uuid);
                attributes.insert(cast(void*)attrID, cast(void*)uuidz);
                attributes.insert(cast(void*)attrDescription, cast(void*)descriptionValue);
                Secret.passwordStorev(schema, attributes, DEFAULT_COLLECTION, pd.label, pd.password, c, &passwordStoreCallback, this.getDialogStruct());
            }
        });
        bButtons.add(btnNew);

        /*
        Button btnDelete = new Button(_("Delete"));
        btnDelete.addOnClicked(delegate(Button) {
            TreeIter selected = tv.getSelectedIter();
            if (selected) {
                ls.remove(selected);

            }
        });
        bButtons.add(btnDelete);
        */

        bList.add(bButtons);

        b.add(bList);
        getContentArea().add(b);
    }

    void filterEntries() {
        string selectedID;
        TreeIter selected = tv.getSelectedIter();
        if (selected) selectedID = ls.getValueString(selected, COLUMN_ID);
        selected = null;
        ls.clear();
        foreach(row; rows) {
            if (se.getText().length ==0 || row[0].indexOf(se.getText()) >=0) {
                TreeIter iter = ls.createIter();
                ls.setValue(iter, COLUMN_NAME, row[0]);
                ls.setValue(iter, COLUMN_ID, row[1]);
                if (row[1] == selectedID) selected = iter;
            }
        }
        if (selected !is null) tv.getSelection().selectIter(selected);    
    }

    void loadEntries() {
        ListG list = collection.getItems();
        Item[] items = list.toArray!Item;
        rows.length = 0;
        foreach (item; items) {
            if (item.getSchemaName() == SCHEMA_NAME) {
                string id = to!string(cast(char*)item.getAttributes().lookup(cast(void*)attrID));
                rows ~= [item.getLabel(), id];
            }
        }
        filterEntries();
        /* Code to sort items, not working
        bool itemComp(Item a, Item b) { return a.getLabel() > b.getLabel(); }
        items = sort!(itemComp)(items);
        */
        /*
        ls.clear();
        foreach(item; items) {
            if (item.getSchemaName() == SCHEMA_NAME) {
                TreeIter iter = ls.createIter();
                ls.setValue(iter, COLUMN_NAME, item.getLabel());
                string id = to!string(cast(char*)item.getAttributes().lookup(cast(void*)attrID));
                ls.setValue(iter, COLUMN_ID, id);
            }
        }
        */
        updateUI();
    }

    HashTable createHashTable() {
        import gtkc.glib;
        return new HashTable(g_str_hash, g_str_equal);
    }

    void createSchema() {
        HashTable ht = createHashTable();
        ht.insert(cast(void*)attrID, cast(void*)0);
        ht.insert(cast(void*)attrDescription, cast(void*)0);
        schema = new Schema(SCHEMA_NAME, SecretSchemaFlags.NONE, ht); 
    }

    void createService() {
        Cancellable c = new Cancellable();
        pending[PENDING_SERVICE] = c;
        Service.get(SecretServiceFlags.OPEN_SESSION, c, &secretServiceCallback, this.getDialogStruct());
    }

    void createCollection() {
        Cancellable c = new Cancellable();
        pending[PENDING_COLLECTION] = c;
        Collection.forAlias(service, DEFAULT_COLLECTION, SecretCollectionFlags.LOAD_ITEMS, c, &collectionCallback, this.getDialogStruct());
    }

    void updateUI() {
        setResponseSensitive(ResponseType.APPLY, tv.getSelectedIter() !is null);
    }

    extern(C) static void passwordStoreCallback(GObject* sourceObject, GAsyncResult* res, void* userData) {
        trace("passwordCallback called");
        try {
            Secret.passwordStoreFinish(new SimpleAsyncResult(cast(GSimpleAsyncResult*)res, false));
            PasswordManagerDialog pd = cast(PasswordManagerDialog) ObjectG.getDObject!(Dialog)(cast(GtkDialog*) userData, false);
            if (pd !is null) {
                trace("Re-loading entries");
                pd.service.disconnect();
                pd.service = null;
                pd.collection = null;
                pd.createService();
            }
        } catch (GException ge) {
            trace("Error occurred: " ~ ge.msg);
            return;
        }
    }

    extern(C) static void collectionCallback(GObject* sourceObject, GAsyncResult* res, void* userData) {
        trace("collectionCallback called");
        try {
            Collection c = Collection.forAliasFinish(new SimpleAsyncResult(cast(GSimpleAsyncResult*)res, false));
            if (c !is null) {
                PasswordManagerDialog pd = cast(PasswordManagerDialog) ObjectG.getDObject!(Dialog)(cast(GtkDialog*) userData, false);
                if (pd !is null) {
                    pd.pending.remove(PENDING_COLLECTION);
                    pd.collection = c;
                    pd.loadEntries();
                    trace("Retrieved default collection");
                }
            }
        } catch (GException ge) {
            trace("Error occurred: " ~ ge.msg);
            return;
        }
    }

    extern(C) static void secretServiceCallback(GObject* sourceObject, GAsyncResult* res, void* userData) {
        trace("secretServiceCallback called");
        try {
            Service ss = Service.getFinish(new SimpleAsyncResult(cast(GSimpleAsyncResult*)res, false));
            if (ss !is null) {
                PasswordManagerDialog pd = cast(PasswordManagerDialog) ObjectG.getDObject!(Dialog)(cast(GtkDialog*) userData, false);
                if (pd !is null) {
                    pd.pending.remove(PENDING_SERVICE);
                    pd.service = ss;
                    pd.createCollection();
                    trace("Retrieved secret service");
                }
            }

        } catch (GException ge) {
            trace("Error occurred: " ~ ge.msg);
            return;
        }        
    }

public:

    this(Window parent) {
        super(_("Insert Password"), parent, GtkDialogFlags.MODAL + GtkDialogFlags.USE_HEADER_BAR, [_("Apply"), _("Cancel")], [GtkResponseType.APPLY, GtkResponseType.CANCEL]);
        setDefaultResponse(GtkResponseType.APPLY);
        addOnDestroy(delegate(Widget) {
            foreach(c; pending) {
                c.cancel();
            }
        });
        EMPTY_ATTRIBUTES = createHashTable();
        attrID = toStringz(ATTRIBUTE_ID);
        attrDescription = toStringz(ATTRIBUTE_DESCRIPTION);
        descriptionValue = toStringz("Terminix Password");
        trace("Retrieving secret service");
        createSchema();
        createUI();
        createService();
        trace("Main Thread ID " ~ to!string(thisThreadID));       
    }

    void insertPassword(VTE vte) {
        TreeIter selected = tv.getSelectedIter();
        if (selected) {
            string id = ls.getValueString(selected, COLUMN_ID);
            trace("Getting password for " ~ id);
            HashTable ht = createHashTable();
            immutable(char*) idz = toStringz(id); 
            ht.insert(cast(void*)attrID, cast(void*)idz);
            string password = Secret.passwordLookupvSync(schema, ht, null);
            vte.feedChild(password, password.length);
        }
    }

}

private:
class PasswordDialog: Dialog {

private:

    Entry eLabel;
    Entry ePassword;
    Entry eConfirmPassword;

    void createUI(string _label, string _password) {

        Grid grid = new Grid();
        grid.setColumnSpacing(12);
        grid.setRowSpacing(6);
        
        int row = 0;
        // Name (i.e. Label in libsecret parlance)
        grid.attach(new Label(_("Name")), 0, row, 1, 1);
        eLabel = new Entry();
        eLabel.setWidthChars(40);
        eLabel.addOnChanged(delegate(Entry) {
            updateUI();
        });
        eLabel.setText(_label);
        grid.attach(eLabel, 1, row, 1, 1);
        row++;

        //Password
        grid.attach(new Label(_("Password")), 0, row, 1, 1);
        ePassword = new Entry();
        ePassword.addOnChanged(delegate(Entry) {
            updateUI();
        });
        ePassword.setVisibility(false);
        ePassword.setText(_password);
        grid.attach(ePassword, 1, row, 1, 1);
        row++;

        //Confirm Password
        grid.attach(new Label(_("Confirm Password")), 0, row, 1, 1);
        eConfirmPassword = new Entry();
        eConfirmPassword.addOnChanged(delegate(Entry) {
            updateUI();
        });
        eConfirmPassword.setVisibility(false);
        eConfirmPassword.setText(_password);
        grid.attach(eConfirmPassword, 1, row, 1, 1);
        row++;        

        with (getContentArea()) {
            setMarginLeft(18);
            setMarginRight(18);
            setMarginTop(18);
            setMarginBottom(18);
            add(grid);
        }
        updateUI();
    }

    void updateUI() {
        setResponseSensitive(GtkResponseType.OK, eLabel.getText().length > 0 && ePassword.getText().length > 0 && ePassword.getText() == eConfirmPassword.getText());
    }

    this(Window parent, string title) {
        super(title, parent, GtkDialogFlags.MODAL + GtkDialogFlags.USE_HEADER_BAR, [_("OK"), _("Cancel")], [GtkResponseType.OK, GtkResponseType.CANCEL]);
        setDefaultResponse(GtkResponseType.OK);
    }

public:
    this(Window parent) {
        this(parent, _("Add Password"));
        createUI("","");
    }

    this(Window parent, string _label, string _password) {
        this(parent, _("Edit Password"));
        createUI(_label, _password);
    }

    @property string label() {
        return eLabel.getText();
    } 
    
    @property string password() {
        return ePassword.getText();
    }

}