// NonRAID storage GUI registration for Proxmox VE.
//
// Loaded from index.html.tpl right after pvemanagerlib.js (injected by
// pve-nonraid-gui). PVE.Utils.storageSchema is only read at runtime
// (dc/StorageView.js builds the Add menu in initComponent and looks up the
// editor class at click time), so registering here is early enough.
//
// This runs on every PVE web session: any failure must degrade to "no
// Add-menu entry" and never break the rest of the UI.
// No 'use strict': ExtJS classic's callParent() walks Function.caller, which
// strict mode forbids - a strict initComponent dies with "Cannot read
// properties of null (reading 'apply')". None of pve-manager's own UI files
// use strict mode for the same reason.
(function () {
    try {
        if (
            typeof Ext === 'undefined' ||
            typeof PVE === 'undefined' ||
            !PVE.Utils ||
            !PVE.Utils.storageSchema ||
            !Ext.ClassManager.get('PVE.panel.StorageBase')
        ) {
            console.warn('pve-nonraid: PVE UI base classes not present, skipping GUI registration');
            return;
        }

        // Single edit point: names must match the properties() of
        // PVE::Storage::Custom::NonRAIDPlugin exactly.
        //
        // 'suggest' turns a field into an editable combobox seeded with those
        // values. Both path fields are free-form - a new array may use any
        // path - so this cannot be a closed list, but offering the values
        // already in use removes the common typo. The list is extended at
        // render time from the nonraid storages this cluster already has (see
        // addDerivedSuggestions); the driver takes its superblock as a module
        // parameter, so a second storage on the same node needs the same one.
        var NONRAID_FIELDS = [
            {
                name: 'nonraid-super',
                label: 'Superblock File',
                xtype: 'combobox',
                value: '/nonraid.dat',
                allowBlank: false,
                suggest: ['/nonraid.dat'],
                column: 1,
            },
            {
                name: 'nonraid-disk-prefix',
                label: 'Disk Mount Prefix',
                xtype: 'combobox',
                emptyText: '/mnt/disk',
                allowBlank: true,
                deleteEmptyOnEdit: true,
                suggest: ['/mnt/disk'],
                column: 1,
            },
            {
                name: 'nonraid-degraded-autostart',
                label: 'Autostart when degraded',
                xtype: 'proxmoxcheckbox',
                uncheckedValue: 0,
                checked: true,
                column: 2,
            },
            {
                name: 'nonraid-mergerfs-opts',
                label: 'mergerfs Options',
                xtype: 'textfield',
                allowBlank: true,
                deleteEmptyOnEdit: true,
                column: 2,
            },
        ];

        // Values already in use by this cluster's nonraid storages. Read from
        // the storage config the UI is entitled to anyway - PVE has no
        // extension point for a per-plugin scan endpoint (the /nodes/{node}/
        // scan/<type> list is fixed at compile time in pve-storage), and
        // patching the API tree to add one would be a far worse dependency
        // than reading a list the Storage view already renders.
        //
        // Best-effort throughout: on any failure the field keeps its defaults
        // and stays typeable, which is exactly what it was before.
        var addDerivedSuggestions = function (panel) {
            if (typeof Proxmox === 'undefined' || !Proxmox.Utils ||
                !Ext.isFunction(Proxmox.Utils.API2Request)) {
                return;
            }
            Proxmox.Utils.API2Request({
                url: '/storage',
                method: 'GET',
                success: function (response) {
                    try {
                        var seen = {};
                        var data = (response.result && response.result.data) || [];
                        Ext.Array.each(NONRAID_FIELDS, function (f) {
                            if (!f.suggest) {
                                return;
                            }
                            var field = panel.down('field[name=' + f.name + ']');
                            if (!field || !field.getStore) {
                                return;
                            }
                            var store = field.getStore();
                            seen = {};
                            store.each(function (rec) { seen[rec.get('value')] = true; });
                            Ext.Array.each(data, function (s) {
                                var v = s[f.name];
                                if (s.type === 'nonraid' && v && !seen[v]) {
                                    seen[v] = true;
                                    store.add({ value: v });
                                }
                            });
                        });
                    } catch (err) {
                        console.warn('pve-nonraid: could not derive suggestions', err);
                    }
                },
                failure: function () {
                    // Defaults remain; nothing to report to the user.
                },
            });
        };

        // Why a disk cannot be unmounted / wiped / assigned, from what
        // /nodes/{node}/disks/list reports. 'used' comes from PVE's own
        // vocabulary: 'mounted', 'LVM', 'ZFS', 'Device Mapper', 'partitions',
        // or absent when the disk is free; osdid is set for a Ceph OSD.
        //
        // The server checks all of this again and is the authority - this only
        // exists so a button is grey with a reason instead of red after a
        // round trip. One thing it CANNOT see is whether a disk is a member of
        // the running array: that lives in /proc/nmdstat, which no API exposes.
        // A member looks exactly like a partitioned spare here, which is why
        // wiping goes through the plugin's own gate and never straight to
        // PVE's /disks/wipedisk.
        var HOLDERS = { 'LVM': 1, 'ZFS': 1, 'Device Mapper': 1 };

        // A disabled button or field swallows mouse events, so the reason it is
        // disabled has to hang off the grid cell around it or the operator never
        // sees it. setTooltip() also only exists on buttons - calling it on the
        // combobox throws inside the widget-attach loop and every row after that
        // one silently ends up with no widget.
        var setWidgetTip = function (widget, tip) {
            if (Ext.isFunction(widget.setTooltip)) {
                widget.setTooltip(tip);
            }
            var apply = function () {
                var cell = widget.el && widget.el.up('.x-grid-cell');
                if (cell && cell.dom) {
                    cell.dom.setAttribute('data-qtip', tip);
                }
            };
            if (widget.rendered) {
                apply();
            } else {
                widget.on('render', apply, null, { single: true });
            }
        };

        // Whether a row may be assigned depends on the Wipe toggle in the same
        // row - a disk staged for wiping is clean by the time the hook creates
        // the array, since it runs wipe before create. widgetcolumn only
        // recomputes on attach, so the Wipe handler calls this too.
        var applyAssignState = function (widget, rec) {
            var why = rec.get('doWipe') ? null : rec.get('assignWhy');
            widget.setDisabled(!!why);
            setWidgetTip(widget, why || gettext(
                'Build a new array from the disks assigned here'));
            // Suppress the change listener: writing to the record from inside
            // the attach loop refreshes the view underneath it.
            widget.nonraidAttaching = true;
            widget.setValue(why ? '' : (rec.get('role') || ''));
            widget.nonraidAttaching = false;
            if (why && rec.get('role')) {
                rec.set('role', '');
            }
        };

        var syncAssignWidget = function (grid, rec) {
            if (!grid) {
                return;
            }
            Ext.Array.each(grid.query('combobox'), function (cb) {
                if (cb.getWidgetRecord() === rec) {
                    applyAssignState(cb, rec);
                }
            });
        };

        var diskActionState = function (d) {
            var used = d.used || '';
            var ceph = d.osdid !== undefined && d.osdid >= 0;
            var held = ceph || !!HOLDERS[used];
            var holder = ceph ? 'a Ceph OSD' : used;

            var state = { used: used, free: !used && !ceph };

            // This endpoint reports no mountpoints, so 'used' being a
            // filesystem name says nothing about whether it is mounted - the
            // OS disk comes back as 'ext4', not 'mounted'. Anything that might
            // be mounted therefore keeps Unmount enabled and lets the server
            // decide; it is a no-op when nothing is mounted, and it refuses
            // system mountpoints and array members outright.
            if (held) {
                state.unmount = gettext('Held by') + ' ' + holder + ' — '
                    + gettext('release it with that tool first');
                state.wipe = state.unmount;
            } else if (!used) {
                state.unmount = gettext('Nothing on this disk to unmount');
                state.wipe = gettext('Already empty');
            } else {
                state.unmount = null; // may be mounted; the server checks
                state.wipe = null; // may be an array member; the server checks
            }

            // Only a disk with nothing on it may be assigned, which is the end
            // of the unmount -> wipe -> assign funnel.
            state.assign = state.free ? null
                : gettext('Wipe it first') + ' (' + (holder || used) + ')';
            return state;
        };

        // A one-line summary of the node's disks, so the operator can see what
        // hardware is actually there while pointing a storage at an array.
        //
        // These are the NODE's disks, not the array's members: the slot -> disk
        // mapping lives in /proc/nmdstat, which no API exposes, and inventing
        // an endpoint for it would mean patching PVE's API tree (the
        // /nodes/{node}/scan/<type> list is fixed at compile time). The label
        // says so rather than implying these are the members.
        var describeDisks = function (panel, node) {
            var store = panel.diskStore;
            if (!store) {
                return;
            }
            if (!node) {
                store.removeAll();
                return;
            }
            Proxmox.Utils.API2Request({
                url: '/nodes/' + node + '/disks/list',
                method: 'GET',
                success: function (response) {
                    try {
                        var disks = (response.result && response.result.data) || [];
                        store.loadData(Ext.Array.map(disks, function (d) {
                            var s = diskActionState(d);
                            return {
                                devpath: d.devpath,
                                size: d.size,
                                used: d.used,
                                osdid: d.osdid,
                                statusText: s.free
                                    ? gettext('free')
                                    : (s.used || gettext('in use'))
                                        + (d.model && d.model !== 'unknown'
                                            ? ' · ' + d.model : ''),
                                unmountWhy: s.unmount,
                                wipeWhy: s.wipe,
                                assignWhy: s.assign,
                            };
                        }));
                    } catch (err) {
                        console.warn('pve-nonraid: could not list disks', err);
                    }
                },
                failure: function () {
                    store.removeAll();
                },
            });
        };


        Ext.define('PVE.storage.NonRAIDInputPanel', {
            extend: 'PVE.panel.StorageBase',

            initComponent: function () {
                var me = this;

                me.column1 = [
                    {
                        xtype: me.isCreate ? 'textfield' : 'displayfield',
                        name: 'path',
                        value: '',
                        emptyText: '/mnt/pve/<storage id>',
                        fieldLabel: gettext('Path'),
                        allowBlank: true,
                    },
                    {
                        xtype: 'pveContentTypeSelector',
                        name: 'content',
                        // Matches plugindata()'s default content set; 'images'
                        // alone would silently exclude container rootfs for
                        // GUI-created storage only.
                        value: ['images', 'rootdir'],
                        multiSelect: true,
                        fieldLabel: gettext('Content'),
                        allowBlank: false,
                    },
                ];
                me.column2 = [];

                Ext.Array.each(NONRAID_FIELDS, function (f) {
                    var field = {
                        xtype: f.xtype,
                        name: f.name,
                        fieldLabel: f.label,
                        allowBlank: f.allowBlank !== false,
                    };
                    if (f.value !== undefined) {
                        field.value = f.value;
                    }
                    if (f.emptyText !== undefined) {
                        field.emptyText = f.emptyText;
                    }
                    if (f.uncheckedValue !== undefined) {
                        field.uncheckedValue = f.uncheckedValue;
                    }
                    // Unconditional: a checkbox whose key is absent from the
                    // config must render the BACKEND default, not unchecked.
                    // The panel defines onGetValues, which forces
                    // InputPanel.getValues(dirtyOnly=false), so every field is
                    // submitted on save - an unchecked box would persist
                    // uncheckedValue and silently flip the setting during an
                    // edit that only touched something else. When the key IS
                    // present, setValues overrides this after render.
                    if (f.checked !== undefined) {
                        field.checked = f.checked;
                    }
                    if (f.deleteEmptyOnEdit) {
                        field.deleteEmpty = !me.isCreate;
                    }
                    if (f.suggest) {
                        // Editable and forceSelection:false on purpose: the
                        // suggestions are a convenience, not the valid set.
                        // queryMode local because the store is in memory.
                        Ext.apply(field, {
                            editable: true,
                            forceSelection: false,
                            queryMode: 'local',
                            displayField: 'value',
                            valueField: 'value',
                            store: {
                                fields: ['value'],
                                data: Ext.Array.map(f.suggest, function (v) {
                                    return { value: v };
                                }),
                            },
                        });
                    }
                    (f.column === 2 ? me.column2 : me.column1).push(field);
                });

                // StorageBase only auto-adds this for its hard-coded type
                // list (dir/btrfs/nfs/cifs), so add it ourselves.
                me.advancedColumn1 = [
                    {
                        xtype: 'pvePreallocationSelector',
                        name: 'preallocation',
                        fieldLabel: gettext('Preallocation'),
                        allowBlank: false,
                        deleteEmpty: !me.isCreate,
                        value: '__default__',
                    },
                ];

                // Full width, under both columns. Everything here is staged
                // intent, not immediate action: there is no storage to act on
                // until this dialog is submitted, and on submit the plugin's
                // hook runs unmount -> wipe -> create in that order, with the
                // whole set validated server-side first. So one confirmation
                // covers the batch.
                me.diskStore = Ext.create('Ext.data.Store', {
                    fields: [
                        'devpath', 'size', 'used', 'osdid',
                        'statusText', 'unmountWhy', 'wipeWhy', 'assignWhy',
                        { name: 'doUnmount', type: 'bool', defaultValue: false },
                        { name: 'doWipe', type: 'bool', defaultValue: false },
                        { name: 'role', defaultValue: '' },
                    ],
                });

                // One instance shared by every row's combobox. An inline store
                // config does NOT work here: widgetcolumn builds one widget per
                // row from the same config object, the first widget turns the
                // config into a Store instance, and every later row silently
                // ends up with no widget at all.
                me.roleStore = Ext.create('Ext.data.Store', {
                    fields: ['v', 't'],
                    data: [
                        { v: '', t: '—' },
                        { v: 'parity', t: gettext('Parity') },
                        { v: 'data', t: gettext('Data') },
                    ],
                });

                me.columnB = [
                    {
                        xtype: 'grid',
                        name: 'nonraid-disk-manager',
                        title: gettext('Disks on the selected node'),
                        store: me.diskStore,
                        height: 230,
                        emptyText: gettext('Select a single node to list its disks'),
                        viewConfig: { markDirty: false, stripeRows: true },
                        columns: [
                            {
                                text: gettext('Device'),
                                dataIndex: 'devpath',
                                flex: 2,
                            },
                            {
                                text: gettext('Size'),
                                dataIndex: 'size',
                                flex: 1,
                                renderer: function (v) {
                                    return Ext.isFunction(Proxmox.Utils.format_size)
                                        ? Proxmox.Utils.format_size(v) : v;
                                },
                            },
                            {
                                text: gettext('Status'),
                                dataIndex: 'statusText',
                                flex: 2,
                            },
                            {
                                xtype: 'widgetcolumn',
                                text: gettext('Disconnect'),
                                flex: 1,
                                widget: {
                                    xtype: 'button',
                                    text: gettext('Unmount'),
                                    enableToggle: true,
                                    handler: function (btn) {
                                        btn.getWidgetRecord().set('doUnmount', btn.pressed);
                                    },
                                },
                                onWidgetAttach: function (col, widget, rec) {
                                    // Grey with the reason rather than letting
                                    // the click fail server-side.
                                    var why = rec.get('unmountWhy');
                                    widget.setDisabled(!!why);
                                    setWidgetTip(widget, why || gettext(
                                        'Unmount every filesystem on this disk when this form is submitted. '
                                        + 'Refused on the node if the disk is an array member or carries a system mountpoint.'));
                                    widget.toggle(rec.get('doUnmount'), true);
                                },
                            },
                            {
                                xtype: 'widgetcolumn',
                                text: gettext('Wipe'),
                                flex: 1,
                                widget: {
                                    xtype: 'button',
                                    text: gettext('Wipe'),
                                    enableToggle: true,
                                    handler: function (btn) {
                                        var rec = btn.getWidgetRecord();
                                        rec.set('doWipe', btn.pressed);
                                        syncAssignWidget(btn.up('grid'), rec);
                                    },
                                },
                                onWidgetAttach: function (col, widget, rec) {
                                    var why = rec.get('wipeWhy');
                                    widget.setDisabled(!!why);
                                    setWidgetTip(widget, why || gettext(
                                        'Erase all signatures on this disk when this form is submitted. '
                                        + 'Refused on the node if the disk is an array member, mounted, or held by another subsystem.'));
                                    widget.toggle(rec.get('doWipe'), true);
                                },
                            },
                            {
                                xtype: 'widgetcolumn',
                                text: gettext('Assign as'),
                                flex: 1.4,
                                widget: {
                                    xtype: 'combobox',
                                    editable: false,
                                    queryMode: 'local',
                                    valueField: 'v',
                                    displayField: 't',
                                    store: me.roleStore,
                                    listeners: {
                                        // Writing to the record while the
                                        // column is still attaching widgets
                                        // refreshes the view underneath the
                                        // attach loop, and every row after
                                        // this one silently ends up with no
                                        // combobox at all. Only write on a
                                        // real user change.
                                        change: function (cb, v) {
                                            var rec = cb.getWidgetRecord();
                                            if (!rec || cb.nonraidAttaching) {
                                                return;
                                            }
                                            if (rec.get('role') !== (v || '')) {
                                                rec.set('role', v || '');
                                            }
                                        },
                                    },
                                },
                                onWidgetAttach: function (col, widget, rec) {
                                    applyAssignState(widget, rec);
                                },
                            },
                        ],
                    },
                ];

                me.callParent();

                // After callParent so the fields exist to be looked up.
                addDerivedSuggestions(me);

                // StorageBase owns the Nodes selector; follow it rather than
                // adding one, so the hint always describes the node the
                // storage is actually being restricted to.
                var nodesField = me.down('field[name=nodes]');
                if (nodesField) {
                    var refresh = function () {
                        var v = nodesField.getValue();
                        var list = Ext.isArray(v) ? v : (v ? String(v).split(',') : []);
                        describeDisks(me, list.length === 1 ? list[0] : undefined);
                    };
                    nodesField.on('change', refresh);
                    refresh();
                }
            },

            // Staged intent -> the write-only action properties the plugin's
            // hooks consume. Collected here so it rides on the same submit as
            // the storage itself: on create there is no storage to act on
            // beforehand, and the hook runs unmount -> wipe -> create in order.
            stagedDiskActions: function () {
                var me = this;
                var out = { unmount: [], wipe: [], parity: [], data: [] };
                if (!me.diskStore) {
                    return out;
                }
                me.diskStore.each(function (rec) {
                    var dev = rec.get('devpath');
                    if (rec.get('doUnmount')) {
                        out.unmount.push(dev);
                    }
                    if (rec.get('doWipe')) {
                        out.wipe.push(dev);
                    }
                    if (rec.get('role') === 'parity') {
                        out.parity.push(dev);
                    } else if (rec.get('role') === 'data') {
                        out.data.push(dev);
                    }
                });
                return out;
            },

            onGetValues: function (values) {
                // Untouched optional fields submit '', which the API rejects
                // against the path/string formats. Dropping them on create
                // yields the backend defaults (path becomes /mnt/pve/<id>
                // via check_config, the rest via properties()).
                if (this.isCreate) {
                    Ext.Object.each(values, function (key, value) {
                        if (value === '' && (key === 'path' || key.indexOf('nonraid-') === 0)) {
                            delete values[key];
                        }
                    });
                }

                var staged = this.stagedDiskActions();
                if (staged.unmount.length) {
                    values['nonraid-unmount-disks'] = staged.unmount.join(',');
                }
                if (staged.wipe.length) {
                    values['nonraid-wipe-disks'] = staged.wipe.join(',');
                }
                if (staged.parity.length) {
                    values['nonraid-create-parity'] = staged.parity.join(',');
                }
                if (staged.data.length) {
                    values['nonraid-create-data'] = staged.data.join(',');
                }

                return this.callParent([values]);
            },
        });

        // One confirmation for the whole batch, naming every disk and what
        // will happen to it. Wrapping BaseEdit's submit is the only hook that
        // sees the finished payload: the panel cannot refuse a submit, and a
        // per-disk prompt would train people to click through them.
        var confirmDiskActions = function (win, submit) {
            var panel = win.query('inputpanel')[0];
            if (!panel || !Ext.isFunction(panel.stagedDiskActions)) {
                return submit();
            }
            var s = panel.stagedDiskActions();
            var lines = [];
            if (s.unmount.length) {
                lines.push(gettext('Unmount') + ': ' + s.unmount.join(', '));
            }
            if (s.wipe.length) {
                lines.push('<b>' + gettext('ERASE ALL DATA') + '</b>: ' + s.wipe.join(', '));
            }
            if (s.parity.length || s.data.length) {
                lines.push('<b>' + gettext('Build a new array, destroying their contents')
                    + '</b>:<br>&nbsp;&nbsp;' + gettext('Parity') + ': '
                    + (s.parity.join(', ') || '—') + '<br>&nbsp;&nbsp;'
                    + gettext('Data') + ': ' + (s.data.join(', ') || '—'));
            }
            if (!lines.length) {
                return submit();
            }
            Ext.Msg.show({
                title: gettext('Confirm disk changes'),
                message: gettext('These changes cannot be undone:') + '<br><br>'
                    + lines.join('<br>') + '<br><br>' + gettext('Continue?'),
                buttons: Ext.Msg.YESNO,
                icon: Ext.Msg.WARNING,
                defaultFocus: 'no',
                fn: function (btn) {
                    if (btn === 'yes') {
                        submit();
                    }
                },
            });
        };

        // Captured BEFORE the override is defined, and that ordering is the
        // whole point: Ext.define({override: ...}) REPLACES
        // PVE.storage.BaseEdit.prototype.submit, so reaching for that property
        // from inside the override finds the override. Confirming the dialog
        // then re-entered it, re-read the still-staged actions and asked again,
        // forever. callParent is not usable either - the real submit happens in
        // the confirmation's callback, long after the calling frame it needs.
        var baseSubmit = PVE.storage.BaseEdit.prototype.submit;

        // Only wrap our own panel's window, never anyone else's storage dialog.
        Ext.define('PVE.storage.NonRAIDBaseEditHook', {
            override: 'PVE.storage.BaseEdit',
            initComponent: function () {
                var me = this;
                // The disk manager adds four columns below the two field
                // columns; at the default width the button labels ellipsise.
                if (me.paneltype === 'PVE.storage.NonRAIDInputPanel') {
                    me.width = 900;
                }
                return me.callParent(arguments);
            },
            submit: function () {
                var me = this;
                var ipanel = me.query('inputpanel')[0];
                var mine = ipanel && ipanel.isXType
                    && ipanel.$className === 'PVE.storage.NonRAIDInputPanel';
                if (!mine) {
                    return me.callParent(arguments);
                }
                return confirmDiskActions(me, function () {
                    baseSubmit.apply(me, []);
                });
            },
        });

        PVE.Utils.storageSchema.nonraid = {
            name: 'NonRAID',
            ipanel: 'NonRAIDInputPanel', // StorageView prepends 'PVE.storage.'
            faIcon: 'hdd-o',
            backups: true,
        };
    } catch (err) {
        // Never rethrow: a broken storage add-on must not take down the UI.
        console.warn('pve-nonraid: GUI registration failed', err);
    }
})();
