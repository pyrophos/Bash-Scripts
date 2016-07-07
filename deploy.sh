#!/bin/sh
#
#  Deployment Script
#

set -x

# shutdown last installation
#find . -name stop-ds |parallel
#rm -rf ds*

# Global Constants
ROOT_DIR=`pwd`
DS_ZIP="directory-4.7.0.0-GA-image.zip"
PS_ZIP="proxy-4.5.1.7-GA-image.zip"
SS_ZIP="/Users/lsaenz/workspace/images/3.1.1.1/sync-3.1.1.1-GA-image.zip"

# Install Server Images
cd $ROOT_DIR
unzip $DS_ZIP -d tmp
mkdir ds-image
mv `find tmp -name 'setup' |sed 's/setup/*/'` ds-image
rm -rf tmp

# Install Directory Server ds4
SERVER='ds4'
IMAGE='ds-image'
cd $ROOT_DIR
mkdir $SERVER
cp -R $IMAGE/. $SERVER
cd $SERVER
./setup --ldapport="4389" --basedn="dc=example,dc=com" --rootuserdn="cn=Directory Manager" --rootuserpassword="password" --cli --acceptlicense --no-prompt 
mv config/tools.properties config/tools.properties.orig
echo "hostname=localhost" >> config/tools.properties
echo "bindDN=cn=Directory Manager" >> config/tools.properties
echo "bindPassword=password" >> config/tools.properties
echo "port=4389" >> config/tools.properties
echo "useSSL=false" >> config/tools.properties
echo "useStartTLS=false" >> config/tools.properties

# Install Directory Server ds1
SERVER='ds1'
IMAGE='ds-image'
cd $ROOT_DIR
mkdir $SERVER
cp -R $IMAGE/. $SERVER
cd $SERVER
./setup --ldapport="1389" --basedn="dc=example,dc=com" --sampledata="1000" --rootuserdn="cn=Directory Manager" --rootuserpassword="password" --cli --acceptlicense --no-prompt 
mv config/tools.properties config/tools.properties.orig
echo "hostname=localhost" >> config/tools.properties
echo "bindDN=cn=Directory Manager" >> config/tools.properties
echo "bindPassword=password" >> config/tools.properties
echo "port=1389" >> config/tools.properties
echo "useSSL=false" >> config/tools.properties
echo "useStartTLS=false" >> config/tools.properties

# Install Directory Server ds2
SERVER='ds2'
IMAGE='ds-image'
cd $ROOT_DIR
mkdir $SERVER
cp -R $IMAGE/. $SERVER
cd $SERVER
./setup --ldapport="2389" --basedn="dc=example,dc=com" --sampledata="1000" --rootuserdn="cn=Directory Manager" --rootuserpassword="password" --cli --acceptlicense --no-prompt 
mv config/tools.properties config/tools.properties.orig
echo "hostname=localhost" >> config/tools.properties
echo "bindDN=cn=Directory Manager" >> config/tools.properties
echo "bindPassword=password" >> config/tools.properties
echo "port=2389" >> config/tools.properties
echo "useSSL=false" >> config/tools.properties
echo "useStartTLS=false" >> config/tools.properties

# Install Directory Server ds3
SERVER='ds3'
IMAGE='ds-image'
cd $ROOT_DIR
mkdir $SERVER
cp -R $IMAGE/. $SERVER
cd $SERVER
./setup --ldapport="3389" --basedn="dc=example,dc=com" --sampledata="1000" --rootuserdn="cn=Directory Manager" --rootuserpassword="password" --cli --acceptlicense --no-prompt 
mv config/tools.properties config/tools.properties.orig
echo "hostname=localhost" >> config/tools.properties
echo "bindDN=cn=Directory Manager" >> config/tools.properties
echo "bindPassword=password" >> config/tools.properties
echo "port=3389" >> config/tools.properties
echo "useSSL=false" >> config/tools.properties
echo "useStartTLS=false" >> config/tools.properties

