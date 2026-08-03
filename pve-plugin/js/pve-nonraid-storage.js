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

        // A one-line summary of the node's disks, so the operator can see what
        // hardware is actually there while pointing a storage at an array.
        //
        // These are the NODE's disks, not the array's members: the slot -> disk
        // mapping lives in /proc/nmdstat, which no API exposes, and inventing
        // an endpoint for it would mean patching PVE's API tree (the
        // /nodes/{node}/scan/<type> list is fixed at compile time). The label
        // says so rather than implying these are the members.
        var describeDisks = function (panel, node) {
            var hint = panel.down('field[name=nonraid-node-disks]');
            if (!hint) {
                return;
            }
            if (!node) {
                hint.setValue(gettext('Select a single node to list its disks'));
                return;
            }
            Proxmox.Utils.API2Request({
                url: '/nodes/' + node + '/disks/list',
                method: 'GET',
                success: function (response) {
                    try {
                        var disks = (response.result && response.result.data) || [];
                        if (!disks.length) {
                            hint.setValue(gettext('No disks reported'));
                            return;
                        }
                        var parts = Ext.Array.map(disks, function (d) {
                            var size = Ext.isFunction(Proxmox.Utils.format_size)
                                ? Proxmox.Utils.format_size(d.size)
                                : d.size;
                            var model = d.model && d.model !== 'unknown'
                                ? ' ' + Ext.String.htmlEncode(d.model) : '';

                            // 'used' is whatever already claims the disk - a
                            // filesystem, LVM, ZFS, partitions - and osdid is
                            // set for a Ceph OSD. Either way it is spoken for,
                            // including by a NonRAID array, whose members
                            // carry their own filesystems.
                            var claim = d.used ||
                                (d.osdid !== undefined && d.osdid >= 0 ? 'Ceph OSD' : '');
                            var label = '<b>' + Ext.String.htmlEncode(d.devpath) + '</b> '
                                + size + model;

                            if (claim) {
                                // Dimmed rather than hidden: knowing a disk is
                                // taken, and by what, is the point. Inert too -
                                // no text selection, no pointer - so a claimed
                                // disk cannot be copied into an nmdctl command
                                // by accident. Opacity degrades sanely in
                                // either PVE theme.
                                return '<span aria-disabled="true" title="'
                                    + Ext.String.htmlEncode(gettext('In use') + ': ' + claim)
                                    + '" style="opacity:0.5;pointer-events:none;'
                                    + 'user-select:none;-webkit-user-select:none;'
                                    + 'cursor:not-allowed">'
                                    + label + ' (' + Ext.String.htmlEncode(claim)
                                    + ')</span>';
                            }
                            // Free disks stay selectable on purpose: the point
                            // of showing the path is to copy it into nmdctl.
                            return '<span style="user-select:text">' + label
                                + ' <span style="opacity:0.7">(' + gettext('free')
                                + ')</span></span>';
                        });
                        hint.setValue(parts.join('&nbsp; · &nbsp;'));
                    } catch (err) {
                        hint.setValue(gettext('Could not read the disk list'));
                    }
                },
                failure: function () {
                    hint.setValue(gettext('Could not read the disk list'));
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

                // Full width, under both columns: a disk list does not fit in
                // a half-width field. submitValue false - it is a hint, and
                // the API rejects keys the schema does not define.
                me.columnB = [
                    {
                        xtype: 'displayfield',
                        name: 'nonraid-node-disks',
                        submitValue: false,
                        fieldLabel: gettext('Node disks'),
                        value: gettext('Select a single node to list its disks'),
                        // The list can wrap over a few lines on a full node.
                        autoEl: { tag: 'div', style: 'line-height:1.6' },
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
                return this.callParent([values]);
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
