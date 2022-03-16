#!/bin/bash
mycertpath=
myclusters=


# v1 :h:p:c:g:s:
# v2 lr:lc:rr:rc:ru:lu:
while getopts ":h:p:c:g:s:" options; do
case "${options}" in   
h)
# header content & disclaimers
clear
echo "##############################################################################################"
echo "This tool performs the following:                                                             "
echo "- generate a SSL certificate to be used as a root certificate authority                       "
echo "- generate a SSL certificate for each cluster                                                 "
echo "- add the SSL certificates into OneFS                                                         "
echo "                                                                                              "
echo "# Per intent, this script does not check or remove existing SSL certificates.                 "
echo "# to avoid accidental removal. The state and requirement of existing SSL certificates         "
echo "# should be manually checked by the storage admin!                                            "
echo "#                                                                                             "
echo "# The following commands list the existing SSL certificates in their corresponding roles;     "
echo "# - Review the defined SSL certificate root authorities:                                      "
echo "#   isi certificates authority list                                                           "
echo "# - Review the SyncIQ set peer SSL certificates:                                              "
echo "#   isi sync certificate peer list                                                            "
echo "# - Review the SyncIQ set server SSL certificates:                                            "
echo "#   isi sync certificate server list                                                          "
echo "#                                                                                             "
echo "# Each SyncIQ policy needs to be designated to use a specific peer SSL certificate.           "
echo "# Apply the peer SSL reference on each policy while the SyncIQ policy is not running and      "
echo "# is temporarily disabled. 																	"
echo "##############################################################################################"
echo "# "
echo "# -help	Description and available switches"
echo "# "
echo "# -p 		-p (PATH) Define the path to be created and used as a repository"
echo "#		example: -p /ifs/data/certificates"
echo "# -c 		-c (clustername1-replication.acme.com,clustername2-replication.foo.bar) comma separate fqdn cluster names."
echo "# 	Do not use spaces or quotes and the fqdn should point to the system access zone!). This option requires the -p option!"
echo "# "
echo "#		example: -c cls01,cls02"
cho "# "
echo "# -g Generate randomly named cluster specific ssl files signed by the rootca. This option requires the -p option!"
echo "# "
echo "# -s Generate scripts to install the certificates .."
echo "# "
echo "# "
exit 1
;; 
p)
# define the path to use as a repository and
# generate the root ca files

	mycertpath=${OPTARG}
	if [ -d $mycertpath ];
	then
		echo "#### Repository already exists: $mycertpath "
		echo "#### Please provide another path. "
		exit 1
	else
		echo "# Creating $mycertpath as a repository .."
		mkdir -m 700 -p $mycertpath
		echo $mycertpath
		ls -lhnG `dirname $mycertpath`|egrep `basename $mycertpath`|egrep -v total|awk '{print $1,$3,$4,$9;}'
		echo
		echo
		
		rootcafilename=SIQ_rootCA_EXPIRES-`date -v+10y +%d-%B-%Y`
		
		# create rootCA
		cd $mycertpath
		echo "# Creating root CA .."
		openssl req -new -newkey rsa:4096 -sha256 -nodes -out $rootcafilename.csr -keyout $rootcafilename.key -subj "/C=FI/ST=`date +"%Z"`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`/L=SIQ-rootCA/O=PowerScale/CN=Millenial@Support.LoCaL"
		openssl x509 -days 3650 -trustout -signkey $rootcafilename.key -req -in $rootcafilename.csr -out $rootcafilename.crt
		openssl x509 -in $rootcafilename.crt -outform PEM -out $rootcafilename.pem
		echo
		echo
		chmod 600 SIQ_rootCA_EXPIRES-*
		echo "# root CA files created accordingly:"
		pwd
 		ls -lhnG $mycertpath|egrep -v total|awk '{print $1,$3,$4,$9;}'
		cd -
		echo
		echo
	fi
;;

c)
# create the cluster specific SSL files and have them signed by the root CA 

	cd $mycertpath
	pwd
	myclusters=${OPTARG}
	echo "# Provided cluster names: $myclusters"
	mycluster=$(echo $myclusters|tr "," "\n")
	for myclustername in $mycluster
	do 
		srvname=SIQ_${myclustername}_EXPIRES-`date -v+10y +%d-%B-%Y`
		echo "# Generating SSL certificate for cluster: $myclustername"
		echo "# Generating cluster specific files .."
		openssl req -new -newkey rsa:4096 -sha256 -nodes -out $srvname.csr -keyout $srvname.key -subj "/C=FI/ST=`date +"%Z"`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`/L=$myclustername/O=SIQ-rootCA/O=PowerScale/CN=Millenial@Support.LoCaL"
		openssl x509 -days 3650 -req -in $srvname.csr -CA $rootcafilename.crt -CAkey $rootcafilename.key -set_serial 01 -out $srvname.crt
		openssl x509 -in $srvname.crt -outform PEM -out $srvname.pem
		openssl verify -CAfile $rootcafilename.pem $srvname.pem
		echo
		echo 
		chmod 600 SIQ_$myclustername_exp*
		echo "# Files created accordingly:"
		pwd
 		ls -lhnG $mycertpath|egrep -v total|awk '{print $1,$3,$4,$9;}'
	done
	cd -
	echo
	echo
	echo "# Done!"
	exit 1