# # Install Proxy Server ps1
# SERVER='ps1'
# IMAGE='ps-image'
# cd $ROOT_DIR
# mkdir $SERVER
# cp -R $IMAGE/. $SERVER
# cd $SERVER
# ./setup --ldapport="1489" --rootuserdn="cn=Directory Manager" --rootuserpassword="password" --acceptlicense --no-prompt 
# mv config/tools.properties config/tools.properties.orig
# echo "hostname=localhost" >> config/tools.properties
# echo "bindDN=cn=Directory Manager" >> config/tools.properties
# echo "bindPassword=password" >> config/tools.properties
# echo "port=1489" >> config/tools.properties
# echo "useSSL=false" >> config/tools.properties
# echo "useStartTLS=false" >> config/tools.properties

# Enable Replication for Replication Group 1
cd $ROOT_DIR/ds1
bin/dsreplication enable --host1 localhost --port1 1389 --bindDN1 "cn=Directory Manager" --bindPassword1 password --replicationport1="1989" --host2 localhost --port2 2389 --bindDN2 "cn=Directory Manager" --bindPassword2 password --replicationport2="2989" --basedn="dc=example,dc=com" --adminuid="admin" --adminpassword="password" --ignorewarnings --no-prompt 
bin/dsreplication enable --host1 localhost --port1 1389 --bindDN1 "cn=Directory Manager" --bindPassword1 password --replicationport1="1989" --host2 localhost --port2 3389 --bindDN2 "cn=Directory Manager" --bindPassword2 password --replicationport2="3989" --basedn="dc=example,dc=com" --adminuid="admin" --adminpassword="password" --ignorewarnings --no-prompt 

# Initialize the replication data for base
bin/dsreplication initialize --hostSource localhost --portSource 1389 --hostDestination localhost --portDestination 2389 --basedn="dc=example,dc=com" --adminuid="admin" --adminpassword="password" --ignorewarnings --no-prompt 
bin/dsreplication initialize --hostSource localhost --portSource 1389 --hostDestination localhost --portDestination 3389 --basedn="dc=example,dc=com" --adminuid="admin" --adminpassword="password" --ignorewarnings --no-prompt 

# Display status from each replica
cd $ROOT_DIR
ds1/bin/dsreplication status --displayServerTable --showAll --adminPassword password --no-prompt
ds2/bin/dsreplication status --displayServerTable --showAll --adminPassword password --no-prompt
ds3/bin/dsreplication status --displayServerTable --showAll --adminPassword password --no-prompt
ds4/bin/dsreplication status --displayServerTable --showAll --adminPassword password --no-prompt

# start mod load
ds1/bin/modrate --port 1389 --bindDN uid=admin,dc=example,dc=com --bindPassword password --entryDN "uid=user.[0-999],ou=People,dc=example,dc=com" --attribute description --valueLength 12 --numThreads 1  >/dev/null &
modratepid=$!
echo "Started modrate pid $modratepid"
sleep 10

# Backup the userRoot from ds1
ds1/bin/export-ldif --backendID userRoot --ldifFile userRoot.ldif

# Import data into ds4
ds4/bin/stop-ds
ds4/bin/import-ldif --backendID userRoot --ldifFile userRoot.ldif --overwrite --overwriteExistingEntries
ds4/bin/start-ds

# Enable Replication with ds4
ds4/bin/dsreplication enable --host1 localhost --port1 1389 --bindDN1 "cn=Directory Manager" --bindPassword1 password --replicationport1="1989" --host2 localhost --port2 4389 --bindDN2 "cn=Directory Manager" --bindPassword2 password --replicationport2="4989" --basedn="dc=example,dc=com" --adminuid="admin" --adminpassword="password" --ignorewarnings --no-prompt

# Display status from each replica
ds1/bin/dsreplication status --displayServerTable --showAll --adminPassword password --no-prompt
ds2/bin/dsreplication status --displayServerTable --showAll --adminPassword password --no-prompt
ds3/bin/dsreplication status --displayServerTable --showAll --adminPassword password --no-prompt
ds4/bin/dsreplication status --displayServerTable --showAll --adminPassword password --no-prompt

# Remove Server Images
cd $ROOT_DIR
rm -rf *-image

# Kill mod load
echo "I'm going to kill the latest ModRate process:"
jps -m |grep ModRate
sleep 10
kill -9 $(jps -m |grep "ModRate" |cut -d' ' -f1 |tail -1)

