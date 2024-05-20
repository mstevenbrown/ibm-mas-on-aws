#!/bin/bash
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Trap the SIGINT signal (Ctrl+C)
trap ctrl_c INT

function ctrl_c() {
    echo "Stopping the script..."
    exit 1
}

if [[ $# -ne 3 ]]; then
        echo "Usage: $0 BUCKETNAME CLUSTER_NAME BASE_DOMAIN"
        exit
fi

# We want to use the Instance profile on PrivateSeedEc2, so remove the .aws folder and unset access key id and secret accesskey and use EC2 instance profile
rm -rf /root/.aws
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY

# Create a new IAM user with that will be used to run the openshift-install
export BUCKETNAME=$1
export CLUSTERNAME=$2
export BASEDOMAIN=$3

TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone -H "X-aws-ec2-metadata-token: $TOKEN"`
export AWS_DEFAULT_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed 's/[a-z]$//'`"

# Update Session Manager preferences (command line)
# aws ssm update-document --name SSM-SessionManagerRunShell --content "file:///root/ibm-mas-on-aws/config/SessionManagerRunShell.json" --document-version "\$LATEST" --region ${AWS_DEFAULT_REGION}

echo `date "+%Y/%m/%d %H:%M:%S"` "Sleeping for 10 seconds before downloading the install-config-wip.yaml file"
aws s3 cp s3://${BUCKETNAME}/install-config-wip.yaml /root/install-dir/install-config-wip.yaml --region ${AWS_DEFAULT_REGION}

# Download entitlement.lic and pull-secret from S3
aws s3 cp s3://${BUCKETNAME}/pull-secret /root/install-dir/pull-secret.txt --region ${AWS_DEFAULT_REGION}
aws s3 cp s3://${BUCKETNAME}/entitlement.lic /root/install-dir/entitlement.lic --region ${AWS_DEFAULT_REGION}

# Download the Certificate bundles for specific AWS Regions
# Note this is the certificate that will be used for RDS and Document DB
if [[ ${AWS_DEFAULT_REGION} == *gov* ]]; then DBCRT="https://truststore.pki.us-gov-west-1.rds.amazonaws.com/${AWS_DEFAULT_REGION}/${AWS_DEFAULT_REGION}-bundle.pem"; else DBCRT="https://truststore.pki.rds.amazonaws.com/${AWS_DEFAULT_REGION}/${AWS_DEFAULT_REGION}-bundle.pem"; fi
wget -q ${DBCRT} -P /root/install-dir/
[ ! -f "/root/install-dir/${AWS_DEFAULT_REGION}-bundle.pem" ] && echo "The certificate bundle for the region not found. Ensure file is present in downloaded" && exit 1
aws s3 cp /root/install-dir/${AWS_DEFAULT_REGION}-bundle.pem s3://${BUCKETNAME}/${AWS_DEFAULT_REGION}-bundle.pem --region ${AWS_DEFAULT_REGION}

# Download the container-runtime-config.yml
wget -q https://ws-assets-prod-iad-r-iad-ed304a55c2ca1aee.s3.us-east-1.amazonaws.com/78554b88-0cd8-45a1-b9ee-2c1078aa6995/config/container-runtime-config.yml -P /root/install-dir/
[ ! -f "/root/install-dir/container-runtime-config.yml" ] && echo "The container-runtime-config.yml could not be downloaded" && exit 1
aws s3 cp /root/install-dir/container-runtime-config.yml s3://${BUCKETNAME}/container-runtime-config.yml --region ${AWS_DEFAULT_REGION}



[ ! -f "/root/install-dir/pull-secret.txt" ] && echo "pull-secret file not found. Ensure file is present in the pre-requisite s3 bucket" && exit 1
[ ! -f "/root/install-dir/entitlement.lic" ] && echo "entitlement.lic file not found. Ensure file is present in the pre-requisite s3 bucket" && exit 1
[ ! -f "/root/install-dir/install-config-wip.yaml" ] && echo "install-config-wip.yaml file not found. Ensure file is present in the pre-requisite s3 bucket" && exit 1

export PULLSECRET=`cat /root/install-dir/pull-secret.txt`

# Use the public secret key  used to login to the cluster nodes
## ssh core@workerip
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
export SSHPUBLICKEY=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key)

## Create an SSH key. The public key will be placed in cluster nodes to allow ssh into the cluster nodes:
## ssh core@workerip
#echo -e y | ssh-keygen -q -t rsa -N "" -f /root/.ssh/id_rsa
#eval "$(ssh-agent -s)"
#ssh-add /root/.ssh/id_rsa
#export SSHPUBLICKEY=`cat /root/.ssh/id_rsa.pub`

## Substitute SSHPUBLICKEY and PULLSECRET
envsubst < /root/install-dir/install-config-wip.yaml > /root/install-dir/install-config.yaml
rand=$RANDOM
export IAMUSER=ocp_install_seed_$rand
export POLICYNAME=ocp_install_seed_policy_$rand
echo $IAMUSER
# Create an IAM user as per https://docs.openshift.com/container-platform/4.10/installing/installing_aws/installing-aws-account.html#installation-aws-permissions_installing-aws-account
aws iam create-user --user-name ${IAMUSER}
policy_output=`aws iam create-policy --policy-name $POLICYNAME --policy-document file:///root/ibm-mas-on-aws/policies/efs-policy.json`
POLICYARN=`echo $policy_output | jq -r '.[].Arn'`
echo "Policy ARN:" $POLICYARN
aws iam attach-user-policy --policy-arn ${POLICYARN} --user-name ${IAMUSER}
json=`aws iam create-access-key --user-name $IAMUSER`
export AWS_ACCESS_KEY_ID=`echo $json | jq -r '.AccessKey.AccessKeyId'`
export OCP_USER_KEY=$AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=`echo $json | jq -r '.AccessKey.SecretAccessKey'`
export DEFAULT_OUTPUT=json

echo `date "+%Y/%m/%d %H:%M:%S"` "Generated AWS Access Keys"
echo $AWS_ACCESS_KEY_ID
echo $AWS_SECRET_ACCESS_KEY
mkdir -p /root/.aws
cat  > /root/.aws/config<<EOFCONFIG
[default]
output = $DEFAULT_OUTPUT
region = $AWS_DEFAULT_REGION
EOFCONFIG

cat  > /root/.aws/credentials<<EOFCRED
[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
EOFCRED

echo `date "+%Y/%m/%d %H:%M:%S"` "Sleeping for 20 seconds before openshift-install"
sleep 20
aws configure list

/root/install-dir/openshift-install create cluster --dir /root/install-dir/ --log-level=debug

## Echo the Console URL with Credentials
export OCP_USERNAME=kubeadmin
export OCP_PASSWORD=`cat /root/install-dir/auth/kubeadmin-password`

echo `date "+%Y/%m/%d %H:%M:%S"` "Sleeping for 10 seconds before oc login"
sleep 10

oc login -u $OCP_USERNAME -p $OCP_PASSWORD --server=https://api.${CLUSTERNAME}.${BASEDOMAIN}:6443 --insecure-skip-tls-verify=true
export CONSOLEURL=`oc whoami --show-console`
export IPI_REGION=AWS_DEFAULT_REGION
#echo "Console URL = " $CONSOLEURL
#echo "Console UserName = "$OCP_USERNAME
#echo "Password = " $OCP_PASSWORD

# Create a secret with the OCP console secrets
if [[ -f /root/install-dir/metadata.json ]]; then
        export INFRAID=`cat /root/install-dir/metadata.json  | jq -r .infraID`"-ocp-console"
        echo `date "+%Y/%m/%d %H:%M:%S"` "Creating secret for OCP cluster in Secrets Manager  .........  " $INFRAID
        aws secretsmanager create-secret \
        --name $INFRAID \
        --description "OCP Console credentials" \
        --secret-string "{\"user\":\"kubeadmin\",\"password\":\"${OCP_PASSWORD}\",\"consoleurl\":\"${CONSOLEURL}\"}"
else
        echo `date "+%Y/%m/%d %H:%M:%S"` "Could not find /root/install-dir/metadata.json file"
        exit 1
fi
