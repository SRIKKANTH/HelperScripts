#!/bin/bash
#
# This script is library for shell scripts used in Azure Linux Automation.
# Author: Srikanth Myakam
# Email	: v-srm@microsoft.com
#
#

LogFile="LogFile.log"
StatusFile="StatusFile.log"
echo "" > $LogFile

function LogMsg ()
{
	tee >> $LogFile
}

function UpdateStatus ()
{
	tee > $StatusFile
}

function check_exit_status ()
{
    exit_status=$?
    message=$1

    if [ $exit_status -ne 0 ]; then
        echo "$message: Failed (exit code: $exit_status)"
        if [ "$2" == "exit" ]
        then
            exit $exit_status
        fi
    else
        echo "$message: Success"
    fi
}

function get_lis_version ()
{
    lis_version=`modinfo hv_vmbus | grep "^version:"| awk '{print $2}'`
    if [ "$lis_version" == "" ]
    then
        lis_version="Default_LIS"
    fi
    echo $lis_version
}

function get_host_version ()
{
    dmesg | grep "Host Build" | sed "s/.*Host Build://"| awk '{print  $1}'| sed "s/;//"
}

function get_one_ip()
{
    ifconfig eth0 | grep "inet addr:"| awk '{print  $2}'| sed 's/addr://'
}

function detect_linux_ditribution_version()
{
    local  distro_version="Unknown"
    if [ -f /etc/centos-release ] ; then
        distro_version=`cat /etc/centos-release | sed s/.*release\ // | sed s/\ .*//`
    elif [ -f /etc/oracle-release ] ; then
        distro_version=`cat /etc/oracle-release | sed s/.*release\ // | sed s/\ .*//`
    elif [ -f /etc/redhat-release ] ; then
        distro_version=`cat /etc/redhat-release | sed s/.*release\ // | sed s/\ .*//`
    elif [ -f /etc/os-release ] ; then
        distro_version=`cat /etc/os-release|sed 's/"//g'|grep "VERSION_ID="| sed 's/VERSION_ID=//'| sed 's/\r//'`
	fi
    echo $distro_version
}

function detect_linux_ditribution()
{
    local  linux_ditribution=`cat /etc/*release*|sed 's/"//g'|grep "^ID="| sed 's/ID=//'`
    local temp_text=`cat /etc/*release*`
    if [ "$linux_ditribution" == "" ]
    then
        if echo "$temp_text" | grep -qi "ol"; then
            linux_ditribution='Oracle'
        elif echo "$temp_text" | grep -qi "Ubuntu"; then
            linux_ditribution='Ubuntu'
        elif echo "$temp_text" | grep -qi "SUSE Linux"; then
            linux_ditribution='SUSE'
        elif echo "$temp_text" | grep -qi "openSUSE"; then
            linux_ditribution='OpenSUSE'
        elif echo "$temp_text" | grep -qi "centos"; then
            linux_ditribution='CentOS'
        elif echo "$temp_text" | grep -qi "Oracle"; then
            linux_ditribution='Oracle'
        elif echo "$temp_text" | grep -qi "Red Hat"; then
            linux_ditribution='RHEL'
        else
            linux_ditribution='unknown'
        fi
    fi
    echo "$(echo "$linux_ditribution" | sed 's/.*/\u&/')"
}

function updaterepos()
{
    ditribution=$(detect_linux_ditribution)
    case "$ditribution" in
        Oracle|RHEL|CentOS)
            yum makecache
            ;;

        Ubuntu)
            apt-get update
            ;;
        SUSE|openSUSE|sles)
            zypper refresh
            ;;

        *)
            echo "Unknown ditribution"
            return 1
    esac
}

function install_rpm ()
{
    package_name=$1
    rpm -ivh --nodeps  $package_name
    check_exit_status "install_rpm $package_name"
}

function install_deb ()
{
    package_name=$1
    dpkg -i  $package_name
    apt-get install -f
    check_exit_status "install_deb $package_name"
}

function apt_get_install ()
{
    package_name=$1
    DEBIAN_FRONTEND=noninteractive apt-get install -y  --force-yes $package_name
    check_exit_status "apt_get_install $package_name"
}

function yum_install ()
{
    package_name=$1
    yum install -y $package_name
    check_exit_status "yum_install $package_name"
}

