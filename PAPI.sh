#auth.json file content

{
"username": "root",
"password": "a",
"services": ["platform","namespace"]
}



# create session
curl -k --header "Content-Type: application/json" -c pipari.txt -X POST -d @auth.json https://192.168.255.12:8080/session/1/session

# revise cookie
cat pipari.txt|egrep -i isicsrf|awk '{print "X-CSRF-Token:",$7;}'
cat pipari.txt|egrep -i isisessid|awk '{print "isisessid="$7;}'



curl -vk "https://192.168.255.12:8080/platform/5/license/licenses" -b 'isisessid=e7a849b5-77a7-411d-b712-fdcae8d58669' -H 'X-CSRF-Token: 544eebf1-6ad7-4260-9656-40c152801308' --referer https://192.168.255.12:8080

# use cookie and csrf token
curl -vk "https://192.168.255.12:8080/platform/?describe&list&all" -b 'isisessid=e7a849b5-77a7-411d-b712-fdcae8d58669' -H 'X-CSRF-Token: 544eebf1-6ad7-4260-9656-40c152801308' --referer https://192.168.255.12:8080


curl -vk "https://192.168.255.12:8080/platform/10/cluster/nodes" -b 'isisessid=e7a849b5-77a7-411d-b712-fdcae8d58669' -H 'X-CSRF-Token: 544eebf1-6ad7-4260-9656-40c152801308' --referer https://192.168.255.12:8080


curl -vk "https://192.168.255.12:8080/platform/5/license/licenses" -b 'isisessid=e7a849b5-77a7-411d-b712-fdcae8d58669' -H 'X-CSRF-Token: 544eebf1-6ad7-4260-9656-40c152801308' --referer https://192.168.255.12:8080

