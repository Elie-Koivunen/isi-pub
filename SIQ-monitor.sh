echo; for m in `isi_classic sync jobs list|grep Running|awk '{print $1}'`; do echo "$m - output time: `date`"; isi sync jobs reports view --policy=$m|grep -E "Sync Type|Total Files|New Files Replicated|Bytes Transferred|Total Network Bytes|Total Data Bytes|File Data Bytes|Phase:|State:|Duration:"; echo; done
