#!/bin/bash
# 1. functions
# gets called when user uses flags -v --v --version version
# prints script version
runversion () {
  echo 'EC2 Apache Hello World Server Installation Script v1.0.0'
  echo 'Andrew Lee, 2018, for Leidos Programming Project'
}

# gets called when user uses flags -h --h --help help
# prints script options
runhelp () {
  echo "Usage:
  ./script.sh [instance_type] [options]
Arguments
  instance_type               [optional]: Supply with the desired instance type. If not provided, script will automatically choose t2.micro.
General Options
  -v, --v, --version, version Show software version and information
  -h, --h, --help, help       Show help for commands."

}

# First, check if keyname leidos exists. If it doesn't exist, create it, if it does, ensure it is the same value as what is stored in ~/.ssh/id_rsa.pub
sshkeys () {
  # loop through all the key names stored in EC2, and see if any of them are named "leidos", if a key named leidos exists, skip creating the key.
  for value in $(aws ec2 describe-key-pairs | grep KeyName | awk '{print $2}' | sed -e 's/^"//' -e 's/"$//')
  do
    if [ "$value" = "leidos" ]; then
      echo 'Key Pair with the name "leidos" found. Assuming this was generated by a prior run of this script, and it correctly inserted your local machines public ssh key when it was initially set up.'
      return
    fi
  done

  echo 'Creating new key pair using your ssh ssh key stored at "~/.ssh/id_rsa.pub"'
  # Check if ssh public_key exists in file (to add to authorized_keys in the new EC2 instance to allow for passwordless ssh-ing)
  public_key=$(cat ~/.ssh/id_rsa.pub)
  if [ "$public_key" = "" ]; then
    echo 'This script requires you to have already configured ssh keys for your client machine (in order to add them to the authorized_keys EC2 remote machine.'
    echo 'Generate these keys using the command "ssh-keygen -t rsa"'
    exit
  fi

  # Import the key as name leidos with the value of the public_key variable we stored the value of public_key to
  aws ec2 import-key-pair --key-name leidos --public-key-material "$public_key"
  echo 'Created (imported) key pair with the name "leidos"'
}

# Checks all available security group names for a specific security group "leidos". If said security group exists, exit funtion without doing anything. If not, create the security group with permission to access port 22 and port 80
securitygroup() {
  # Loop through security group names
  for value in $(aws ec2 describe-security-groups | grep GroupName | awk '{print $2}' | sed 's/"//g')
  do
    if [ "${value%?}" = "leidos" ]; then
      # since security group leidos already exists (we can assume this program already ran previously creating the security group with the necessary access points), return without doing anything
      echo 'Security group with the name "leidos" was found. Assuming this was set up in a previous run of this script and will just assume this existing security group has the necessary access rights'
      security_group_id=$(aws ec2 describe-security-groups --group-names leidos --query "SecurityGroups[0].GroupId" --output text)
      return
    fi
  done
  # Since security group with the name "leidos" does not exist, create it with the aforementioned access permissions which we will need to set up the servers.
  echo 'Creating security group "leidos"'
  # Loop through VPCS's and find the default VPCS, use the default VPC ID to create security group.
  OLDIFS=$IFS # Want to preserve IFS to return to after we no longer want to create arrays by newline
  IFS=$'\n'
  ARR=$(aws ec2 describe-vpcs | tr -d '"' | sed 's/ ^"\(.*\)".*/\1/')
  for value in $ARR; do
    vpcidgrep=$(echo $value | grep "VpcId" | sed 's/ //g')
    isdefault=$(echo $value | grep "IsDefault: true" | sed 's/ //g')
    if [ ! "$vpcidgrep" = "" ]; then
      vpcid=${vpcidgrep%?};
      vpcid=$(echo $vpcid | cut -c 7-)
    fi
    if [ "$isdefault" = "IsDefault:true" ]; then
      IFS=$OLDIFS
      security_group_id=$(aws ec2 create-security-group --group-name leidos --description "Testing security group to complete Leidos Coding Project" --vpc-id vpc-bb4140df | awk 'NR==2{print $2}' | sed -e 's/^"//' -e 's/"$//')
      aws ec2 authorize-security-group-ingress --group-id $security_group_id --protocol tcp --port 22 --cidr 0.0.0.0/0
      aws ec2 authorize-security-group-ingress --group-id $security_group_id --protocol tcp --port 80 --cidr 0.0.0.0/0
      echo 'Created security group "leidos" with group authorizations to allow for access to port 22 and 80'
    fi
  done

}

# Create instance and save the instance id to variable to be able to use in other parts of the program
# If the user defined a specific type of instance (i.e. "m5.xlarge", etc.), use that value for --instance-type, if blank, use t2.micro
createinstance () {
  if [ "$1" = "" ]; then
    echo 'You did not specify a instance type. So creating Ubuntu 16.04 LTS instance using the default instance type of t2.micro'
    instance_id=$(aws ec2 run-instances --image-id ami-2c7b5656 --count 1 --instance-type t2.micro --key-name leidos --security-group-id $security_group_id --query 'Instances[0].InstanceId' | sed -e 's/^"//' -e 's/"$//')
  else
    echo 'You specified a instance type of $1. Creating Ubuntu 16.04 LTS instance using this instance type.'
    instance_id=$(aws ec2 run-instances --image-id ami-2c7b5656 --count 1 --instance-type $1 --key-name leidos --security-group-id $security_group_id --query 'Instances[0].InstanceId' | sed -e 's/^"//' -e 's/"$//')
  fi
  echo 'Created instance with the instance id of '$instance_id
  sleep 5
}


