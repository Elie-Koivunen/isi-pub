isi_for_array -sXI 'for i in $(isi_nodes %{name}":"%{internal_a_address}":"%{internal_b_address}); do name=$(echo $i | cut -f 1 -d ":"); if [ "$name" != "$(hostname)" ]; then iba=$(echo $i | cut -f 2 -d":"); ibb=$(echo $i | cut -f 3 -d":"); ping -c2 -t2 $iba > /dev/null; if [ $? -eq 0 ]; then iba_ok="|A| OK "; else iba_ok="|A| FAIL "; fi; ping -c2 -t2 $ibb > /dev/null; if [ $? -eq 0 ]; then ibb_ok="|B| OK"; else ibb_ok="|B| FAIL "; fi ; echo $name $iba_ok $ibb_ok; fi; done' | grep -v "Host is down"