function zypper_install ()
{
    package_name=$1
    zypper --non-interactive in $package_name
    check_exit_status "zypper_install $package_name"
}

function install_package ()
{
    local package_name=$@
    ditribution=$(detect_linux_ditribution)
	for i in "${package_name[@]}"
	do
	    case "$ditribution" in
	        Oracle|RHEL|CentOS)
	            yum_install "$package_name"
	            ;;

	        Ubuntu)
	            apt_get_install "$package_name"
	            ;;

	        SUSE|OpenSUSE|sles)
	            zypper_install "$package_name"
	            ;;

	        *)
	            echo "Unknown ditribution"
	            return 1
		esac
	done
}

function creat_partitions ()
{
    disk_list=($@)
    echo "Creating partitions on ${disk_list[@]}"

    count=0
    while [ "x${disk_list[count]}" != "x" ]
    do
       echo ${disk_list[$count]}
       (echo n; echo p; echo 2; echo; echo; echo t; echo fd; echo w;) | fdisk ${disk_list[$count]}
       count=$(( $count + 1 ))
    done
}

function remove_partitions ()
{
    disk_list=($@)
    echo "Creating partitions on ${disk_list[@]}"

    count=0
    while [ "x${disk_list[count]}" != "x" ]
    do
       echo ${disk_list[$count]}
       (echo p; echo d; echo w;) | fdisk ${disk_list[$count]}
       count=$(( $count + 1 ))
    done
}

