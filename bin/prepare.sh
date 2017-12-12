#!/usr/bin/env bash

# This scripts extracts User ID from dashbase-license.yml and sets it as KAFKA_TOPIC,
# and also generates keystore and sets its password in KEYSTORE_PASSWORD.

if [[ -z "$1" ]]
then
  echo "
Missing your dashbase.io email.
Usage:

  ./bin/prepare.sh <email>"
  exit 1
fi

BASEDIR="$(cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd)"

# Prepare the license file by curling dashbase.io/license/get
echo "Getting license from dashbase.io and save to dashbase-license.yml locally. Will require your dashbase.io password."
echo "user: $1" > ${BASEDIR}/dashbase-license.yml
echo -n "license: " >> ${BASEDIR}/dashbase-license.yml
if ! command -v curl >/dev/null; then
  echo "`curl` not installed. Please get Dashbase license manually."
  exit 1
else
  KEY="$(curl https://www.dashbase.io/license/get -u $1)"
  echo -n "$KEY" >> ${BASEDIR}/dashbase-license.yml
  echo
  echo "$(cat ${BASEDIR}/dashbase-license.yml)"
  echo
fi

# Prepare AWS credentials for userdata.txt
echo "Getting AWS credentials."
if [[ -z "$AWS_ACCESS_KEY_ID" ]] || [[ -z "$AWS_SECRET_ACCESS_KEY" ]]
then
  echo "No env variables found, checking ~/.aws/credentials file."
  if [[ -e ~/.aws/credentials ]]
  then
    export AWS_ACCESS_KEY_ID="$(cat ~/.aws/credentials | grep -E 'aws_access_key_id = (.*)' | sed 's/aws_access_key_id = //')"
    export AWS_SECRET_ACCESS_KEY="$(cat ~/.aws/credentials | grep -E 'aws_secret_access_key = (.*)' | sed 's/aws_secret_access_key = //')"
  fi
  if [[ -z "$AWS_ACCESS_KEY_ID" ]] || [[ -z "$AWS_SECRET_ACCESS_KEY" ]]
  then
    echo "No AWS credentials were found. Please run `aws configure` or export the env variables manually before retrying."
    exit 1
  fi
fi

# Get cleaned user id to use as default Kafka topic
export USER_ID=$(cat $BASEDIR/dashbase-license.yml | grep user | sed -e 's/user://' -e 's/ //g' -e 's/[^a-zA-Z0-9\-]/-/g')
if [ -z "$USER_ID" ]; then
  echo "Cannot find User ID from dashbase-license.yml. Please make sure to configure dashbase-license.yml properly."
  exit -1
fi
export KEYSTORE_PATH="${BASEDIR}/keystore"
export KEYSTORE_ENV="${BASEDIR}/env"
export P12KEYSTORE_PATH="${BASEDIR}/keystore.p12"

# Bash generate random 32 character alphanumeric string (upper and lowercase) and
export KEYSTORE_PASSWORD=$(cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

sed -i ".backup" \
  -e "s/KEYSTORE_PASSWORD=.*/KEYSTORE_PASSWORD=${KEYSTORE_PASSWORD}/g" \
  -e "s/KAFKA_SSL_KEYSTORE_PASSWORD=.*/KAFKA_SSL_KEYSTORE_PASSWORD=${KEYSTORE_PASSWORD}/g" \
  -e "s/KAFKA_SSL_KEY_PASSWORD=.*/KAFKA_SSL_KEY_PASSWORD=${KEYSTORE_PASSWORD}/g" \
  -e "s/KAFKA_SSL_TRUSTSTORE_PASSWORD=.*/KAFKA_SSL_TRUSTSTORE_PASSWORD=${KEYSTORE_PASSWORD}/g" \
  -e "s/KAFKA_TOPIC=.*/KAFKA_TOPIC=${USER_ID}/g" \
  ${KEYSTORE_ENV}

echo "Generated keystore password, values saved in '${KEYSTORE_ENV}' and 'docker-compose.yml'"

echo "Deleting previous generated self signed SSL cert"
rm $KEYSTORE_PATH

echo "Generating SSL cert"
# Create keystore (self signed certificate)
keytool -genkey -noprompt \
 -alias dashbase \
 -dname "CN=dashbase.io, OU=Engineering, O=Dashbase, L=Santa clara, S=CA, C=US" \
 -keystore ${KEYSTORE_PATH} \
 -storepass ${KEYSTORE_PASSWORD} \
 -keypass ${KEYSTORE_PASSWORD} \
 -keyalg RSA  \
 -validity 3650 \
 -keysize 2048

echo "Get SSL cert and private key"
# Check for keytool
if ! command -v keytool >/dev/null; then
  echo "`keytool` command not found."
  exit 1
fi
keytool -importkeystore -srckeystore $KEYSTORE_PATH -destkeystore $P12KEYSTORE_PATH -deststoretype PKCS12 \
  -deststorepass $KEYSTORE_PASSWORD -srcstorepass $KEYSTORE_PASSWORD

# Check for openssl
if ! command -v openssl >/dev/null; then
  echo "`openssl` command not found."
  exit 1
fi
openssl pkcs12 -in $P12KEYSTORE_PATH -nokeys -out $BASEDIR/cert.pem -passin pass:$KEYSTORE_PASSWORD
openssl pkcs12 -in $P12KEYSTORE_PATH -nodes -nocerts -out $BASEDIR/key.pem -passin pass:$KEYSTORE_PASSWORD
# Cleanup
rm $P12KEYSTORE_PATH

echo "Done."
echo
echo "Please run the REX-Ray command on each instance (can also be found in $BASEDIR/rexray_cmd):"
echo "sudo docker plugin install rexray/ebs EBS_ACCESSKEY=$AWS_ACCESS_KEY_ID EBS_SECRETKEY=$AWS_SECRET_ACCESS_KEY" > $BASEDIR/rexray_cmd
echo "$(cat $BASEDIR/rexray_cmd)"