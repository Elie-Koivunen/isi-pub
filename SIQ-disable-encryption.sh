isi sync settings modify --service=off

isi sync settings modify --encryption-required=false

isi services isi_migrate disable

isi services isi_migrate enable

isi sync settings modify --service=on
