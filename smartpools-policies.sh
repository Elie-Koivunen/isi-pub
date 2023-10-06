#!/bin/sh

isi filepool policies create \
--name="RND-Default_accdb_csv_db" \
--data-access-pattern=random \
--description="Random Access Pattern for ACCDB CSV DB" \
--begin-filter \
--file-type=file --and --name="*.accdb" --or \
--file-type=file --and --name="*.csv" --or \
--file-type=file --and --name="*.db" \
--end-filter \

isi filepool policies create \
--name="RND-Default_dbf_dsk_flv" \
--data-access-pattern=random \
--description="Random Access Pattern for dbf dsk flv" \
--begin-filter \
--file-type=file --and --name="*.dbf" --or \
--file-type=file --and --name="*.dsk" --or \
--file-type=file --and --name="*.flv" \
--end-filter \

isi filepool policies create \
--name="RND-Default_mdb_mdf_pdb" \
--data-access-pattern=random \
--description="Random Access Pattern for mdb mdf pdb" \
--begin-filter \
--file-type=file --and --name="*.mdb" --or \
--file-type=file --and --name="*.mdf" --or \
--file-type=file --and --name="*.pdb" \
--end-filter \

isi filepool policies create \
--name="RND-Default_pst" \
--data-access-pattern=random \
--description="Random Access Pattern for pst" \
--begin-filter \
--file-type=file --and --name="*.pst" \
--end-filter \

isi filepool policies create \
--name="RND-Mx2_hdd_vdi_vhd" \
--data-access-pattern=random \
--set-requested-protection=2x \
--description="random Access Pattern and mirror x2 protection for hdd vdi vhd" \
--begin-filter \
--file-type=file --and --name="*.hdd" --or \
--file-type=file --and --name="*.vdi" --or \
--file-type=file --and --name="*.vhd" \
--end-filter \

isi filepool policies create \
--name="RND-Mx2_vmdk" \
--data-access-pattern=random \
--set-requested-protection=2x \
--description="random Access Pattern and mirror x2 protection for vmdk" \
--begin-filter \
--file-type=file --and --name="*.vmdk" \
--end-filter \

isi filepool policies create \
--name="STREAM-Default_avi_iso_m4v" \
--data-access-pattern=streaming \
--description="Streaming Access Pattern for avi iso m4v" \
--begin-filter \
--file-type=file --and --name="*.avi" --or \
--file-type=file --and --name="*.iso" --or \
--file-type=file --and --name="*.m4v" \
--end-filter \

isi filepool policies create \
--name="STREAM-Default_mov_mpg_tar" \
--data-access-pattern=streaming \
--description="Streaming Access Pattern for mov mpg tar" \
--begin-filter \
--file-type=file --and --name="*.mov" --or \
--file-type=file --and --name="*.mpg" --or \
--file-type=file --and --name="*.tar" \
--end-filter \
