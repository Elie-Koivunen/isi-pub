mkdir -m 770 /ifs/data/lic
isi license generate --action=generate_activation --file=/ifs/data/lic/cluster-activation-request.req --include=ONEFS --include=SMARTCONNECT_ADVANCED --include=SMARTQUOTAS --include=SNAPSHOTIQ --include=SYNCIQ
isi license list
isi license add --evaluation=ONEFS,HDFS,SMARTCONNECT_ADVANCED,SMARTQUOTAS,SNAPSHOTIQ,SYNCIQ
isi license list
