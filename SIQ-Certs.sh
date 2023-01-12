#!/bin/bash

# collection of variables for scripting:

# update the following variables!!!
myrepo=/ifs/data/certs
mycls1=sslsiq9101
mycls2=sslsiq9102

if [ -d "$myrepo" ]; then
                echo "#### working repository exists: $myrepo ####"
                exit 0
        else
                mkdir -m 700 -p $myrepo
fi

# create rootCA
cd $myrepo

echo Creating rootCA..
openssl req -new -newkey rsa:4096 -sha256 -nodes -out rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.csr -keyout rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.key -subj "/C=FI/ST=`date +"%Z"`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`/L=rootCA-SIQ/O=PowerScale/CN=Millenial@Support.LoCaL"
openssl x509 -days 3650 -trustout -signkey rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.key -req -in rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.csr -out rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.crt
openssl x509 -in rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.crt -outform PEM -out rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.pem

echo Creating initiator cluster specific certs ..
openssl req -new -newkey rsa:4096 -sha256 -nodes -out cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.csr -keyout cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.key -subj "/C=FI/ST=`date +"%Z"`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`/L=$mycls1/O=rootCA-SIQ/O=PowerScale/CN=Millenial@Support.LoCaL"
openssl x509 -days 3650 -req -in cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.csr -CA rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.crt -CAkey rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.key -set_serial 01 -out cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.crt
openssl x509 -in cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.crt -outform PEM -out cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.pem
openssl verify -CAfile rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.pem cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.pem

echo Creating target cluster specific certs ..
openssl req -new -newkey rsa:4096 -sha256 -nodes -out cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.csr -keyout cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.key -subj "/C=FI/ST=`date +"%Z"`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`/L=$mycls2/O=rootCA-SIQ/O=PowerScale/CN=Millenial@Support.LoCaL"
openssl x509 -days 3650 -req -in cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.csr -CA rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.crt -CAkey rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.key -set_serial 01 -out cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.crt
openssl x509 -in cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.crt -outform PEM -out cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.pem
openssl verify -CAfile rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.pem cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.pem


echo Setting up primary cluster certs ..
isi certificate authority import --name=rootCA-SIQ --certificate-path=rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.pem
isi sync certificates peer import --certificate-path=cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.pem  --name=peer-cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`
isi sync certificates server import --certificate-path=cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.pem --certificate-key-path=cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.key --name=server-cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`
isi sync settings modify --cluster-certificate-id=`isi sync certificates server list -v|egrep -i "ID:"|awk '{print $2;}'`


echo Setting up secondary cluster certs ..
echo copy the generated certinstall.sh script + pem files to the second cluster and run on the second cluster

echo "isi certificate authority import --name=rootCA-SIQ --certificate-path=rootCA-SIQ-exp-`date -v+10y +%d-%B-%Y`.pem" >> certinstall.sh
echo "isi sync certificates peer import --certificate-path=cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`.pem  --name=peer-cls-$mycls1-exp-`date -v+10y +%d-%B-%Y`" >> certinstall.sh
echo "isi sync certificates server import --certificate-path=cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.pem --certificate-key-path=cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`.key --name=server-cls-$mycls2-exp-`date -v+10y +%d-%B-%Y`" >> certinstall.sh
echo "isi sync settings modify --cluster-certificate-id=`isi sync certificates server list -v|egrep -i ID:|awk '{print $2;}'`" >> certinstall.sh