# Uses passwordless SSH (which we established using the users ssh public key) to run updates, upgrades, the installation of Apache, and finally change the default index.html file to be a simple Hello World HTML file.
run_updates_installs_configurations () {
  currentstatus=$(aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[0].Instances[0].State.Name' | sed 's/"//g')
  # Check if the currentstatus of of the instance is "running". If it is not running, pause for 2 seconds, and run this script again.
  # If it is running, start running remote commands on the Ubuntu instance using passwordless ssh
  if [ "$currentstatus" = "running" ]; then
    echo 'Instance successfully running, sleeping for 30 seconds to ensure all system functionality is up and running and then running commands'
    sleep 30
    # Need to disable apt-daily.service which for some reason locks dpkg and prevents program from manually running apt commands
    ssh -o StrictHostKeyChecking=no -tt ubuntu@$ip "sudo systemctl disable apt-daily.service"
    ssh -tt ubuntu@$ip "sudo systemctl disable apt-daily.timer"
    sleep 10
    set +e
    echo 'runing command "sudo apt update" on remote machine'
    ssh -tt ubuntu@$ip "sudo apt update"
    # Hit a wierd issue with the Kubernetes PPA becoming undefined in the last few months, and it crashing the apt update process
    # Resolve by killing all dpkg processes, then removing the lock file. (probably a problem if we needed Kubernetes, but since we don't, just go with the simple solution)
    sleep 5
    ssh -tt ubuntu@$ip "sudo killall dpkg"
    ssh -tt ubuntu@$ip "sudo rm /var/lib/dpkg/lock"
    echo 'runing command "sudo apt upgrade" on remote machine'
    # Run upgrade
    ssh -tt ubuntu@$ip "sudo apt -y upgrade"
    echo 'runing command "sudo apt dist-upgrade" on remote machine'
    # Run dist-upgrade
    ssh -tt ubuntu@$ip "sudo apt -y dist-upgrade"
    echo 'runing command "sudo apt install apache2" on remote machine'
    # Install apache
    ssh -tt ubuntu@$ip "sudo apt -y install apache2"
    # Recursively change ownernship of /var/www directory
    ssh -tt ubuntu@$ip "sudo chown -R ubuntu /var/www"
    # Replace default index.html file (created by Apache during installation) with the hello world HTML data.
    ssh -tt ubuntu@$ip 'sudo echo "<html><body><p>Hello World</p></body></html>" > /var/www/html/index.html'
  else
    sleep 2
    run_updates_installs_configurations
  fi
}


# 2. Run checks to ensure this script has pre-requisites are fulfilled.

# First check is user installed AWS command line tools
if ! hash aws 2>/dev/null; then
  echo 'aws command not found. Please install using pip'
  echo 'The command to install aws cli is: "pip3 install awscli --upgrade --user" or "brew install awscli" on homebrew'
  exit
fi

# Check if aws has been configured with a aws_access_key_id and aws_secret_access_key
if [[ $(aws configure get aws_secret_access_key) = '' || $(aws configure get aws_access_key_id) = '' ]]; then
  echo 'aws configure has not been run. Hence, program was unable to retrieve a valid aws_access_key_id or aws_secret_access_key'
  echo 'Please run the command "aws configure" and enter the credentials so that AWS CLI can access it.'
  echo 'If you need to generate an access key, access "https://console.aws.amazon.com/iam/home", add a new user for this purpose, and give it programmatic access permission well as adding it to a resource group which has "AdministratorAccess". The resulting screen will let you see the Access key ID and the Secret access key which you will enter into the prompt for "aws configure"'
  exit
fi


# 3. Actually main logic

# I. Check flags

# Check for help flag
if [ "$1" = "-h" ] || [ "$1" = "--h" ] || [ "$1" = "--help" ] || [ "$1" = "help" ]; then
  runhelp
  exit
fi

# Check for version flag
if [ "$1" = "-v" ] || [ "$1" = "--v" ] || [ "$1" = "--version" ] || [ "$1" = "version" ]; then
  runversion
  exit
fi

# Import public_key as security key to launch EC2 instances using function on line ...
sshkeys

# Use a security group which allows for access to EC2 instance on SSH and HTTP (port 22 and 80)
securitygroup

# Create instance, save instance_id into variable
createinstance $1

# Sleep for 10 seconds to make sure the IP is set up, then save ip into variable
sleep 10
ip=$(aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[*].Instances[*].PublicIpAddress' --output text)
echo 'The IP of the new machine is '$ip

# Use ssh to do system updates, install apache2 from Ubuntu's system package archives, and configure Apache to serve Hello World
run_updates_installs_configurations

# End of program
echo '*******************************************'
echo 'Congratulations, script successfully created an instance of Ubuntu 16.04 running Apache server which displays the file "/var/www/html/index.html" at the root.'
echo 'Check out the created website by going to "http://'$ip'" in your browser.'
