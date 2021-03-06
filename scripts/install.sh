#!/usr/bin/env sh

#set -e

SCRIPT_DIR="$(pwd -P)/scripts"
OWTF_DIR="${HOME}/.owtf"
ROOT_DIR="$(dirname $SCRIPT_DIR)/owtf"
CWD="$(dirname $ROOT_DIR)"
os=${OSTYPE//[0-9.-]*/}


. ${SCRIPT_DIR}/platform_config.sh
export NVM_DIR="${HOME}/.nvm"

# ======================================
#   ESSENTIAL
# ======================================
yell() { echo "$0: $*" >&2; }
die() { yell "$*"; exit 111; }
try() { "$@" || die "cannot $*"; }


if [ ! -f "${CWD}/Makefile" ]; then
    die "Exiting: no Makefile found"
fi

[ -d $OWTF_DIR ] || mkdir $OWTF_DIR


# ======================================
#  COLORS
# ======================================
bold=$(tput bold)
reset=$(tput sgr0)

danger=${bold}$(tput setaf 1)   # red
warning=${bold}$(tput setaf 3)  # yellow
info=${bold}$(tput setaf 6)     # cyan
normal=${bold}$(tput setaf 7)   # white

# =======================================
#   Default variables
# =======================================
user_agent='Mozilla/5.0 (X11; Linux i686; rv:6.0) Gecko/20100101 Firefox/15.0'

action="init"

certs_folder="${OWTF_DIR}/proxy/certs"
ca_cert="${OWTF_DIR}/proxy/certs/ca.crt"
ca_key="${OWTF_DIR}/proxy/certs/ca.key"
ca_pass_file="${OWTF_DIR}/proxy/certs/ca_pass.txt"
ca_key_pass="$(openssl rand -base64 16)"

postgres_server_ip="127.0.0.1"
db_name="owtf_db"
db_user="owtf_db_user"
db_pass="jgZKW33Q+HZk8rqylZxaPg1lbuNGHJhgzsq3gBKV32g="
postgres_server_port=5432
postgres_version="$(psql --version 2>&1 | tail -1 | awk '{print $3}' | $SED_CMD 's/\./ /g' | awk '{print $1 "." $2}')"


# =======================================
#   COMMON FUNCTIONS
# =======================================
if [[ "$(cat /proc/1/cgroup 2> /dev/null | grep docker | wc -l)" > 0 ]] || [ -f /.dockerenv ]; then
  IS_DOCKER=1
else
  IS_DOCKER=0
fi

create_directory() {
    if [ ! -d $1 ]; then
      mkdir -p $1;
      return 1
    else
      return 0
    fi
}

check_sudo() {
    timeout 2 sudo id && sudo=1 || sudo=0
    return $sudo
}

check_root() {
	if [ $EUID -eq 0 ]; then
		return 1
	else
		return 0
	fi
}

install_in_dir() {
    tmp=$PWD
    if [ $(create_directory $1) ]; then
        cd $1
        echo "Running command $2 in $1"
        $2
    else
        echo "${warning}[!] Directory $1 already exists, so skipping installation for this${reset}"
    fi
    cd $tmp
}

check_debian() {
    if [ -f "/etc/debian_version" ]; then
        debian=1
    else
        debian=0
    fi
    return $debian
}

copy_dirs() {
    dest=$2
    src=$1
    if [ ! -d $dest ]; then
        cp -r $src $dest
    else
        echo "${warning}[!] Skipping copying directory $(basename $src) ${reset}"
    fi
}

# =======================================
#   PROXY CERTS SETUP
# =======================================
proxy_setup() {
    if [ ! -f ${ca_cert} ]; then
        # If ca.crt is absent then all the old signed certs have to be wiped clean first
        if [ -d ${certs_folder} ]; then
            rm -r ${certs_folder}
        fi
        mkdir -p ${certs_folder}

        # A file is created which consists of CA password
        if [ -f ${ca_pass_file} ]; then
            rm ${ca_pass_file}
        fi
        echo $ca_key_pass >> $ca_pass_file
        openssl genrsa -des3 -passout pass:${ca_key_pass} -out "$ca_key" 4096
        openssl req -new -x509 -days 3650 -subj "/C=US/ST=Pwnland/L=OWASP/O=OWTF/CN=MiTMProxy" -passin pass:${ca_key_pass} \
            -key "$ca_key" -out "$ca_cert"
        echo "${warning}[!] Don't forget to add the $ca_cert as a trusted CA in your browser${reset}"
    else
        echo "${info}[*] '${ca_cert}' already exists. Nothing done.${reset}"
    fi
}

# =======================================
#   DATABASE setup
# =======================================

# Check if postgresql service is running or not
postgresql_check_running_status() {
    postgres_ip_status=$(get_postgres_server_ip)
    if [ -z "$postgres_ip_status" ]; then
        echo "${info}PostgreSQL server is not running.${reset}"
        echo "${info}Please start the PostgreSQL server and rerun.${reset}"
        echo "${info}For Kali/Debian like systems, try sudo service postgresql start or sudo systemctl start postgresql ${reset}"
        echo "${info}For macOS, use pg_ctl -D /usr/local/var/postgres start ${reset}"
    else
        echo "${info}[+] PostgreSQL server is running ${postgres_server_ip}:${postgres_server_port} :)${reset}"
    fi
}

# returns postgresql service IP
get_postgres_server_ip() {
    if [ $os == "darwin" ]; then
        echo "$(lsof -i -n -P | grep TCP | grep postgres | sed 's/\s\+/ /g' | cut -d ' ' -f4 | cut -d ':' -f1 | uniq)"
    else
        echo "$(sudo netstat -lptn | grep "^tcp " | grep postgres | sed 's/\s\+/ /g' | cut -d ' ' -f4 | cut -d ':' -f1)"
    fi
}

postgresql_create_user() {
    if [ $os == "darwin" ]; then
        psql postgres -c "CREATE USER $db_user WITH PASSWORD '$db_pass';"
    else
        sudo su postgres -c "psql -c \"CREATE USER $db_user WITH PASSWORD '$db_pass'\""
    fi
}

postgres_alter_user_password() {
    if [ $os == "darwin" ]; then
        psql postgres -tc "ALTER USER $db_user WITH PASSWORD '$db_pass';"
    else
        sudo su postgres -c "psql postgres -tc \"ALTER USER $db_user WITH PASSWORD '$db_pass'\""
    fi
}

postgresql_create_db() {
    if [ $os == "darwin" ]; then
        psql postgres -c "CREATE DATABASE $db_name WITH OWNER $db_user ENCODING 'utf-8' TEMPLATE template0;"
    else
        sudo su postgres -c "psql -c \"CREATE DATABASE $db_name WITH OWNER $db_user ENCODING 'utf-8' TEMPLATE template0;\""
    fi
}

postgresql_check_user() {
    cmd="$(psql -l | grep -w $db_name | grep -w $db_user | wc -l | xargs)"
    if [ "$cmd" != "0" ]; then
        return 1
    else
        return 0
    fi
}

postgresql_drop_user() {
    if [ $os == "darwin" ]; then
        psql postgres -c "DROP USER $db_user"
    else
        sudo su postgres -c "psql -c \"DROP USER $db_user\""
    fi
}

postgresql_drop_db() {
    if [ $os == "darwin" ]; then
        psql postgres -c "DROP DATABASE $db_name"
    else
        sudo su postgres -c "psql -c \"DROP DATABASE $db_name\""
    fi
}

postgresql_check_db() {
    cmd="$(psql -l | grep -w $db_name | wc -l | xargs)"
    if [ "$cmd" != "0" ]; then
        return 1
    else
        return 0
    fi
}


db_setup() {
    # Check if the postgres server is running or not.
    postgresql_check_running_status

    # postgres server is running perfectly fine begin with db_setup.
    # Create a user $db_user if it does not exist
    if [ postgresql_check_user == 1 ]; then
        echo "${info}[+] User $db_user already exist.${reset}"
        # User $db_user already exist in postgres database change the password
        continue
    else
        # Create new user $db_user with password $db_pass
        postgresql_create_user
    fi
    # Create database $db_name if it does not exist.
    if [ postgresql_check_db == 1 ]; then
       echo "${info}[+] Database $db_name already exist.${reset}"
       continue
    else
       # Either database does not exists or the owner of database is not $db_user
       # Create new database $db_name with owner $db_user
       postgresql_create_db
    fi
}


# ======================================
#   KALI install
# ======================================
kali_install() {
    echo "${info}[*] Install Kali linux specific dependencies...${reset}"
    make install-dependencies
    echo "${info}[*] Installing required tools...${reset}"
    make opt-tools
    make web-tools
    sh "$SCRIPT_DIR/kali/install.sh"
}

# ======================================
#   SETUP WEB INTERFACE DEPENDENCIES
# ======================================

ui_setup() {
    # Download community written templates for export report functionality.
    if [ ! -d "${ROOT_DIR}/webapp/src/containers/Report/templates" ]; then
        echo "${warning} Templates not found, fetching the latest ones...${reset}"
        git clone https://github.com/owtf/templates.git "$ROOT_DIR/webapp/src/containers/Report/templates"
    fi

    if [ ! -d ${NVM_DIR} ]; then
        # Instead of using apt-get to install npm we will nvm to install npm because apt-get installs older-version of node
        echo "${normal}[*] Installing npm using nvm.${reset}"
        wget https://raw.githubusercontent.com/creationix/nvm/v0.31.1/install.sh -O /tmp/install_nvm.sh
        bash /tmp/install_nvm.sh
        rm -rf /tmp/install_nvm.sh
    fi

    # Setup nvm and install node
    . ${NVM_DIR}/nvm.sh
    echo "${normal}[*] Installing NPM...${reset}"
    nvm install node
    nvm alias default node
    echo "${normal}[*] npm successfully installed.${reset}"

    # Installing webpack and gulp globally so that it can used by command line to build the bundle.
    npm install -g yarn
    # Installing node dependencies
    echo "${normal}[*] Installing node dependencies.${reset}"
    TMP_DIR=${PWD}
    cd ${ROOT_DIR}/webapp
    yarn --silent
    echo "${normal}[*] Yarn dependencies successfully installed.${reset}"

    # Building the ReactJS project
    echo "${normal}[*] Building using webpack.${reset}"
    yarn build &> /dev/null
    echo "${normal}[*] Build successful${reset}"
    cd ${TMP_DIR}
}

#========================================
cat << EOF
 _____ _ _ _ _____ _____
|     | | | |_   _|   __|
|  |  | | | | | | |   __|
|_____|_____| |_| |__|

        @owtfp
    http://owtf.org
EOF

echo "${info}[*] Thanks for installing OWTF! ${reset}"
echo "${info}[!] There will be lot of output, please be patient :)${reset}"

# Copy git hooks
echo "${info}[*] Installing pre-commit and black for git hooks...${reset}"
pip install pre-commit==1.8.2
pip install black==18.4a3
pre-commit install

# Copy all necessary directories
for dir in ${ROOT_DIR}/data/*; do
    copy_dirs "$dir" "${OWTF_DIR}/$(basename $OWTF_DIR/$dir)"
done

if [ ! "$(uname)" == "Darwin" ]; then
    check_sudo > /dev/null
fi

proxy_setup

if [ "$IS_DOCKER" -eq "0" ]; then
    db_setup
else
    echo "${info}Running inside Docker, no need to configure DB"
fi

ui_setup

if [ "$(check_debian)" == "1" ]; then
    kali_install
fi

make post-install

echo "${info}[*] Finished!${reset}"
echo "${info}[*] Start OWTF by running cd path/to/pentest/directory; owtf${reset}"
