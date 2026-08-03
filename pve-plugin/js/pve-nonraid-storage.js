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
        var NONRAID_FIELDS = [
            {
                name: 'nonraid-super',
                label: 'Superblock File',
                xtype: 'textfield',
                value: '/nonraid.dat',
                allowBlank: false,
                column: 1,
            },
            {
                name: 'nonraid-disk-prefix',
                label: 'Disk Mount Prefix',
                xtype: 'textfield',
                emptyText: '/mnt/disk',
                allowBlank: true,
                deleteEmptyOnEdit: true,
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

                me.callParent();
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