function create_raid_and_mount()
{
# Creats RAID using unused data disks attached to the VM.
    if [[ $# == 3 ]]
    then
        local deviceName=$1
        local mountdir=$2
        local format=$3
    else
        local deviceName="/dev/md1"
        local mountdir=/data-dir
        local format="ext4"
    fi

    local uuid=""
    local list=""

    echo "IO test setup started.."
    list=(`fdisk -l | grep 'Disk.*/dev/sd[a-z]' |awk  '{print $2}' | sed s/://| sort| grep -v "/dev/sd[ab]$" `)

    lsblk
    install_package mdadm
    echo "--- Raid $deviceName creation started ---"
    (echo y)| mdadm --create $deviceName --level 0 --raid-devices ${#list[@]} ${list[@]}
    check_exit_status "$deviceName Raid creation"

    time mkfs -t $format $deviceName
    check_exit_status "$deviceName Raid format"

    mkdir $mountdir
    uuid=`blkid $deviceName| sed "s/.*UUID=\"//"| sed "s/\".*\"//"`
    echo "UUID=$uuid $mountdir $format defaults 0 2" >> /etc/fstab
    mount $deviceName $mountdir
    check_exit_status "RAID ($deviceName) mount on $mountdir as $format"
}

function remote_copy ()
{
    remote_path="~"

    while echo $1 | grep -q ^-; do
       eval $( echo $1 | sed 's/^-//' )=$2
       shift
       shift
    done

    if [[ `which sshpass` == "" ]]
    then
        echo "sshpass not installed\n Installing now..."
        install_package "sshpass"
    fi

    if [ "x$host" == "x" ] || [ "x$user" == "x" ] || [ "x$passwd" == "x" ] || [ "x$filename" == "x" ] ; then
       echo "Usage: remote_copy -user <username> -passwd <user password> -host <host ipaddress> -filename <filename> -remote_path <location of the file on remote vm> -cmd <put/get>"
       return
    fi

    if [ "$cmd" == "get" ] || [ "x$cmd" == "x" ]; then
       source_path="$user@$host:$remote_path/$filename"
       destination_path="."
    elif [ "$cmd" == "put" ]; then
       source_path=$filename
       destination_path=$user@$host:$remote_path/
    fi

    status=`sshpass -p $passwd scp -o StrictHostKeyChecking=no $source_path $destination_path 2>&1`
    echo $status
}

function remote_exec ()
{
    while echo $1 | grep -q ^-; do
       eval $( echo $1 | sed 's/^-//' )=$2
       shift
       shift
    done
    cmd=$@
    if [[ `which sshpass` == "" ]]
    then
        echo "sshpass not installed\n Installing now..."
        install_package "sshpass"
    fi

    if [ "x$host" == "x" ] || [ "x$user" == "x" ] || [ "x$passwd" == "x" ] || [ "x$cmd" == "x" ] ; then
       echo "Usage: remote_exec -user <username> -passwd <user password> -host <host ipaddress> <onlycommand>"
       return
    fi

    status=`sshpass -p $passwd ssh -t -o StrictHostKeyChecking=no $user@$host $cmd 2>&1`
    echo $status
}

function set_user_password {
    # This routine can set root or any user's password without interaction.
    if [[ $# == 3 ]]
    then
        user=$1
        user_password=$2
        sudo_password=$3
    else
        echo "Usage: user user_password sudo_password"
        return -1
    fi

    hash=$(openssl passwd -1 $user_password)

    string=`echo $sudo_password | sudo -S cat /etc/shadow | grep $user`

    if [ "x$string" == "x" ]
    then
        echo "$user not found in /etc/shadow"
        return -1
    fi

    IFS=':' read -r -a array <<< "$string"
    line="${array[0]}:$hash:${array[2]}:${array[3]}:${array[4]}:${array[5]}:${array[6]}:${array[7]}:${array[8]}"

    echo $sudo_password | sudo -S sed -i "s#^${array[0]}.*#$line#" /etc/shadow

    if [ `echo $sudo_password | sudo -S cat /etc/shadow| grep $line|wc -l` != "" ]
    then
        echo "Password set succesfully"
    else
        echo "Failed to set password"
    fi
}

function collect_VM_properties ()
{
# This routine collects the information in .csv format.
# Anyone can expand this with useful details.
# Better if it can collect details without su permission.

    local output_file=$1

    if [ "x$output_file" == "x" ]
    then
        output_file="VM_properties.csv"
    fi

    echo "" > $output_file
    echo ",OS type,"`detect_linux_ditribution` `detect_linux_ditribution_version` >> $output_file
    echo ",Kernel version,"`uname -r` >> $output_file
    echo ",LIS Version,"`get_lis_version` >> $output_file
    echo ",Host Version,"`get_host_version` >> $output_file
    echo ",Total CPU cores,"`nproc` >> $output_file
    echo ",Total Memory,"`free -h|grep Mem|awk '{print $2}'` >> $output_file
    echo ",Resource disks size,"`lsblk|grep "^sdb"| awk '{print $4}'`  >> $output_file
    echo ",Data disks attached,"`lsblk | grep "^sd" | awk '{print $1}' | sort | grep -v "sd[ab]$" | wc -l`  >> $output_file
    echo ",eth0 MTU,"`ifconfig eth0|grep MTU|sed "s/.*MTU:\(.*\) .*/\1/"` >> $output_file
    echo ",eth1 MTU,"`ifconfig eth1|grep MTU|sed "s/.*MTU:\(.*\) .*/\1/"` >> $output_file
    cat /proc/cpuinfo > cpuinfo
    dmesg > dmesg
}

function keep_cmd_in_startup ()
{
	testcommand=$*
	startup_files="/etc/rc.d/rc.local /etc/rc.local /etc/SuSE-release"
	count=0
	for file in $startup_files
	do
		if [[ -f $file ]]
		then
			if ! grep -q "${testcommand}" $file
			then
				sed "/^\s*exit 0/i ${testcommand}" $file -i
				if ! grep -q "${testcommand}" $file
				then
					echo $testcommand >> $file
				fi
				echo "Added $testcommand >> $file"
				((count++))
			fi
		fi
	done
	if [ $count == 0 ]
	then
		echo "Cannot find $startup_files files"
	fi
}

function remove_cmd_from_startup ()
{
	testcommand=$*
	startup_files="/etc/rc.d/rc.local /etc/rc.local /etc/SuSE-release"
	count=0
	for file in $startup_files
	do
		if [[ -f $file ]]
		then
			if grep -q "${testcommand}" $file
			then
				sed "s/${testcommand}//" $file -i
				((count++))
				echo "Removed $testcommand from $file"
			fi
		fi
	done
	if [ $count == 0 ]
	then
		echo "Cannot find $testcommand in $startup_files files"
	fi
}

function install_azcopy ()
{

  if [[ `which yum` != "" ]]; then
    echo "RedHat based OS"
    sudo yum install rh-dotnet20 -y
    #bash /opt/rh/rh-dotnet20/enable
    sudo scl enable rh-dotnet20 bash
    #sudo cp /opt/rh/rh-dotnet20/root/usr/bin/dotnet /usr/bin
  else
    if [[ `which apt-get` != "" ]]; then
      echo "Ubuntu based OS"
      curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
      sudo mv microsoft.gpg /etc/apt/trusted.gpg.d/microsoft.gpg
      sudo sh -c 'echo "deb [arch=amd64] https://packages.microsoft.com/repos/microsoft-ubuntu-xenial-prod xenial main" > /etc/apt/sources.list.d/dotnetdev.list'
      sudo apt-get update
      sudo apt-get install dotnet-sdk-2.0.2 -y
    fi
  fi

  wget -O azcopy.tar.gz https://aka.ms/downloadazcopyprlinux
  tar -xf azcopy.tar.gz
  sudo ./install.sh
  check_exit_status "Installation of azcopy"
}

function upload_files_to_blob_storage ()
{
	filename=$1
	blob_storage_url=$2
	key=$3

	echo "Uploading logs to Storage account '"$blob_storage_url"'"
	
	if [[ `which azcopy` == "" ]]
	then 
		echo "azcopy wasn't installed\n Installing now..." 
		install_azcopy 
	fi
	
	azcopy \
		--source $filename \
		--destination $blob_storage_url/$filename \
		--dest-key $key

}

function get_service_status ()
{
	ServiceName=$1
	Status=""
	if [ "x"`which service` != "x" ]
    then
		CmdOutPut=`service $ServiceName status`
        Status=`service $ServiceName status | grep Active| awk '{print $3}' | sed s/[\(\)]//g`
    elif [ "x"`which systemctl` != "x" ]
    then
		CmdOutPut=`systemctl status $ServiceName`
		Status=`systemctl status $ServiceName | grep Active| awk '{print $3}' | sed s/[\(\)]//g`
    else
		Status="Unknown"
    fi

    if [ $Status == "dead" ]
    then
		if [ `echo $CmdOutPut| grep "not-found"|wc -l` -eq 1 ]
		then
			Status="ServiceNotFound"
		fi
    fi
	echo $Status
}

function set_service_status ()
{
	ServiceName=$1 
	Status=$2
	if [ "x"`which service` != "x" ]
    then
		service $ServiceName $Status
		check_exit_status "service $ServiceName $Status"
    elif [ "x"`which systemctl` != "x" ]
    then
		systemctl $Status $ServiceName
		check_exit_status "systemctl $Status $ServiceName"
    else
		Status="Unknown"
    fi
	echo "Currenr status of service $ServiceName:" `GetServiceStatus $ServiceName`
}

function InstallDockerFromGetDockerDotCom ()
{
    sudo docker --version | grep "Docker version" | LogMsg
    if [ $? -eq 0 ]
	then
		sudo systemctl start docker
		echo "Docker already installed" | LogMsg
    else
		echo "Installing Docker" | LogMsg
		#TODO Should we install docker via someother means ?for example apt-get install docker-ce
		wget -qO- https://get.docker.com/ | sh

		if [ $? -ne 0 ] 
		then
			echo "docker install failed" | LogMsg
			return 1
		fi
		
		echo "Installing Docker:Done" | LogMsg
		# Commenting below out as currently custom extension script is run as root. 
		# The virtualmachine admin user has sudo permission currently so below may not be required anyways.
		# if required put in a seperate function and get admin user from FSM as here the $USER will always be root
		#sudo usermod -aG docker $USER
    fi
    DockerStatus=`get_service_status docker`
	if [ "x$DockerStatus" == "running" ]
	then
		echo "Docker Installed Succesfully"  | LogMsg
		return 1
	elif [ "x$DockerStatus" == "dead" ]
	then
		echo "Docker Installed succesfully but service not started" | LogMsg
		return 1
	elif [ "x$DockerStatus" == "ServiceNotFound" ]
	then
		echo "Error: Docker Installation Failed" | LogMsg
		return 2
	fi
}

function InstallDockerFromRepo ()
{
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - | LogMsg  
	check_exit_status | LogMsg 
	sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | LogMsg
	check_exit_status | LogMsg
	sudo apt-get update | LogMsg
	check_exit_status  | LogMsg
	sudo apt-cache policy docker-ce | LogMsg
	check_exit_status  | LogMsg
	sudo apt-get install -y docker-ce | LogMsg
	check_exit_status  | LogMsg
	sudo systemctl status docker | LogMsg
	check_exit_status  | LogMsg
	DockerStatus=`get_service_status docker`
	if [ "x$DockerStatus" == "running" ]
	then
		echo "Docker Installed Succesfully"  | LogMsg
		return 1
	elif [ "x$DockerStatus" == "dead" ]
	then
		echo "Docker Installed succesfully but service not started" | LogMsg
		return 1
	elif [ "x$DockerStatus" == "ServiceNotFound" ]
	then
		echo "Error: Docker Installation Failed" | LogMsg
		return 2
	fi
}

function InstallDocker()
{
    if [[ `which docker` != "" ]]
    then
        echo "Info: 'docker' is already installed skipping ..."
    else
		echo "Info: Installing 'docker' ..."

		InstallDockerFromRepo
		Status=$?
		if [ $Status -eq 1 ]
		then
			set_service_status docker restart
		elif [ $Status -gt 1 ]
		then
			echo "Warning: InstallDockerFromRepo failed to install 'docker'" | LogMsg
			InstallDockerFromGetDockerDotCom
			Status=$?
			if [ $Status -eq 1 ]
			then
				set_service_status docker restart
			elif [ $Status -gt 1 ]
			then
				echo "Error: Failed to Install docker exitting now" | LogMsg
				echo "DOCKER_INSTALLATION_FAILED" | UpdateStatus
			fi
		fi
		
		echo "Info: Installation of docker succesfully finished" | LogMsg		
		echo "DOCKER_INSTALLATION_SUCCESS" | UpdateStatus

		if [ $? -ne 0 ] 
		then 
			exit 1 
		fi
	fi
}

function stop_and_remove_all_containers()
(
    echo "Info: Stopping all containers" | LogMsg
    docker stop $(docker ps -a -q)  | LogMsg
    echo "Info: Removing all containers" | LogMsg
    docker rm $(docker ps -a -q)  | LogMsg
)

function remove_all_images()
(
    docker rmi $(docker images -a -q)  | LogMsg
)


function CreatePostgresBdrImage()
{
cat >Dockerfile <<EOL
FROM ubuntu:16.04

RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial main restricted"  > /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial-updates main restricted" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial universe" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial-updates universe" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial multiverse" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial-updates multiverse" >> /etc/apt/sources.list
RUN echo "deb http://azure.archive.ubuntu.com/ubuntu/ xenial-backports main restricted universe multiverse" >> /etc/apt/sources.list
RUN echo "deb http://security.ubuntu.com/ubuntu xenial-security main restricted" >> /etc/apt/sources.list
RUN echo "deb http://security.ubuntu.com/ubuntu xenial-security universe" >> /etc/apt/sources.list
RUN echo "deb http://security.ubuntu.com/ubuntu xenial-security multiverse" >> /etc/apt/sources.list

RUN apt-get update
RUN apt-get install openssh-server unzip curl apt-transport-https ca-certificates -y

RUN sh -c 'echo "deb https://apt.2ndquadrant.com/ $(cat /etc/*release*| grep DISTRIB_CODENAME| sed 's/^.*=//')-2ndquadrant main" > /etc/apt/sources.list.d/2ndquadrant.list'
RUN curl https://apt.2ndquadrant.com/site/keys/9904CD4BD6BAF0C3.asc | apt-key add -

RUN apt-get update
RUN apt-get install -y postgresql-bdr-9.4-bdr-plugin

RUN mkdir /datadrive
RUN mkdir /var/run/sshd

RUN echo 'root:screencast' | chpasswd
RUN sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd
ENV NOTVISIBLE "in users profile"
RUN echo "export VISIBLE=now" >> /etc/profile
EXPOSE 22

RUN /usr/sbin/locale-gen --purge en_US.UTF-8
RUN echo -e 'LANG="en_US.UTF-8"\nLANGUAGE="en_US:en"\n' > /etc/default/locale

RUN echo "service postgresql start" > /startup.sh
RUN echo "/usr/sbin/sshd -D" >> /startup.sh

CMD ["/bin/bash", "/startup.sh"]

EOL
	imageName="postgresql-bdr_0.3"
    containerName="postgresql-bdr"
    echo "*****************************************************"
    echo "Building the Image....."
	docker build -t $imageName . 
	echo "*****************************************************"
    echo "Starting the Container...."
    docker run -d -P  -p  222:22 -p 5432:5432 -p 5433:5433  -v /root:/root -v /etc/shadow:/etc/shadow --name $containerName $imageName
	docker port $containerName
}