;;



g)
# generate cluster specific ssl files signed by the rootca 
# this option does not require clusternames and would create the files with random string

	cd $mycertpath
	pwd
	myclusters=`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`,`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`
	echo "# Provided cluster names: $myclusters"
	mycluster=$(echo $myclusters|tr "," "\n")
	for myclustername in `$mycluster| cut -d"." -f1 `
	do 
		echo "# Generating SSL certificate for cluster: $myclustername"
		echo "# Generating cluster specific files .."
		openssl req -new -newkey rsa:4096 -sha256 -nodes -out $srvname.csr -keyout $srvname.key -subj "/C=FI/ST=`date +"%Z"`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`-`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1`/L=$myclustername/O=SIQ-rootCA/O=PowerScale/CN=Millenial@Support.LoCaL"
		openssl x509 -days 3650 -req -in $srvname.csr -CA $rootcafilename.crt -CAkey $rootcafilename.key -set_serial 01 -out $srvname.crt
		openssl x509 -in $srvname.crt -outform PEM -out $srvname.pem
		openssl verify -CAfile $rootcafilename.pem $srvname.pem
		echo
		echo 
		echo "# Files created accordingly:"
		pwd
 		ls -lhnG $mycertpath|egrep -v total|awk '{print $1,$3,$4,$9;}'
	done
	cd -
	pwd	
	echo
	echo
	exit 1
;;

s)
echo "generating ..."
;;

# TBD s)
# TBD isi certificate authority import --name=rootCA-SIQ --certificate-path=rootCA-SIQ_EXPIRES-`date -v+10y +%d-%B-%Y`.pem
# TBD isi sync certificates peer import --certificate-path=cls-$mycls2_EXPIRES-`date -v+10y +%d-%B-%Y`.pem  --name=peer-cls-$mycls2_EXPIRES-`date -v+10y +%d-%B-%Y`
# TBD isi sync certificates server import --certificate-path=cls-$mycls1_EXPIRES-`date -v+10y +%d-%B-%Y`.pem --certificate-key-path=cls-$mycls1_EXPIRES-`date -v+10y +%d-%B-%Y`.key --name=server-cls-$mycls1_EXPIRES-`date -v+10y +%d-%B-%Y`;;
# TBD isi sync settings modify --cluster-certificate-id=`isi sync certificates server list -v|egrep -i "ID:"|awk '{print $2;}'`## v2 lr)

## v2 # locally install rootca files
## v2 echo "Applying the root CA certificate to the local cluster .."
## v2 isi certificate authority import --name=rootCA-SIQ --certificate-path=rootCA-SIQ_EXPIRES-`date -v+10y +%d-%B-%Y`.pem
## v2 echo done 
## v2 ;;
## v2 lc)
## v2 # locally installing server & peer certificates 
## v2 echo "Applying the server & peer certificates .."
## v2 isi sync certificates peer import --certificate-path=cls-$mycls2_EXPIRES-`date -v+10y +%d-%B-%Y`.pem  --name=peer-cls-$mycls2_EXPIRES-`date -v+10y +%d-%B-%Y`
## v2 isi sync certificates server import --certificate-path=cls-$mycls1_EXPIRES-`date -v+10y +%d-%B-%Y`.pem --certificate-key-path=cls-$mycls1_EXPIRES-`date -v+10y +%d-%B-%Y`.key --name=server-cls-$mycls1_EXPIRES-`date -v+10y +%d-%B-%Y`
## v2 isi sync settings modify --cluster-certificate-id=`isi sync certificates server list -v|egrep -i "ID:"|awk '{print $2;}'`
## v2 ;;
## v2 lu)
## v2 # locally update synciq policies to use SSL certificates 
## v2 echo "Applying the server & peer certificates .."
## v2 #TBD
## v2 ;;
## v2 rr)
## v2 echo "Remotely applying the root CA certificate to target cluster.."
## v2 isi certificate authority import --name=rootCA-SIQ --certificate-path=rootCA-SIQ_EXPIRES-`date -v+10y +%d-%B-%Y`.pem
## v2 echo done 
## v2 ;;
## v2 rc)
## v2 # Install server & peer certificate
## v2 echo "Applying the remote server & peer certificates .."
## v2 isi sync certificates peer import --certificate-path=cls-$mycls1_EXPIRES-`date -v+10y +%d-%B-%Y`.pem  --name=peer-cls-$mycls1_EXPIRES-`date -v+10y +%d-%B-%Y`
## v2 isi sync certificates server import --certificate-path=cls-$mycls2_EXPIRES-`date -v+10y +%d-%B-%Y`.pem --certificate-key-path=cls-$mycls2_EXPIRES-`date -v+10y +%d-%B-%Y`.key --name=server-cls-$mycls2_EXPIRES-`date -v+10y +%d-%B-%Y`
## v2 isi sync settings modify --cluster-certificate-id=`isi sync certificates server list -v|egrep -i "ID:"|awk '{print $2;}'`
## v2 ;;
## v2 ru)
## v2 # remotely update synciq policies to use SSL certificates 
## v2 echo "Settung the synciq policy certificate .."
## v2 #TBD
esac
done
mycertpath=
myclusters=
mycluster=
myclustername=

echo "# Run --help switch for details and options"
exit 0



